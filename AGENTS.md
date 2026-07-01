# DroneSim — Project Guide

## What This Is

A 3D drone flight simulator built in Godot 4.7 / GDScript. Started as a
vibe-coding playground with the intent to iterate into a drone swarm simulator
with realistic flight physics, autonomous routing, weather, and threat simulation.

**Current phase:** Per-rotor thrust vectoring complete, plus assisted flight
modes (altitude hold + brake) and crash / signal loss (P2 Phase C). Both acro
and stabilized modes use individual rotor forces applied at each arm position.
See `PROJECT_SUMMARY.md` for detailed architecture and tuning parameters.

## Tech Stack

- **Engine:** Godot 4.7
- **Language:** GDScript
- **Physics:** Jolt Physics (3D)
- **Renderer:** gl_compatibility (low-poly aesthetic, lightweight, VR-friendly later)
- **Controller:** DualSense (PS5) via Godot input system
- **Godot MCP:** `@coding-solo/godot-mcp` available for editor automation
  (run/stop scenes, read debug output — use it to syntax-check GDScript)
- **Blender MCP:** available in this workspace for driving Blender directly
  (inspect/edit `drone_parts.blend`, re-export GLBs) when connected

## Architecture

```
scenes/
  main.tscn              Root scene
  drone/drone.tscn        Drone instance
  environment/terrain.tscn
  test/                   Headless test scenes
    flight_mode_test_scene.tscn
scripts/
  drone/
    drone_controller.gd          Core controller — input, mixer, damping,
                                 crash detection + FLYING/CRASHED state
    flight_mode_base.gd          Abstract base — FlightControl, RotorMix
    flight_mode_acro.gd          Idle-floor throttle + expo differential, no auto-level
    flight_mode_stabilized.gd    PD auto-level + rate mode
    flight_mode_altitude_hold.gd Post-compute collective filter (not a mode)
    brake_assist.gd              Rotor-thrust tilt brake (assist, not a mode)
    drone_body_mesh.gd           Procedural rhombic body (RETIRED — superseded
                                 by drone_body.glb; kept for reference only)
    debug_axes.gd                RGB orientation arrows
  camera/
    chase_camera.gd              FPV + chase camera (FPV rotation smoothed)
  environment/
    terrain_generator.gd         Procedural noise terrain
    crash_effects.gd             Dust burst on crash (listens to crash_detected)
  ui/
    debug_hud.gd                 Telemetry overlay
  test/
    flight_mode_test.gd          15 headless tests
assets/
  materials/
  models/
    drone_parts.blend            Source: full drone (body, 4 arms, 4 props)
    drone_body.glb               Exported body mesh (Mat_body); nose faces +Y
                                 in Blender → Godot −Z (forward)
    arm.glb                      Exported single arm mesh (Mat_arm)
    propeller.glb                Front prop (Mat_prop_front, cyan) + back prop
                                 (Mat_prop_back, pink) for orientation
  textures/
```

### Drone geometry

The drone's body, arms, and propellers are authored in Blender
(`drone_parts.blend`) and exported as GLB. `drone.tscn` holds bare `Node3D`
marker nodes (Body, RotorFL/FR/BL/BR, ArmFL/FR/BL/BR) at the correct local
transforms — markers rather than `MeshInstance3D` so the editor shows no
"missing mesh" warnings. `DroneController._setup_visuals()` loads each GLB and
attaches its mesh as a `MeshInstance3D` child of the matching marker at runtime. Front rotors (FL/FR) use the
cyan `Mat_prop_front` prop, back rotors (BL/BR) the pink `Mat_prop_back` prop,
for at-a-glance orientation. When armed (throttle > 0) each rotor swaps its prop
for a translucent blur disc built in code, tinted to that prop's color. Static
prop colors are authored in Blender; the spin-disc color is derived from them in
`DroneController._setup_visuals()`.

### Flight Pipeline

```
Mode.compute() → FlightControl(collective, pitch_diff, roll_diff, yaw_torque)
       ↓
_mix_rotors()  → RotorMix(fl, fr, bl, br)  ← anti-clip scaling, MIN_ROTOR
       ↓
apply_force() at 4 rotor positions + apply_torque() for yaw
       ↓
_apply_angular_damping()  ← per-axis damping
```

### Crash / signal loss (P2 Phase C)

`DroneController` has two states: `FLYING` and `CRASHED`. Detection lives in
`_integrate_forces` — not the `body_entered` signal, which carries no contact
normal (contact reporting needs `contact_monitor = true` +
`max_contacts_reported = 4` on the RigidBody3D, set in `drone.tscn` along with
`continuous_cd = true` — without CCD the thin drone body tunnels through
geometry above ~10 m/s, which fast dives easily exceed). A contact
crashes only if impact momentum exceeds `crash_momentum_threshold` (8 kg·m/s
≈ 4 m/s; the spawn free-fall onto the pad arrives at ~6.1, which must bounce)
**and** the hit is direct (−velocity within `crash_max_impact_angle_deg` = 60°
of the contact normal); anything slower or more grazing just bounces. The
impact velocity is `_prev_velocity` (cached each physics tick) because the
solver has already absorbed the impact from `linear_velocity` by the time the
contact is reported.

On crash the "signal" is lost: rotor forces stop (physics tumbles the airframe
naturally — no magic forces), inputs are ignored except **Triangle** (reset)
and **R1** (camera toggle — the camera belongs to the pilot, not the dead
drone; L1 mode toggle is ignored). The HUD shows a pulsing SIGNAL LOST banner.
The FPV *feed* dies at the crash instant: crash in FPV → the last rendered
frame stays frozen on screen; crash in 3PV → no frame was captured, so
switching to FPV shows a black "no signal" screen. Chase cam always renders
live. Reset restores everything.

Environment-side crash effects (a ~5m white-sand dust burst that hangs for
~10-13s at the impact point) live in `scripts/environment/crash_effects.gd`,
a `Node3D` in `main.tscn` that listens to the drone's `crash_detected` signal —
the controller owns flight/crash logic only; what the world does in response
does not belong in it. The dust emits in world space (`top_level`), so it stays
put while the wreck tumbles. Purely visual, no collision or forces.

### Extension Points

- **Flight modes:** New modes implement `FlightModeBase.compute()` interface
- **Terrain generator:** Pluggable backend (noise-based now, OSM-based later)
- **Drone scene:** Single drone now, instanced for swarm later
- **Input mapping:** Godot InputMap actions, not hardcoded device codes

## Conventions

- **File naming:** snake_case for all files (scenes, scripts, assets)
- **Script class naming:** PascalCase (e.g., `DroneController`)
- **Scene root nodes:** PascalCase (e.g., `Main`, `Drone`, `Terrain`)
- **Signals:** snake_case past tense (e.g., `crash_detected`, `mode_changed`)
- **Physics:** All drone physics in `_physics_process`, not `_process`
- **Input:** Always use `Input.get_action_strength` for analog sticks
- **Commits:** Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`)

## Coordinate System (CANONICAL — read this before touching rotors, pitch, or roll)

Godot is **right-handed, Y-up**. This is the single source of truth. Do not
re-derive it from the code — the code conforms to this, not the other way around.

| Direction        | Local axis | Notes                          |
|------------------|-----------|---------------------------------|
| Right            | **+X**    | Left = −X                       |
| Up               | **+Y**    | Down = −Y                       |
| **Forward (nose)** | **−Z**  | **Back / tail = +Z**            |

Debug gizmo (`debug_axes.gd`): red = +X (right), green = +Y (up), blue = +Z
(**back**). The nose points **away** from the blue arrow.

Blender → Godot import: Blender is Z-up (forward = −Y, up = +Z). Godot's importer
rotates −90° about X, so Blender −Y → Godot −Z (forward) and Blender +Z → Godot
+Y (up). Model the nose toward Blender −Y and it lands on Godot −Z.

### Rotor / arm layout (positions are ground truth; names follow positions)

Quad-X. Looking from above, nose up the page:

```
        nose (−Z)
     FL o       o FR      FL/FR = front = teal
        \       /
         \     /
          drone            +X → (right)
         /     \
        /       \
     BL o       o BR      BL/BR = back  = pink
        tail (+Z)
```

| Rotor | Local position (x, y, z) | Color |
|-------|--------------------------|-------|
| FL    | (−0.25, 0.07, **−0.25**) | teal  |
| FR    | (+0.25, 0.07, **−0.25**) | teal  |
| BL    | (−0.25, 0.07, **+0.25**) | pink  |
| BR    | (+0.25, 0.07, **+0.25**) | pink  |

Mixer signs (`drone_controller.gd::_mix_rotors`) follow directly:
- **Pitch:** positive = nose up → **front** rotors (FL, FR) get *more* thrust.
- **Roll:** positive = roll right → **left** rotors (FL, BL) get *more* thrust.

The `_rotor_positions` array order is `[FL, FR, BL, BR]` and the mixer output
`[fl, fr, bl, br]` maps to it index-for-index. Keep those two in the same order.

## Development

- Godot editor must be open when using MCP tools (auto-import on file changes)
- GDScript files can be edited externally; Godot reloads on focus
- Scene files (.tscn) should be edited in the Godot editor unless making targeted text edits
- **Run tests:** `godot --headless --path . scenes/test/flight_mode_test_scene.tscn`
- **Run game:** F6 in editor or `godot --path .`

## Controller Layout (Mode 2)

| Stick | Direction | Action |
|---|---|---|
| Left | Up/Down | Throttle (climb/descend) |
| Left | Left/Right | Yaw (rotate) |
| Right | Up/Down | Pitch (forward/back) |
| Right | Left/Right | Roll (tilt left/right) |
| L1 | Press | Toggle flight mode (acro ↔ stabilized) |
| R1 | Press | Toggle FPV camera |
| L2 | Hold (analog) | Altitude hold — replaces collective with a PD hover hold; pitch/roll/yaw pass through |
| R2 | Hold (analog) | Brake — tilts the airframe via rotor thrust to oppose horizontal velocity (adds to, doesn't override, pitch/roll from stick/mode); composes with altitude hold (brake = horizontal, altitude hold = vertical) |
| Triangle | Press | Reset drone (also recovers from a crash / SIGNAL LOST) |

While CRASHED only Triangle (reset) and R1 (camera toggle) are handled — L1 and
all stick input are dead until reset.

Keyboard fallback: Shift = altitude_hold, Ctrl = brake_mode (see other actions'
keyboard bindings in `project.godot`).

**L2/R2 are analog axes, not buttons.** In Godot's abstracted joypad model,
L2/R2 report as `InputEventJoypadMotion` on axis 4/5 (SDL `TRIGGER_LEFT`/
`TRIGGER_RIGHT`), not `InputEventJoypadButton`. Binding them as
`button_index` 6/7 (as an earlier draft of this project did) silently binds
to Start/L3-click instead — the action never fires on a real controller, with
no error. If a future trigger-based action seems to do nothing despite a
correct-looking `project.godot` entry, check this first.

## Known Issues

- **Roll→yaw coupling during aggressive dives** — real physics effect
  (pitching hard at high throttle briefly deflects yaw), not currently
  compensated. The headless test for this
  (`test_stabilized_roll_does_not_induce_yaw_spin`) only asserts the coupling
  stays bounded (<45° heading delta), not that it's absent.
- **Stabilized mode "jump" when releasing stick near level**
  (`flight_mode_stabilized.gd`): rate-mode (stick active) and auto-level
  (stick released) are two entirely different control laws — rate-PD on
  angular velocity (`rate_p_gain = 4.0`) vs. angle-PD in world frame
  (`stabilize_p_gain = 15.0`, ~4x stronger gain-equivalent at the same tilt).
  The switch at `input_deadzone = 0.05` is a hard binary swap with no
  blending, so releasing the stick while still tilted can produce a visible
  torque discontinuity ("snap" into level) as the controller jumps from a
  modest rate-correction to a much more aggressive angle-correction. This is
  compounded by `_apply_angular_damping()` in `drone_controller.gd` damping
  the **raw** angular velocity every tick, stacked on the flight mode's own
  D-term which uses the **filtered** angular velocity — a brief mismatch
  right at the mode-switch instant. Likely fix: blend between the two
  control laws across the deadzone instead of hard-switching.
- **Stabilized mode feels "sticky" near level under active stick input**
  (`flight_mode_stabilized.gd`): the gyro low-pass filter
  (`gyro_filter_alpha = 0.35`, added to fix PD limit-cycle jitter) is reused
  for the rate-mode branch's `rate_error = target_rate - local_ang_vel`, not
  just the auto-level D-term. That filter adds ~1-2 frames of lag to the
  pilot's own control feedback loop. Near level, commanded rates from small
  stick deflections are already tiny, so the lag is proportionally more
  noticeable there than during large, fast stick inputs — reads as
  sluggish/resistant response. Likely fix: use two separate filtered signals
  — heavily-filtered for auto-level's D-term (noise rejection), raw or
  lightly-filtered for rate-mode's feedback (responsiveness).

## License

Private project. No license file needed yet.
