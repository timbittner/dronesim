# DroneSim — Project Summary

A 3D drone flight simulator in **Godot 4.7 / GDScript** with **Jolt Physics**.
Single drone, flyable with a PS5 DualSense controller. Procedural terrain,
chase/FPV cameras, debug HUD.

Current phase: **Per-rotor thrust vectoring complete**, plus **Phase B assisted
flight modes** (altitude hold + brake) and **Phase C crash / signal loss** —
both acro and stabilized modes use individual rotor forces applied at each arm
position; hard impacts kill the "signal" (rotors cut, physics tumbles the
airframe, SIGNAL LOST overlay, frozen FPV feed). 15 headless tests pass.

---

## Scene Tree

```
Main (Node3D)
├── Terrain (Node3D)
│   └── [TerrainMesh, TerrainBody]
├── SpawnPad (MeshInstance3D)
├── DirectionalLight3D
├── WorldEnvironment
├── Drone (RigidBody3D)          # geometry from Blender GLBs (see below)
│   ├── Body (MeshInstance3D)
│   ├── RotorFL, RotorFR, RotorBL, RotorBR
│   ├── ArmFL, ArmFR, ArmBL, ArmBR
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

### `scripts/drone/drone_controller.gd` — Core Controller

`DroneController extends RigidBody3D`. Physics loop:
```
_read_inputs()           → reads 4 axes + altitude_hold/brake_mode from InputMap
_compute_and_apply_forces(delta)  → mode → altitude-hold filter → brake tilt add-on → mixer → rotor forces + yaw torque
_apply_angular_damping() → per-axis damping (0.08 pitch/roll, 1.0 yaw)
```

Hover throttle per-rotor: `(mass * gravity) / (4 * max_thrust)`.

Static `_mix_rotors(collective, pitch, roll)` handles anti-clip scaling and
MIN_ROTOR (0.02) protection. Early-returns all zeros if collective < 0.001
(throttle cut kills motors).

**Crash / signal loss (Phase C):** two states, `FLYING` / `CRASHED`. Detection
lives in `_integrate_forces` (not `body_entered` — that signal carries no
contact normal): requires `contact_monitor = true` + `max_contacts_reported = 4`
on the RigidBody3D (set in `drone.tscn`, along with `continuous_cd = true` —
without CCD the 0.12m-thin drone tunnels straight through thin geometry above
~10 m/s, which fast dives easily exceed). A contact crashes iff impact momentum
(`_prev_velocity.length() * mass`, previous-tick velocity since the solver has
already absorbed the impact by report time) exceeds `crash_momentum_threshold`
(8 kg·m/s ≈ 4 m/s — the spawn free-fall onto the pad arrives at ~6.1, so the
threshold must stay above that) **and** the hit is direct (angle between
−velocity and contact normal
within `crash_max_impact_angle_deg`, 60°); slow or grazing contacts bounce. A
near-zero-velocity guard covers resting contact on the spawn pad. On crash:
state → CRASHED, `crash_detected` emitted, inputs zeroed, rotor visuals to idle,
and a one-shot white-sand dust burst (`CPUParticles3D`, built in code) expands
to ~5m at the impact point — world-space + top_level, so it stays put while the
wreck tumbles away. Purely visual.
While CRASHED, `_physics_process` skips inputs/forces/damping — gravity and
inertia tumble the airframe naturally (no magic forces). Only `reset_drone`
(Triangle) and `toggle_fpv` (R1 — the camera belongs to the pilot, not the dead
drone) are handled; `toggle_flight_mode` is ignored. `reset()` restores FLYING.

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

### `scripts/drone/flight_mode_altitude_hold.gd` — Altitude Hold (assist, not a mode)

`FlightModeAltitudeHold extends RefCounted`. Not selectable like acro/stabilized —
`DroneController` calls `update()` after the active mode's `compute()` and, while
`altitude_hold` (L2 / Shift) is held, replaces `control.collective` wholesale with
classic PD-on-altitude: `hover_throttle + P * (target_altitude - current_y) -
D * linear_velocity.y`, target altitude captured on engage. Pitch/roll/yaw pass
through untouched. On release, blends from the last hold collective back to the
pilot's live collective over 0.3s (internal state machine: IDLE → HOLDING →
BLENDING → IDLE).

An earlier version instead did P on velocity-error (target rate = 0) with a
finite-differenced "acceleration" D-term (RigidBody3D has no acceleration
signal). Dividing that finite difference by the ~1/60s physics delta amplified
per-tick noise ~20x, causing a bang-bang oscillation between 0% and ~50%
thrust (visible as HUD throttle flicker and the prop mesh flipping between
idle/spin-disc every frame). PD-on-altitude needs no differentiation at all —
`linear_velocity.y` is already the natural derivative of altitude — so this
class of instability can't happen, and it holds the engaged altitude against
disturbance rather than merely zeroing climb rate wherever the drone is.

### `scripts/drone/brake_assist.gd` — Brake (assist, not a mode, not a magic force)

`BrakeAssist extends RefCounted`. Rotor-thrust-only — no `apply_central_force`
shortcut. While `brake_mode` (R2 / Ctrl) is held, computes the horizontal
deceleration needed (`-horizontal_vel / brake_time`), converts it to a target
airframe tilt via the small-angle relation `a ≈ g·tan(θ)` (solved with
`atan2` so it saturates instead of diverging, clamped to `max_tilt_deg`), then
reuses stabilized mode's exact auto-level technique — restoring torque from
`body_up.cross(target_up)` — pointed at that tilted target instead of literal
world-up. This reuses the already-tested pitch/roll sign conventions instead
of re-deriving them. The resulting `(pitch_diff, roll_diff)` is **added** to
whatever the active flight mode already computed (blends with pilot stick
input and stabilized's own auto-level, doesn't override them — the drone
brakes by tilting into the wind and letting real rotor thrust do the work,
same as a real quad). Vertical velocity untouched; composes with altitude
hold (brake owns horizontal, altitude hold owns vertical).

### `scripts/camera/chase_camera.gd` — Camera

Two modes:
- **FPV:** Position rigidly locked to drone nose. Rotation smoothed via
  quaternion slerp (factor 0.92) to mask control-loop jitter without
  position drift.
- **Chase:** Lerp behind drone, yaw-only tracking (ignores pitch/roll tilt).

### `scripts/ui/debug_hud.gd` — Telemetry HUD

On-screen overlay: flight mode, FPV status, altitude-hold/brake assist
indicators, throttle %, stick inputs, heading/pitch/roll angles, speed,
altitude. Compact log every 60 frames.

**Signal-loss overlay (Phase C):** on `crash_detected`, a pulsing red
"⚠ SIGNAL LOST" banner appears and telemetry dims. The FPV *feed* dies at the
crash instant: if the crash happened in FPV, the last rendered frame is captured
(`get_viewport().get_texture().get_image()`) and frozen fullscreen; if it
happened in chase cam, no frame was ever captured, so entering FPV afterwards
shows a plain black "no signal" screen. Chase cam always renders live — R1
during a crash bails from the dead feed to watch the wreck. Reset (polled via
`is_crashed()`) clears everything.

### `scripts/test/flight_mode_test.gd` — Headless Test Harness

15 tests using `Input.action_press/release` + `await get_tree().physics_frame`:

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
| Altitude hold | Engage at 500m with -3 m/s sink, 200 ticks | Within 0.5m of engage altitude, |vel| < 1 m/s |
| Brake | Inject (5, 0, 3) m/s, brake 180 ticks (~3s, tilt-based) | Speed < 50% of initial |
| Crash on hard impact | Drop at -12 m/s onto ground | is_crashed() true |
| Gentle landing | Acro throttle-cut settle at ~1.7 m/s | No crash |
| Reset clears crash | Crash, reset(), 5 ticks | FLYING, near spawn |

Run: `godot --headless --path . scenes/test/flight_mode_test_scene.tscn`
(or `./run_tests.sh`)

---

## Drone Geometry

Body, arms, and propellers are authored in Blender (`assets/models/drone_parts.blend`)
and exported as GLB (`drone_body.glb`, `arm.glb`, `propeller.glb`). `drone.tscn`
is bare `Node3D` marker nodes at the correct transforms (markers, so the editor
shows no "missing mesh" warnings); `DroneController._setup_visuals()` attaches the
GLB meshes as `MeshInstance3D` children at runtime. Front props
(FL/FR) are cyan, back props (BL/BR) pink for orientation; when armed each rotor
swaps to a code-built blur disc tinted to its prop color. The body nose faces −Z
(forward). The old procedural `drone_body_mesh.gd` is retired.

## Coordinate System

Godot right-handed, Y-up: **forward (nose) = −Z**, right = +X, up = +Y. Rotors
are quad-X, named by physical position: **FL/FR at the nose (−Z)**, BL/BR at the
tail (+Z). The full canonical table (with the mixer sign rationale) lives in
**AGENTS.md → "Coordinate System"** — treat that as the single source of truth.

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

**Assists** (compose with either mode, held not toggled): altitude hold
(L2/Shift) replaces collective with a PD hover hold; brake (R2/Ctrl) adds a
rotor-thrust tilt on top of whatever pitch/roll the mode already commands, to
oppose horizontal velocity — no out-of-band forces, blends with pilot input
rather than overriding it. Both can be held together — brake owns horizontal,
altitude hold owns vertical.

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
| altitude_hold (hold) | L2 (axis 4, analog trigger) | Shift |
| brake_mode (hold) | R2 (axis 5, analog trigger) | Ctrl |
| reset_drone | Triangle (button 3) | R |

Mode 2 layout: left stick = throttle + yaw, right stick = pitch + roll.
L2/R2 are held-trigger assists (altitude hold / brake), not toggles. L2/R2 are
analog **axis** events (`InputEventJoypadMotion`, axis 4/5 = SDL
TRIGGER_LEFT/TRIGGER_RIGHT), not button events — an earlier version of this
binding incorrectly used `InputEventJoypadButton` with `button_index` 6/7,
which in Godot's abstracted `JoyButton` enum are Start and L3-click, not the
triggers, so the actions never fired on a real controller.

---

## Known Issues

- **Auto-level jitter:** Sub-degree oscillations on pitch/roll near level
  persist despite blended P gain and angular damping. Likely needs D-term
  filtering on gyro measurement (vs on error) to fully eliminate.
- **Roll→yaw coupling during aggressive dives:** Brief yaw deflection when
  pitching aggressively at high throttle. Not compensated — real physics effect.
- **`reset_drone` occasionally needs a held press, not a tap:** mitigated
  (lower deadzone + physics-tick polling fallback) but not yet confirmed
  fixed against real hardware. See AGENTS.md "Known Issues" for the full
  writeup.

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
| Crash momentum threshold | drone_controller.gd | 8.0 kg·m/s |
| Crash max impact angle | drone_controller.gd | 60° |
| Altitude hold P gain | flight_mode_altitude_hold.gd | 0.15 |
| Altitude hold D gain | flight_mode_altitude_hold.gd | 0.3 |
| Altitude hold release blend time | flight_mode_altitude_hold.gd | 0.3 s |
| Brake P gain | brake_assist.gd | 6.0 |
| Brake D gain | brake_assist.gd | 1.5 |
| Brake max tilt | brake_assist.gd | 25° |
| Brake time constant | brake_assist.gd | 1.0 s |
