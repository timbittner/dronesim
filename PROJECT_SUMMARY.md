# DroneSim — Project Summary

A 3D drone flight simulator in **Godot 4.7 / GDScript** with **Jolt Physics**.
Single drone, flyable with a PS5 DualSense controller. Procedural terrain,
chase/FPV cameras, debug HUD.

Current phase: **Per-rotor thrust vectoring complete** — both acro and stabilized
modes use individual rotor forces applied at each arm position. 10 headless tests pass.

---

## Scene Tree

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

### Three-Layer Flight Pipeline

```
FlightMode.compute()  →  FlightControl(collective, pitch_diff, roll_diff, yaw_torque)
DroneController._mix_rotors()  →  RotorMix(fl, fr, bl, br)  ← anti-clip scaling
Physics: apply_force() at 4 rotor positions + apply_torque() for yaw
```

### `scripts/drone/drone_controller.gd` — Core Controller (185 lines)

`DroneController extends RigidBody3D`. Physics loop:
```
_read_inputs()           → reads 4 axes from InputMap
_compute_and_apply_forces(delta)  → mode → mixer → rotor forces + yaw torque
_apply_angular_damping() → per-axis damping (0.08 pitch/roll, 1.0 yaw)
```

Hover throttle per-rotor: `(mass * gravity) / (4 * max_thrust)` = 0.098.

Static `_mix_rotors(collective, pitch, roll)` handles anti-clip scaling and
MIN_ROTOR (0.02) protection. Early-returns all zeros if collective < 0.001
(throttle cut kills motors).

### `scripts/drone/flight_mode_base.gd` — Abstract Base

`FlightModeBase extends RefCounted`. Virtual method:
- `compute(throttle, pitch, roll, yaw, basis, angular_velocity, delta) -> FlightControl`
- `get_mode_name() -> String`

Inner classes: `FlightControl` (collective, pitch_diff, roll_diff, yaw_torque)
and `RotorMix` (fl, fr, bl, br).

### `scripts/drone/flight_mode_acro.gd` — Acro/Rate Mode (40 lines)

Pure stick-to-differential mapping. No auto-leveling.
- `max_differential = 0.02` — rotor throttle offset per unit stick input
- `throttle_range = 0.15` — 1/4 of old central-force value (4 rotors)
- `yaw_torque_factor = 1.5` — Nm per unit yaw input

### `scripts/drone/flight_mode_stabilized.gd` — Stabilized (120 lines)

Two sub-modes:
- **Sticks active (>0.05 deadzone):** Rate mode — stick maps to target angular
  velocity (max 1.5 rad/s pitch/roll, 1.0 rad/s yaw), PD drives toward target
  with `rate_p_gain = 4.0`. Yaw uses direct stick-to-torque (same as acro),
  no rate PD.
- **Sticks centered:** PD auto-level using world-frame cross product
  (body_up × world_up) → angle → P gain. P gain blends from 0 at 0° to
  full at 1.5° to prevent limit-cycle jitter. D gain (4.0) always active.
  `stabilize_p_gain = 15.0`, `stabilize_d_gain = 4.0`.

### `scripts/camera/chase_camera.gd` — Camera

Two modes:
- **FPV:** Position rigidly locked to drone nose. Rotation smoothed via
  quaternion slerp (factor 0.92) to mask control-loop jitter without
  position drift.
- **Chase:** Lerp behind drone, yaw-only tracking (ignores pitch/roll tilt).

### `scripts/ui/debug_hud.gd` — Telemetry HUD

On-screen overlay: flight mode, FPV status, throttle %, stick inputs,
heading/pitch/roll angles, speed, altitude. Compact log every 60 frames.

### `scripts/test/flight_mode_test.gd` — Headless Test Harness (330 lines)

10 tests using `Input.action_press/release` + `await get_tree().physics_frame`:

| Test | Input | Verification |
|---|---|---|
| Pitch self-level | 30° tilt, 350 ticks | Within 5° of level |
| Roll self-level | 20° tilt, 350 ticks | Within 5° of level |
| Combined self-level | 25° pitch + -15° roll, 350 ticks | Both within 5° |
| Acro stays tilted | 30° pitch, 350 ticks | Still > 20° |
| Input response | pitch_forward @ 80%, 150 ticks | |pitch| > 2° |
| Acro holds pitch | 15% pitch, 15 ticks + 300 settle | |pitch| > 5° |
| Acro holds roll | 15% roll, 15 ticks + 300 settle | |roll| > 5° |
| Stabilized levels pitch | 15% pitch, 15 ticks + 300 settle | |pitch| < 5° |
| Stabilized levels roll | 15% roll, 15 ticks + 300 settle | |roll| < 5° |
| Roll→yaw coupling | 60% roll + 30% throttle, 30 ticks | heading delta < 45° |

Run: `godot --headless --path . scenes/test/flight_mode_test_scene.tscn`

---

## Flight Model

**Per-rotor thrust vectoring** (current):
- Each rotor at position (x, 0.07, z): force = `basis.y * throttle * max_thrust`
- `apply_force(force, global_basis * local_pos)` — physics engine computes
  torque from force offset (r × F)
- Yaw torque applied explicitly via `apply_torque` (rotor drag not from force offset)
- Anti-clip scaling prevents rotor saturation while preserving pitch/roll ratio
- Minimum rotor throttle (2%) prevents full cut-out during aggressive maneuvers
- Throttle cut (collective < 0.001) kills all rotors

---

## Flight Modes

| Mode | Stick input mapping | When centered |
|---|---|---|
| **Acro** | Direct differential mapping | Nothing — stays in current orientation |
| **Stabilized** | Rate mode (target angular velocity, P=4.0) | Blended PD auto-level toward upright |

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
| toggle_fpv | R2 (button 10) | C |
| reset_drone | Triangle (button 3) | R |

Mode 2 layout: left stick = throttle + yaw, right stick = pitch + roll.

---

## Known Issues

- **Auto-level jitter:** Sub-degree oscillations on pitch/roll near level
  persist despite blended P gain and angular damping. Likely needs D-term
  filtering on gyro measurement (vs on error) to fully eliminate.
- **Roll→yaw coupling during aggressive dives:** Brief yaw deflection when
  pitching aggressively at high throttle. Not compensated — real physics effect.

---

## Tuning Parameters

| Parameter | Location | Value |
|---|---|---|
| max_thrust (per rotor) | drone_controller.gd | 50.0 N |
| hover_throttle (per rotor) | drone_controller.gd | 0.098 (auto) |
| Angular damping | drone_controller.gd | (0.08, 1.0, 0.08) |
| MIN_ROTOR | drone_controller.gd | 0.02 |
| Acro max_differential | flight_mode_acro.gd | 0.02 |
| Acro throttle_range | flight_mode_acro.gd | 0.15 |
| Acro yaw_torque_factor | flight_mode_acro.gd | 1.5 |
| Stab P gain | flight_mode_stabilized.gd | 15.0 |
| Stab D gain | flight_mode_stabilized.gd | 4.0 |
| Stab rate_P gain | flight_mode_stabilized.gd | 4.0 |
| Stab max rates | flight_mode_stabilized.gd | 1.5 / 1.5 / 1.0 rad/s |
| Stab input deadzone | flight_mode_stabilized.gd | 0.05 |
| Stab angle deadzone | flight_mode_stabilized.gd | 1.5° (blended) |
| FPV rotation smoothing | chase_camera.gd | 0.92 |
