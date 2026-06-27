# P2 — Environment & Flight Mode Expansion

> **Overall phase:** P2 (follows per-rotor thrust vectoring in P1)
> **Type:** Multi-step implementation plan
> **Author:** Tim / Kaya

**Goal:** Make the drone sim feel like a real place with obstacles, crash states,
assisted flight modes, and environmental wind.

**Theme:** Alternating visual breathers and physics work. No more than one
heavy physics phase in a row.

---

## Phase A — Visual Breather (Trees, Rotors, Terrain)

### A-1 Fix documentation: FPV toggle is on R1, not R2

**Files:** `AGENTS.md` (controller layout table), `PROJECT_SUMMARY.md`

- `toggle_fpv` is bound to button_index 10, which is **R1** on DualSense
- `reset_drone` is button_index 3 = Triangle
- Update both doc files to reflect this
- Other HUD items are fine

### A-2 Binary spinning rotor visual

**Files:** `scripts/drone/drone_controller.gd`, `scenes/drone/drone.tscn`

Approach from discussion:
- Don't animate mesh rotation — rotors spin too fast to see
- Instead: swap the propeller mesh to a "teacup" (small translucent disc /
  torus mesh that blurs the rotor disc area) when motors are armed
- Swap back to the cone when throttle is cut (collective < 0.001)
- Means: expose rotor nodes in `DroneController`, check throttle cut state
  each frame, swap mesh resource on all 4 rotors
- Could also add a subtle emissive glow when spinning (rotor materials get
  slight emission)

### A-3 Procedural trees and rocks

**Files:** `scripts/environment/terrain_generator.gd` (or new
`scripts/environment/scatter.gd`), new mesh resources in `assets/models/`

Approach:
- Trees = cone + cylinder (cone trunk, sphere canopy). Simple CSG or
  MeshInstance3D with procedural geometry.
- Rocks = scaled, randomly rotated box/sphere with rough material.
- Spawn at generation time: sample terrain height at N random points,
  place instances with random rotation + slight scale variance.
- Need to update `terrain_generator.gd` to expose a `get_height_at(x, z)`
  so scatter code can sample it.
- For now, no physics collision on trees/rocks — visual only. Add collision
  bodies later in Phase C.

Variations:
- 2-3 tree shapes (tall pine, round deciduous, dead stub)
- 2 rock shapes (boulder, rubble cluster)

### A-4 Simple terrain coloring

**Files:** `scripts/environment/terrain_generator.gd`

Current terrain is one flat noise-based heightmap. Add:
- Vertex color by height: low = brown/green, mid = green, high = grey/rock
- Or slope-based coloring: steep = rock, flat = grass
- Simple gradient lookup in the mesh generation

### A-5 Sky / atmosphere / lighting pass

**Files:** `scenes/main.tscn`

Current scene has:
- DirectionalLight3D with shadows
- WorldEnvironment with fog

Tune:
- Fog density / color for atmosphere
- Sun angle for better shadows / mood
- Maybe add a gentle ambient light tint

---

## Phase B — Assisted Flight Modes (Altitude Hold + Brake)

### B-1 Rebind inputs for new modes

**Files:** `project.godot`, `scripts/drone/drone_controller.gd`

New InputMap actions needed:
- `altitude_hold` → L2 (button_index 6, analog trigger) — hold to engage
- `brake_mode` → R2 (button_index 7, analog trigger) — hold to engage

Note: L2 and R2 are analog triggers (axis values), so use
`Input.get_action_strength("altitude_hold")` to get 0.0–1.0 press depth.
Engage when > 0.5.

Currently R2 (button_index 10) was `toggle_fpv` — that moves to R1.

**New controller layout:**

| Button | Function | Type |
|--------|----------|------|
| L1 | Toggle flight mode (acro ↔ stabilized) | Press |
| R1 | Toggle FPV mode | Press |
| L2 | Altitude hold (hold) | Analog hold |
| R2 | Brake / cancel horizontal velocity (hold) | Analog hold |
| Triangle | Reset drone | Press |

### B-2 Altitude hold flight mode subsystem

**Files:** `scripts/drone/flight_mode_altitude_hold.gd` (new),
`scripts/drone/drone_controller.gd`

New class `FlightModeAltitudeHold extends FlightModeBase`.

Behavior:
- On engage (L2 pressed), capture current Y position as `_target_altitude`
- While held, compute vertical velocity error: `0 - current_vertical_speed`
- Apply PD to vertical velocity: output = P * error - D * vertical_accel
- Mix output into collective offset (override pilot throttle)
- All other axes (pitch/roll/yaw) pass through normally — pilot still flies
- On release, smooth transition back to pilot throttle over 0.3s

Integration:
- `DroneController` checks if altitude_hold > 0.5 in `_read_inputs`
- If engaged, replaces the collective from `_current_mode.compute()` with
  altitude-hold collective, but passes through pitch/roll/yaw as normal
- This means altitude hold is a filter stage after mode compute, not a
  standalone mode — simpler architecture

Alternative: make it a new flight mode that toggles like acro/stabilized.
But Tim said L2 is a "hold trigger" — so it's momentary. So it's a
modifier on any existing mode. The filter approach is better.

### B-3 Brake / hover mode

**Files:** `scripts/drone/drone_controller.gd`

On R2 hold:
- Compute horizontal velocity (x,z components of `linear_velocity`)
- Apply opposing force scaled by `mass * horizontal_vel / brake_time`
  where `brake_time ≈ 1.0s` (tune for feel)
- Do NOT touch vertical velocity (Y) — pilot controls climb/descent,
  or altitude hold handles it if also active
- If vertical velocity is also held AND both L2+R2 are pressed, brake
  handles horizontal, altitude hold handles vertical — they compose

### B-4 HUD indicators for new modes

**Files:** `scripts/ui/debug_hud.gd`

Add to telemetry display:
- `ALT HOLD` indicator when altitude hold engaged
- `BRAKE` indicator when brake engaged
- Update HUD layout if needed (panel may need to grow)

---

## Phase C — Crash / Signal Loss

### C-1 Collision detection using existing physics

No new collision shapes needed — `Drone extends RigidBody3D` with
`BoxShape3D` collision and terrain has a `StaticBody3D`. Godot already
fires `body_entered` / `body_exited` signals.

Connect signal in `DroneController._ready()`:
- `body_entered.connect(_on_collision)`

In `_on_collision(body)`:
- Compute impact angle: angle between `linear_velocity.normalized()` and
  the collision normal
- Compute impact momentum: `linear_velocity.length() * mass`
- If angle > threshold (glancing blow) AND momentum low → bounce (no-op,
  physics handles it)
- If angle < threshold (direct hit) OR momentum high → crash

### C-2 Signal loss state machine

**Files:** `scripts/drone/drone_controller.gd`

Add states: `FLYING`, `CRASHED`

When crash triggers:
1. Emit `crash_detected` signal
2. Set state to `CRASHED`
3. Zero all rotor forces (stop calling `_compute_and_apply_forces`)
4. Let physics inertia carry the drone naturally (it'll tumble + settle)
5. HUD shows "SIGNAL LOST" over telemetry

When `reset()` is called (Triangle pressed):
1. Reset to spawn, set state to `FLYING`
2. Clear the signal lost indicator

While CRASHED:
- `_read_inputs` and `_compute_and_apply_forces` are skipped
- `_apply_angular_damping` is skipped
- Only `reset_drone` action is handled

### C-3 Signal lost HUD overlay

**Files:** `scripts/ui/debug_hud.gd`

Add signal to get crash state from drone:
- `signal_lost` bool or a signal connection

When crashed:
- Overlay large red "⚠ SIGNAL LOST" text in center of screen
- Pulse or flash the text
- Mute normal telemetry display (or dim it)

On reset:
- Remove overlay, restore telemetry

---

## Phase D — Wind Fields

### D-1 Global wind vector + turbulence

**Files:** `scripts/environment/wind.gd` (new singleton or autoload),
`scripts/drone/drone_controller.gd`

`Wind` autoload:
- `base_wind: Vector3` — constant wind direction + speed (default
  `Vector3(2.0, 0.0, 1.0)` = light breeze)
- `turbulence_strength: float` — noise amplitude (default 1.0)
- `turbulence_frequency: float` — how quickly gusts change (default 0.5)
- Function `get_wind_at(position: Vector3, time: float) -> Vector3`
  - Uses `FastNoiseLite` or `sin(time * freq)` for turbulence
  - Returns `base_wind + turbulence_offset`

DroneController:
- In `_compute_and_apply_forces`, get `Wind.get_wind_at(global_position, Time.get_ticks_msec() / 1000.0)`
- Apply wind as a force: `apply_central_force(wind_vector * wind_influence_factor)`
- Per-rotor wind: apply asymmetric wind by adding drift to each rotor's
  thrust direction based on wind at that rotor position
  (wind pushes high side = roll torque downwind)

### D-2 Wind visualization

Two options — pick one:

**Option A: HUD wind arrow**
- Small compass-like arrow in HUD showing wind direction + strength
- Arrow length = speed, arrow direction = wind direction in horizontal plane
- Digital: "WIND: 3.2 m/s → NW"

**Option B: Particle system**
- GPU particles streaming across scene in wind direction
- More immersive but higher overhead
- Thin white/grey streaks, low opacity

### D-3 Wind intensity by altitude

Wind gets stronger with altitude (realistic):
- `base_wind * (1.0 + altitude * 0.1)` — doubles at 10m height
- Makes low flying calmer, high flying more challenging

---

## Open Questions

1. **Trees on terrain collision:** Currently trees would be visual-only.
   Add collision later for crash detection? Or keep them purely decorative
   and use only terrain collision for crashes?

2. **Altitude hold engagement:** Capture altitude on button press. What if
   you press L2 while still at 0 throttle on the ground? Should it
   immediately climb to a minimum altitude (1m) or just hold current?
   (Recommend: hold current — if pilot didn't take off yet, altitude hold
   at ground level is no-op until they throttle up manually.)

3. **Brake + altitude hold composition:** If both L2+R2 are held, brake
   handles horizontal and altitude hold handles vertical. Feels right but
   need to make sure they don't fight each other.

4. **Wind + stabilized mode interaction:** Wind pushes drone sideways.
   Stabilized mode auto-levels attitude but doesn't resist horizontal
   drift — so wind will naturally push the drone. That's realistic drone
   behavior (no GPS hold). Brake mode would cancel wind drift.

---

## Testing

Each phase should have verifiable tests:

**Phase A (visual):**
- Launch game, visually confirm rotors spin when throttle > 0
- Confirm trees/rocks scattered across terrain
- Confirm terrain has color variation

**Phase B (flight modes):**
- Headless tests: altitude hold maintains altitude within 0.5m over 200 frames
- Headless test: brake mode kills horizontal velocity within 1s
- HUD shows ALT HOLD / BRAKE

**Phase C (crash):**
- Fly into terrain, verify SIGNAL LOST appears
- Press Triangle, verify reset + cleared overlay

**Phase D (wind):**
- Print wind vector to console during flight
- Verify drone drifts downwind in stabilized mode with no stick input

---

## Execution Order

1. Phase A-1 (doc fix) — 5 min
2. Phase A-2 (rotor visual) — 15 min
3. Phase A-3 (trees/rocks) — 30 min
4. Phase A-4 (terrain color) — 15 min
5. Phase A-5 (sky/lighting) — 10 min
6. Phase B-1 (input rebind) — 10 min
7. Phase B-2 (altitude hold) — 30 min
8. Phase B-3 (brake mode) — 20 min
9. Phase B-4 (HUD indicators) — 10 min
10. Phase C-1 + C-2 (crash detection + state machine) — 25 min
11. Phase C-3 (signal lost HUD) — 15 min
12. Phase D-1 (wind system) — 25 min
13. Phase D-2 (wind viz) — 20 min
14. Phase D-3 (altitude wind) — 10 min

Estimated total: ~4h of focused work.
