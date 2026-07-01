# DroneSim — Project Guide

## What This Is

A 3D drone flight simulator built in Godot 4.7 / GDScript. Started as a
vibe-coding playground with the intent to iterate into a drone swarm simulator
with realistic flight physics, autonomous routing, weather, and threat simulation.

**Current phase:** Per-rotor thrust vectoring complete, plus assisted flight
modes (altitude hold + brake). Both acro and stabilized modes use individual
rotor forces applied at each arm position. See `PROJECT_SUMMARY.md` for
detailed architecture and tuning parameters.

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
    drone_controller.gd          Core controller — input, mixer, damping
    flight_mode_base.gd          Abstract base — FlightControl, RotorMix
    flight_mode_acro.gd          Direct differential mapping
    flight_mode_stabilized.gd    PD auto-level + rate mode
    flight_mode_altitude_hold.gd Post-compute collective filter (not a mode)
    drone_body_mesh.gd           Procedural rhombic body (RETIRED — superseded
                                 by drone_body.glb; kept for reference only)
    debug_axes.gd                RGB orientation arrows
  camera/
    chase_camera.gd              FPV + chase camera (FPV rotation smoothed)
  environment/
    terrain_generator.gd         Procedural noise terrain
  ui/
    debug_hud.gd                 Telemetry overlay
  test/
    flight_mode_test.gd          10 headless tests
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
| Triangle | Press | Reset drone |

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

- Roll→yaw coupling during aggressive dives — real physics effect, not
  currently compensated.
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
- **`reset_drone` (Triangle) sometimes needs a held press, not a tap**
  (`project.godot`, `drone_controller.gd`): investigated for Tim — ruled out
  the "event consumed elsewhere" theory (grepped the whole project: the only
  `_unhandled_input` handler is in `drone_controller.gd`, and no `Control`
  node grabs focus, so nothing upstream can be swallowing the event).
  Leading theory is deadzone-related: Apple's GameController framework (macOS
  DualSense driver) reports even digital face buttons with an analog
  `.value`, which Godot likely surfaces as `pressure` on
  `InputEventJoypadButton`; the action's `deadzone: 0.5` gated
  `is_action_pressed()` on that pressure crossing 0.5, so a very quick tap
  that releases before the reported value ramps past 0.5 never registers as
  "pressed" at all. Mitigated two ways: lowered `reset_drone`'s deadzone to
  0.2 (still filters noise-floor values but tolerates a much lighter/quicker
  press), and added an `Input.is_action_just_pressed("reset_drone")` poll in
  `_physics_process` alongside the existing `_unhandled_input` edge trigger,
  so a missed discrete event still gets caught the next physics tick
  (`reset()` is idempotent, so double-firing in one frame is harmless). Not
  independently confirmed against real hardware since this requires the
  physical DualSense — report back if it still needs a hold after this fix.

## License

Private project. No license file needed yet.
