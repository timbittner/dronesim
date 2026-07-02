# P2 — Environment & Flight Mode Expansion

> **Overall phase:** P2 (follows per-rotor thrust vectoring in P1)
> **Type:** Multi-step implementation plan
> **Author:** Tim / Kaya

**Goal:** Make the drone sim feel like a real place with obstacles, crash states,
assisted flight modes, and environmental wind.

**Theme:** Alternating visual breathers and physics work. No more than one
heavy physics phase in a row.

---

## Phase A — Visual Breather (Trees, Rotors, Terrain) — ✅ DONE

Landed in `97ab761`, `c46c5d7`, `6bbbeee`, `0fd69d7`, `1ea1589`. Trees/rocks
stay decorative — no dedicated tree/rock collision bodies; Godot's terrain
`StaticBody3D` collision layer already covers crash detection for Phase C.
Add collision to foliage later only if a specific case demands it.

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

## Phase B — Assisted Flight Modes (Altitude Hold + Brake) — ✅ DONE

Altitude hold (`flight_mode_altitude_hold.gd`) implemented per the
clarifications below: full collective replacement (not blended with the
mode's own math), world-frame `linear_velocity.y`, finite-differenced
filtered velocity for the D-term, and a real engaged-flag + blend-timer state
machine for the 0.3s release blend. HUD shows ALT HOLD / BRAKE. 12 headless
tests pass (10 existing + 2 new: altitude-hold-maintains-altitude,
brake-kills-horizontal-velocity).

**Post-landing fixes from real-controller testing:**
- **B-1 had a real bug:** L2/R2 were bound as `InputEventJoypadButton` with
  `button_index` 6/7. In Godot's abstracted `JoyButton` enum those are Start
  and L3-click, not the triggers — the actions never fired on a real
  DualSense (keyboard Shift/Ctrl worked fine, masking the bug in solo
  testing). L2/R2 are analog **axes** (`InputEventJoypadMotion`, axis 4/5 =
  SDL `TRIGGER_LEFT`/`TRIGGER_RIGHT`), same event type sticks already use.
  Fixed in `project.godot`.
- **B-3 was redesigned:** the original brake used `apply_central_force` — an
  out-of-band force with no relation to rotor thrust, violating the sim's
  "only the 4 motors" principle (flagged by Tim). Replaced with
  `brake_assist.gd`: computes a target airframe tilt from the desired
  horizontal deceleration (`a ≈ g·tan(θ)`) and reuses stabilized mode's
  auto-level restoring-torque technique pointed at that tilted target instead
  of world-up — same rotor-thrust-only mechanism pitch/roll always uses. Adds
  to (blends with) the active mode's own pitch/roll output rather than
  overriding it, per Tim's choice of "blend with stick" over "full override."

### B-1 Rebind inputs for new modes

**Files:** `project.godot`, `scripts/drone/drone_controller.gd`

New InputMap actions needed:
- `altitude_hold` → L2 (axis 4, `InputEventJoypadMotion`) — hold to engage
- `brake_mode` → R2 (axis 5, `InputEventJoypadMotion`) — hold to engage

Note: L2 and R2 are analog triggers reported as **axis** events (SDL
`TRIGGER_LEFT`/`TRIGGER_RIGHT`), the same event type the sticks already use —
not `InputEventJoypadButton`. Use `Input.get_action_strength("altitude_hold")`
to get 0.0–1.0 press depth. Engage when > 0.5.

Currently R2 (button_index 10) was `toggle_fpv` — that moves to R1.

**Keyboard fallback required.** Every existing action in `project.godot` has
a keyboard event alongside the joypad one (see `throttle_up`, `toggle_fpv`,
etc.) — `altitude_hold`/`brake_mode` need the same so keyboard-only testing
still works. Default to **Shift** (altitude_hold) / **Ctrl** (brake_mode); no
conflict with existing WASD/arrow/M/C/R bindings.

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

**Implementation clarifications (resolve before coding):**

- **Full replacement, not a blend with the mode's own collective.** Acro's
  `collective` bakes in an idle-throttle floor (`flight_mode_acro.gd`'s
  `idle_throttle = 0.08`); stabilized's doesn't share that shape. Altitude
  hold must replace `control.collective` entirely with
  `hover_throttle + P * error - D_term`, where `hover_throttle` is the
  value already computed once in `drone_controller.gd:79`
  ((mass * gravity) / (4 * max_thrust)) — not derive a new baseline from
  whichever mode is active.
- **Use world-frame `linear_velocity.y`** for the vertical error, not a
  basis-transformed value — gravity/altitude are always world-Y regardless
  of drone tilt.
- **No acceleration signal exists.** RigidBody3D doesn't expose
  acceleration directly. Store the previous frame's vertical velocity (or
  error) on the new class and take a finite difference for the D-term —
  same pattern `flight_mode_stabilized.gd` already uses for its filtered
  gyro D-term (reuse that shape rather than inventing a new one).
- **Release blend needs actual state**, not just a comment: store an
  `_engaged` flag and a blend timer; on release, lerp from the
  last-computed altitude-hold collective to the pilot's live mode collective
  over 0.3s, then hand control back fully.

### B-3 Brake / hover mode

**Files:** `scripts/drone/brake_assist.gd` (new), `scripts/drone/drone_controller.gd`

**Rewritten after first landing:** the original design ("apply opposing force
scaled by `mass * horizontal_vel / brake_time`" via `apply_central_force`)
was an out-of-band force with no relation to rotor thrust — it violates the
sim's core principle that the drone can only be controlled through its 4
motors. Real fix, `BrakeAssist` (`RefCounted`, same "filter stage" shape as
`FlightModeAltitudeHold`):

- Compute horizontal velocity (x, z components of `linear_velocity`)
- Desired deceleration: `-horizontal_vel / brake_time` (`brake_time ≈ 1.0s`)
- Convert desired deceleration to a target airframe tilt angle via
  `atan2(accel_mag, gravity)` (small-angle `a ≈ g·tan(θ)`, `atan2` so it
  saturates instead of diverging), clamped to `max_tilt_deg` (25°)
- Build `target_up` = world-up rotated toward the deceleration direction by
  that tilt angle, then reuse `flight_mode_stabilized.gd`'s exact auto-level
  technique — restoring torque from `body_up.cross(target_up)` — pointed at
  `target_up` instead of literal world-up. This reuses the already-tested
  pitch/roll sign conventions instead of re-deriving them by hand.
- The resulting `(pitch_diff, roll_diff)` is **added** to whatever the active
  mode already computed — blends with pilot stick input and with
  stabilized's own auto-level (per Tim's choice of "blend with stick" over
  "full override"), rather than taking over pitch/roll entirely. Real quads
  brake this way: nose up / bank to redirect thrust, not a magic force.
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

## Phase C — Crash / Signal Loss — ✅ DONE

Landed with two deliberate deviations from the text below, agreed with Tim:

- **Detection uses `_integrate_forces`, not `body_entered`:** the signal
  carries no contact normal, which the impact-angle check needs. With
  `contact_monitor = true` + `max_contacts_reported = 4` (the setup gap
  flagged in C-1, now set in `drone.tscn`), the same contacts are available
  with normals via `PhysicsDirectBodyState3D`. Impact velocity is the
  previous tick's `linear_velocity` (cached), since the solver has already
  absorbed the impact by contact-report time.
- **FPV "frozen last frame" on signal loss** (Tim's idea, this session):
  physics keeps rolling after a crash as planned, but the FPV *feed* dies at
  the crash instant. Crash in FPV → last rendered frame is captured and
  frozen fullscreen; crash in 3PV → no frame was captured, so entering FPV
  afterwards shows a black "no signal" screen. Chase cam always renders
  live. This relaxes "only reset_drone is handled while CRASHED" to reset
  **+ toggle_fpv** (the camera is the pilot's, not the drone's); L1 stays
  ignored.

Two tuning findings from verification runs:
- `crash_momentum_threshold` is **8** kg·m/s, not the ~6 suggested below: the
  game-start free-fall from the spawn point onto the pad arrives at ~6.1, and
  crashed the drone on launch at 6.0.
- `continuous_cd = true` added to `drone.tscn`: without CCD the 0.12m-thin
  drone body tunnels straight through thin geometry above ~10 m/s (found when
  the crash test's 12 m/s drop passed through the test ground plane), and fast
  dives exceed that easily.

3 new headless tests (15 total): hard impact crashes, gentle acro touchdown
doesn't, reset clears CRASHED and returns to spawn.

### C-1 Collision detection using existing physics

No new collision shapes needed — `Drone extends RigidBody3D` with
`BoxShape3D` collision and terrain has a `StaticBody3D`. Godot already
fires `body_entered` / `body_exited` signals — **but only if contact
monitoring is enabled.**

**Required setup gap:** `drone.tscn` currently has `contact_monitor` unset
(defaults to `false`) and `max_contacts_reported = 0`. Without setting
`contact_monitor = true` and `max_contacts_reported` to at least 4,
`body_entered` will never fire. Easy to miss since the plan text says "no
new collision shapes needed" — true, but this property still has to be set.

Connect signal in `DroneController._ready()`:
- `body_entered.connect(_on_collision)`

In `_on_collision(body)`:
- **Guard first:** if `linear_velocity.length()` is below a small epsilon
  (e.g. `0.05`), return without evaluating angle/momentum at all.
  `linear_velocity.normalized()` on a near-zero vector is undefined, and
  this also naturally covers the drone resting on the spawn pad (at rest,
  contact fires but there's no meaningful velocity to crash on).
- Compute impact angle: angle between `linear_velocity.normalized()` and
  the collision normal
- Compute impact momentum: `linear_velocity.length() * mass` (mass = 2.0,
  see `drone.tscn:10` — a sensible starting threshold is ~6 kg·m/s, i.e. a
  ~3 m/s impact; expose as `@export` so it's tunable without a code change)
- **Corrected logic — this was backwards in the original draft:** crash
  requires **momentum high AND angle direct** (small angle to the surface
  normal), not "OR". The original "OR" would crash on a slow graze at a bad
  angle, and would crash on literally any contact once the zero-velocity
  guard above is added (since angle-direct-but-zero-momentum would still
  satisfy the OR). Bounce (no-op) is everything else.

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

**Known reliability issue — investigated early, during Phase B, at Tim's
request:** `reset_drone` (Triangle) sometimes doesn't trigger on a quick tap
— needs the button held for about a second to register. Findings:
- Ruled out "swallowed elsewhere": grepped the whole project — the only
  `_unhandled_input` handler is in `drone_controller.gd`, and no `Control`
  node grabs focus, so nothing upstream can consume the event first.
- Leading theory: Apple's GameController framework (macOS DualSense driver)
  reports even digital face buttons with an analog `.value`, which Godot
  likely surfaces as `pressure` on `InputEventJoypadButton`. The action's
  old `deadzone: 0.5` gated `is_action_pressed()` on that pressure crossing
  0.5, so a quick tap that releases before the value ramps past 0.5 never
  registers as "pressed" — not independently confirmed against real
  hardware, since that requires the physical controller.
- **Mitigated:** lowered `reset_drone`'s deadzone to 0.2 in `project.godot`
  (still filters real noise-floor values, tolerates a lighter/quicker press),
  and added the suggested `Input.is_action_just_pressed("reset_drone")` poll
  in `_physics_process` alongside the existing `_unhandled_input` edge
  trigger (`reset()` is idempotent, so double-firing in one frame is
  harmless). Documented in AGENTS.md "Known Issues" — **needs a hardware
  retest to confirm this fully resolves it, not just probably helps.**

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

## Phase D — Wind Fields — ✅ DONE

Landed with a substantially redesigned architecture, agreed with Tim during a
dedicated planning pass (see the approved plan, reproduced in spirit below —
the text under D-1/D-2/D-3 is the **original sketch, superseded**, kept for
history):

- **Node-in-group, not an autoload.** `WindField` (`wind_field.gd`) is a
  `Node3D` in `main.tscn`, same environment-side pattern as `CrashEffects` —
  self-registered into group `"wind_field"`, discovered lazily by
  `DroneController` on first physics tick (group lookup, not `_ready()` —
  Drone precedes WindField in tree order). No `WindField` in a scene means
  zero wind, which is why the flight-mode test scene needed zero changes.
- **Relative-airspeed drag, not `apply_central_force(wind_vector *
  factor)`.** `F = air_drag_coefficient * (wind_velocity - linear_velocity)`
  replaces the old `linear_damp = 0.5` (now `0.0`) on the RigidBody3D — tuned
  (`air_drag_coefficient = 1.0` N·s/m at 2.0 kg) to reproduce the old damping
  exactly in still air, so the 15 existing headless tests needed no changes.
  Applied before the FLYING/CRASHED gate, so a wreck drifts downwind too.
- **Both visualization options shipped, not a pick-one.** Advected
  MultiMesh streak particles (`wind_particles.gd`) *and* a camera-relative
  HUD arrow (`debug_hud.gd`, same projection as the axis gizmo), per Tim's
  request — the original D-2 framed these as alternatives.
- **Altitude-above-ground boundary-layer profile, not linear altitude
  scaling.** `get_wind()` ramps from `ground_wind_fraction` of `base_speed`
  at ground level to full speed at `boundary_layer_height` AGL (terrain-
  relative, not `position.y` scaling as D-3 sketched) — needed so wind can
  actually go calm in valleys rather than just scaling with world altitude.
- **Terrain shapes wind speed *and* direction**, not just intensity:
  upwind-ridge shelter (valleys behind ridges go calm), a ridge speed boost,
  and horizontal deflection + updraft around windward slopes (rotates the
  wind vector, doesn't attenuate it) — this and the calm-zone/gust math were
  the actual design work of this phase, well beyond D-1's flat "constant
  wind + turbulence" sketch.
- **Per-rotor asymmetric wind (D-1's roll-torque-from-wind idea) explicitly
  deferred** — not implemented. The uniform relative-airspeed drag model
  was judged sufficient for this phase; revisit only if a specific gameplay
  case wants wind-induced attitude disturbance beyond what drag-drift +
  pilot correction already produces.
- 6 new headless tests (`wind_field_test.gd` against a deterministic
  `MockHillTerrain`): spawn-zone calm, wind grows with AGL, ridge windier
  than valley, wind deflects around a hill (magnitude preserved), null-
  terrain fallback, hovering drone drifts downwind. `run_tests.sh` now runs
  both suites (15 + 6).

Full design detail: `scripts/environment/wind_field.gd`,
`scripts/environment/wind_particles.gd`, `AGENTS.md` → "Wind (P2 Phase D)",
`PROJECT_SUMMARY.md` → wind sections.

<details>
<summary>Original sketch (superseded — kept for history)</summary>

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

1. ~~**Trees on terrain collision**~~ — Resolved: trees/rocks stay decorative,
   crash detection uses terrain's physics layer only. Revisit if a specific
   gameplay case needs foliage collision.

2. **Altitude hold engagement:** Capture altitude on button press. What if
   you press L2 while still at 0 throttle on the ground? Should it
   immediately climb to a minimum altitude (1m) or just hold current?
   (Recommend: hold current — if pilot didn't take off yet, altitude hold
   at ground level is no-op until they throttle up manually.)

3. **Brake + altitude hold composition:** If both L2+R2 are held, brake
   handles horizontal and altitude hold handles vertical. Feels right but
   need to make sure they don't fight each other.

4. ~~**Wind + stabilized mode interaction**~~ — Resolved as expected: wind
   pushes the drone sideways via relative-airspeed drag, stabilized mode
   auto-levels attitude but doesn't resist horizontal drift, so a hovering
   drone drifts downwind (confirmed by the `test_hover_drifts_downwind`
   headless test). Brake mode (R2) cancels the drift, same as it cancels any
   other horizontal velocity.

---

## Testing

Each phase should have verifiable tests:

**Phase A (visual):** ✅ done — rotors spin, trees/rocks scattered, terrain
color variation confirmed.

**Phase B (flight modes):** ✅ done
- Headless tests: altitude hold maintains altitude within 0.5m over 200 frames
- Headless test: brake mode kills horizontal velocity within 1s
- HUD shows ALT HOLD / BRAKE

**Phase C (crash):**
- Fly into terrain, verify SIGNAL LOST appears
- Press Triangle, verify reset + cleared overlay

**Phase D (wind):** ✅ done
- 6 headless tests (`wind_field_test.gd`): spawn calm, AGL profile, ridge vs.
  valley, deflection around a hill, null-terrain fallback, downwind drift
- Manual: streaks bend around hills / vanish in valleys, HUD arrow scales
  and fades with speed and dims on crash, R2 brake cancels wind drift

---

## Execution Order

1. ~~Phase A-1 (doc fix)~~ — done
2. ~~Phase A-2 (rotor visual)~~ — done
3. ~~Phase A-3 (trees/rocks)~~ — done
4. ~~Phase A-4 (terrain color)~~ — done
5. ~~Phase A-5 (sky/lighting)~~ — done
6. ~~Phase B-1 (input rebind)~~ — done
7. ~~Phase B-2 (altitude hold)~~ — done
8. ~~Phase B-3 (brake mode)~~ — done
9. ~~Phase B-4 (HUD indicators)~~ — done
10. ~~Phase C-1 + C-2 (crash detection + state machine)~~ — done
11. ~~Phase C-3 (signal lost HUD + frozen FPV feed)~~ — done
12. ~~Phase D (wind field + drag refactor + headless tests + streak particles
    + HUD arrow + docs)~~ — done

P2 is now complete. Next direction is unscheduled — see "Post-P2 direction"
below.

---

## Post-P2 direction (parking lot, not scheduled)

Notes from discussion after P2 planning, for whenever a P3 doc gets drafted:

- **Swarm vs. deeper physics** — open fork, not yet decided. Scene is already
  built to instance `Drone` for swarm later (see AGENTS.md).
- **PID fine-tuning** — open, ongoing; see `AGENTS.md` → Known Issues for the
  current stabilized-mode jitter/stickiness writeup.
- **Sound simulation** — floated, but Tim is skeptical it's more than a gimmick.
  Low priority.
- **Weather** — Tim is skeptical beyond the wind already scoped in Phase D.
  Don't expand this without a concrete driver.
- **Doxygen-style docs** — wanted, so the codebase is self-explanatory at a
  glance. Good candidate for the "documentation after P2" pass already agreed
  on.
- **UI Menu** - DPad controlled 2D menu to control various flags of the 
  simulation similar to games like Forza Horizon or F1 Series.
