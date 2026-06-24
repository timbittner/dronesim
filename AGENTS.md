# DroneSim — Project Guide

## What This Is

A 3D drone flight simulator built in Godot 4.7 / GDScript. Started as a vibe-coding
playground with the intent to iterate into a drone swarm simulator with realistic
flight physics, autonomous routing, weather, and threat simulation.

**Current phase:** P0 complete — flyable single drone. P1 stabilized mode implemented
but oscillates under load (PD-on-torque approach has fundamental issues).
**Next phase (per-rotor thrust vectoring):** See "Session Start: Per-Rotor Migration" below.
The plan: replace central-force + abstract-torque with individual rotor force vectors
applied at each arm position. Acro first, then stabilized on top of the real physics.

## Tech Stack

- **Engine:** Godot 4.7
- **Language:** GDScript
- **Physics:** Jolt Physics (3D)
- **Renderer:** gl_compatibility (low-poly aesthetic, lightweight, VR-friendly later)
- **Controller:** DualSense (PS5) via Godot input system
- **Godot MCP:** `@coding-solo/godot-mcp` available for editor automation

## MVP Scope

- One drone, RigidBody3D-based, flyable with gamepad
- Two flight modes: **Stabilized** (auto-levels on stick release) and **Acro** (full manual rate control)
- Procedural noise terrain (seed-based, flat spawn pad)
- Chase camera with FPV toggle
- DualSense controller input (Mode 2: left stick = throttle/yaw, right stick = pitch/roll)
- Headless test suite (`scenes/test/`) — 5 tests pass

### Out of Scope (Future Layers)

| Feature | Notes |
|---|---|
| Swarm simulation | Multiple drones, formation flying, swarm behaviors |
| OSM terrain | Real-world terrain from OpenStreetMap data |
| Weather | Wind, rain, visibility degradation |
| Threat simulation | Obstacles, no-fly zones, detection systems |
| AI input enhancement | Computer-assisted steering, PID tuning assist |
| VR mode | Stereo rendering, head tracking |
| DualSense features | Tilt steering, haptic feedback, adaptive triggers |

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
    drone_controller.gd          Core controller
    flight_mode_base.gd          Abstract base for modes
    flight_mode_acro.gd          Direct torque (current behavior)
    flight_mode_stabilized.gd    PD auto-level (to be replaced)
    drone_body_mesh.gd           Procedural rhombic body
    debug_axes.gd                RGB orientation arrows
  camera/
    chase_camera.gd              FPV + chase camera
  environment/
    terrain_generator.gd         Procedural noise terrain
  ui/
    debug_hud.gd                 Telemetry overlay
  test/
    flight_mode_test.gd          5 headless tests
assets/
  materials/
  models/
  textures/
```

### Extension Points

- **Flight modes:** New modes implement `FlightModeBase.compute_torque()` interface.
  Planned: per-rotor mixer replaces this with direct force-per-rotor calculation.
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

## License

Private project. No license file needed yet.

---

## Session Start: Per-Rotor Thrust Vectoring

**Goal:** Replace the current `apply_central_force + apply_torque` model with individual
rotor forces. Each rotor applies thrust at its position on the drone, creating pitch,
roll, and yaw torque naturally through speed differentials.

### Phase 1: Acro Mode (Pure Mixer)

1. Add a **rotor mixer** function to `drone_controller.gd`: `_mix_rotors(inputs) → array[4]`
2. Each rotor position is defined in `drone.tscn`:
   - FL: (-0.25, 0.07, 0.25), FR: (0.25, 0.07, 0.25) — pink (rear)
   - BL: (-0.25, 0.07, -0.25), BR: (0.25, 0.07, -0.25) — teal (front)
3. Acro mixer: left stick Y = collective throttle, right stick = differential speed
   - Pitch forward: front rotors (teal) faster, rear (pink) slower
   - Roll right: right rotors faster, left slower
   - Yaw: CW rotors faster vs CCW rotors → drag torque
4. Remove `_apply_thrust()`, `_apply_torque()`, `_apply_angular_damping()`
5. Keep `FlightModeAcro` but change its interface from `compute_torque` → `mix_rotors`
6. Update test harness: acro tests now assert rotation under differential thrust
7. Fly it. Should feel identical to current acro but with correct physics.

### Phase 2: Stabilized Mode (On Top of Mixer)

8. `FlightModeStabilized.mix_rotors()` computes rotor speeds directly:
   - Base: collective hover throttle on all 4 rotors
   - Pitch correction: front/rear speed offset proportional to pitch angle
   - Roll correction: left/right speed offset proportional to roll angle
   - Yaw correction: CW/CCW speed offset proportional to yaw rate
   - PID gains tune the offsets, not abstract torque
9. Remove PD-on-torque code entirely. Replace with PD-on-rotor-differential.
10. Update test assertions. Stabilized tests should now converge cleanly without oscillation.

### File Changes Summary

| File | Action |
|---|---|
| `drone_controller.gd` | Remove `_apply_thrust`, `_apply_torque`, `_apply_angular_damping`. Add `_mix_rotors`. |
| `flight_mode_base.gd` | Change virtual method from `compute_torque` → `mix_rotors(inputs) -> RotorMix` |
| `flight_mode_acro.gd` | Rewrite as mixer. Direct differential mapping. |
| `flight_mode_stabilized.gd` | Rewrite as mixer. PD on rotor differentials, not torque. |
| `flight_mode_test.gd` | Update test cases. Acro tests verify differential rotation. Stabilized tests verify convergence. |

### Data Structure

```gdscript
struct RotorMix:
    var fl: float  # 0.0..1.0 throttle
    var fr: float
    var bl: float
    var br: float
```

Each force: `apply_force(rotor_position, basis.y * rotor_throttle * max_thrust)`
