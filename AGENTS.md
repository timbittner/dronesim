# DroneSim — Project Guide

## What This Is

A 3D drone flight simulator built in Godot 4.7 / GDScript. Started as a
vibe-coding playground with the intent to iterate into a drone swarm simulator
with realistic flight physics, autonomous routing, weather, and threat simulation.

**Current phase:** Per-rotor thrust vectoring complete. Both acro and stabilized
modes use individual rotor forces applied at each arm position. See
`PROJECT_SUMMARY.md` for detailed architecture and tuning parameters.

## Tech Stack

- **Engine:** Godot 4.7
- **Language:** GDScript
- **Physics:** Jolt Physics (3D)
- **Renderer:** gl_compatibility (low-poly aesthetic, lightweight, VR-friendly later)
- **Controller:** DualSense (PS5) via Godot input system
- **Godot MCP:** `@coding-solo/godot-mcp` available for editor automation

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
    drone_body_mesh.gd           Procedural rhombic body
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
  textures/
```

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
| L1/R1 | Toggle | Switch flight mode |
| R2 | Hold | Toggle FPV camera |

## Known Issues

- Small sub-degree jitter on pitch/roll near level in stabilized mode (limit
  cycle from the PD controller interacting with physics stepping). D-term
  filtering or gyro LPF would help.
- Roll→yaw coupling during aggressive dives — real physics effect, not
  currently compensated.

## License

Private project. No license file needed yet.
