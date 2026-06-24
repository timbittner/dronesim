# DroneSim — Project Summary

A 3D drone flight simulator in **Godot 4.7 / GDScript** with **Jolt Physics**. Single drone, flyable with a PS5 DualSense controller. Procedural terrain, chase/FPV cameras, debug HUD.

Current phase: **P0 complete** — single flyable drone, two flight modes (acro + stabilized), procedural terrain, headless test harness.

---

## Scene Tree

Everything starts from `scenes/main.tscn`:

```
Main (Node3D)
├── Terrain (Node3D)
│   └── [TerrainMesh, TerrainBody]
├── SpawnPad (MeshInstance3D)
├── DirectionalLight3D
├── WorldEnvironment
├── Drone (RigidBody3D)
│   ├── Body (MeshInstance3D)
│   ├── RotorFL, RotorFR, RotorBL, RotorBR
│   ├── CameraMount
│   ├── CameraRig (Node3D)
│   ├── CollisionShape3D
│   └── DebugAxes (Node3D)
├── ChaseCamera (Camera3D)
└── DebugHUD (CanvasLayer)
```

---

## Script Architecture

### `scripts/drone/drone_controller.gd` — Core Controller (155 lines)

`DroneController extends RigidBody3D`. Physics loop:

```
_read_inputs()    → reads 4 axes from InputMap
_apply_thrust()   → central force along local Y (hover + user throttle)
_apply_torque()   → delegates to active flight mode
_apply_angular_damping() → light air resistance (0.5 factor)
```

**Currently uses `apply_central_force + apply_torque` model.** Next iteration migrates to per-rotor force vectors (see Next Session).

### `scripts/drone/flight_mode_base.gd` — Abstract Base (32 lines)

`FlightModeBase extends RefCounted`. Virtual methods:
- `compute_torque(pitch, roll, yaw, basis, angular_velocity, delta) -> Vector3`
- `get_mode_name() -> String`

### `scripts/drone/flight_mode_acro.gd` — Acro/Rate Mode (40 lines)

Direct torque mapping from stick input. No auto-leveling. Preserves original P0 behavior.

### `scripts/drone/flight_mode_stabilized.gd` — Stabilized (85 lines)

Two sub-modes:
- **Sticks centered:** PD auto-level using world-frame cross product (body_up × world_up) for rotation axis, acos for angle. P=15.0, D=4.0.
- **Sticks active:** Rate mode — stick input maps to target angular velocity.

**Known issue:** PD-on-torque approach oscillates with real thrust. Auto-level can produce ±23° roll hunting and terrain phasing. Planned replacement: per-rotor thrust vectoring.

### `scripts/camera/chase_camera.gd` — Camera (60 lines)

Two modes: FPV (rigidly locked to drone) and Chase (lerp behind, ignores pitch/roll tilt). Listens to `fpv_toggled` signal.

### `scripts/environment/terrain_generator.gd` — Terrain (procedural)

FastNoiseLite with Simplex + FBM, 500×500m, 250 divisions, flat spawn zone at origin.

### `scripts/test/flight_mode_test.gd` — Headless Test Harness (230 lines)

5 tests using `Input.action_press/release` + `await get_tree().physics_frame`:

| Test | What it verifies |
|---|---|
| Pitch self-level | 30° tilt → within 5° of level in 300 ticks |
| Roll self-level | 20° tilt → within 5° of level |
| Combined self-level | 25° pitch + -15° roll → both within 5° |
| Acro stays tilted | 30° pitch → still > 20° after 300 ticks |
| Input response | pitch_forward @ 50% → pitch angle > 2° |

Run: `godot --headless --path . scenes/test/flight_mode_test_scene.tscn`

---

## Flight Model (Current — Being Replaced)

**Central force + abstract torque:**
- `apply_central_force(basis.y * thrust)` — single upward force
- `apply_torque(basis * torque_vec)` — abstract rotation torque
- Hover throttle auto-computed: `(mass * gravity) / max_thrust`

**Pain points driving migration:**
- Oscillation between PD auto-level and thrust-generated rotation
- No natural differential thrust behavior
- Ground phasing on oscillation peaks

### Next: Per-Rotor Thrust Vectoring

Each rotor applies force at its position via `apply_force(position, direction * throttle)`:
- Pitch control: front/rear rotor speed differential
- Roll control: left/right rotor speed differential
- Yaw control: CW vs CCW rotor speed differential (drag torque)
- Auto-level: PID on rotor differential ratio, not abstract torque

---

## Flight Modes

| Mode | Stick input mapping | When centered |
|---|---|---|
| **Acro** | Direct torque (current behavior) | Nothing — stays in current orientation |
| **Stabilized** | Rate mode (target angular velocity) | PD auto-level toward upright |

Toggle with L1/R1.

---

## Input Map

| Action | DualSense | Keyboard |
|---|---|---|
| throttle_up / throttle_down | Left stick Y | W / S |
| yaw_left / yaw_right | Left stick X | A / D |
| pitch_forward / pitch_backward | Right stick Y | Up / Down |
| roll_left / roll_right | Right stick X | Left / Right |
| toggle_flight_mode | L1 (button 9) | M |
| toggle_fpv | R1 (button 10) | C |
| reset_drone | Triangle (button 3) | R |

Mode 2 layout: left stick = throttle + yaw, right stick = pitch + roll.

---

## Coordinates

- Godot right-handed: X+=right, Y+=up, Z+=back
- Drone forward = -Z (nose tip protrudes -Z, teal rotors at -Z)
- Debug axes: red=+X, green=+Y, blue=+Z
- **Note:** In current physics, -X torque = pitch UP (original code comment claiming opposite was incorrect — confirmed via headless tests)

---

## Extension Points

- **Flight modes:** New modes implement `FlightModeBase` interface
- **Per-rotor mixer:** New `_mix_rotors()` method replacing `_apply_thrust + _apply_torque`
- **Terrain:** Pluggable backend (noise → OSM later)
- **Drone scene:** Single drone instanced, swarm via multiple instances
- **Input mapping:** InputMap actions, not raw device codes

---

## Development

- Run: `godot --path .` (F6 in editor)
- Tests: `godot --headless --path . scenes/test/flight_mode_test_scene.tscn`
- GDScript files can be edited externally; Godot reloads on focus
- Scene files (.tscn) edit in Godot editor unless making targeted text edits
