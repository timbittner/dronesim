# DroneSim — Project Summary

A 3D drone flight simulator in **Godot 4.7 / GDScript** with **Jolt Physics**. Single drone, flyable with a PS5 DualSense controller. Procedural terrain, chase/FPV cameras, debug HUD.

---

## Scene Tree (the "Unity Hierarchy" equivalent)

Everything starts from **`scenes/main.tscn`**. Here's the tree, roughly:

```
Main (Node3D)                              <-- root of the whole game
├── Terrain (Node3D)                       <-- terrain_generator.gd attached
│   └── [TerrainMesh, TerrainBody]         <-- generated at runtime by the script
├── SpawnPad (MeshInstance3D)              <-- flat box at origin where you start
├── DirectionalLight3D                     <-- sun with shadows
├── WorldEnvironment                       <-- sky + fog + ambient light
├── Drone (RigidBody3D)                    <-- drone_controller.gd attached
│   ├── Body (MeshInstance3D)              <-- drone_body_mesh.gd -- procedural rhombic prism
│   ├── RotorFL, RotorFR, RotorBL, RotorBR <-- teal forward (-Z), pink rear (+Z)
│   ├── CameraMount                        <-- sphere marker for camera position
│   ├── CameraRig (Node3D)                <-- reserved for future camera logic
│   ├── CollisionShape3D                   <-- box collider, size 0.4 x 0.12 x 0.4
│   └── DebugAxes (Node3D)                <-- debug_axes.gd -- RGB axis arrows
├── ChaseCamera (Camera3D)                 <-- chase_camera.gd attached
└── DebugHUD (CanvasLayer)                 <-- debug_hud.gd -- overlay text
```

**Godot concept mapping (Unity programmer reference):**

| Unity | Godot equivalent | Notes |
|---|---|---|
| GameObject | `Node3D` | Base for everything 3D |
| Transform | `Transform3D` | Position + rotation + scale; `global_transform` for world space |
| Rigidbody | `RigidBody3D` | Physics body with mass, gravity, forces |
| Collider | `CollisionShape3D` | Child node referencing a shape resource |
| MeshFilter + MeshRenderer | `MeshInstance3D` | Single node for both |
| MonoBehaviour | `Script` (`.gd`) | Godot-native GDScript, attached as a resource |
| `Update()` | `_process(delta)` | Every frame |
| `FixedUpdate()` | `_physics_process(delta)` | Physics tick (fixed timestep) |
| `Start()` | `_ready()` | Called when node enters scene tree |
| Canvas (UI) | `CanvasLayer` | Screen-space overlay |
| Coordinate system | X=right, Y=up, Z=back | Camera looks down -Z |

---

## How Scripts Work and Interact

### 1. `drone_controller.gd` — The Core

**Class:** `DroneController extends RigidBody3D`

This is the drone itself. Attached to the `Drone` node. It's both the physics body AND the controller — in Godot you don't separate these into different objects.

**Physics loop** (`_physics_process`):

```
_read_inputs()       → reads 4 stick axes from Godot's InputMap
_apply_thrust()      → pushes upward force based on throttle + hover offset
_apply_torque()      → rotates via pitch/yaw/roll torque
_apply_angular_damping() → air resistance on rotation
```

**Hover mechanics:**
- Drone mass = 2.0 kg, gravity = 9.8 m/s^2, weight = 19.6 N
- `hover_throttle` is auto-computed: `(mass * gravity) / max_thrust` → `19.6 / 50.0 ≈ 0.392`
- **At 0.392 throttle, thrust exactly cancels gravity** — the drone hovers.
- User throttle input is added on top (`clamp(hover + input * 0.6, 0, 1)`), giving ±60% extra authority.
- Thrust is `max_thrust * total_throttle` applied upward along the drone's local Y axis. Tilt the drone and the thrust vector tilts with it — that's how you get forward flight.

**Torque logic:**
- Godot uses **right-handed** coordinates: X+=right, Y+=up, Z+=back. Positive rotation = counterclockwise around that axis.
- Pitch (tilt forward/back) = torque around X axis. Stick forward → negative X torque → nose dips.
- Roll (tilt left/right) = torque around Z axis. Left stick → negated → positive Z → left roll.
- Yaw (spin) = torque around Y axis. Right stick → negated → clockwise from above.
- Torque is applied in world space via `apply_torque(global_transform.basis * torque_vec)`.

**Input handling** (`_unhandled_input`):
- `L1/R1` → toggle flight mode (stabilized ↔ acro) — emits `flight_mode_changed` signal
- `R2` → toggle FPV camera — emits `fpv_toggled` signal  
- `Triangle` (PS) → reset drone to spawn

**Currently:** Both modes are stubs — stabilized and acro both do the same direct torque mapping. Auto-leveling in stabilized mode is P1.

**Coordinate reference:** The drone model's local forward is -Z. The nose tip protrudes in -Z. Teal rotors mark forward (-Z), pink rotors mark rear (+Z). Red axis = +X (right), Green = +Y (up), Blue = +Z from the debug axes. The gizmo (top-right HUD) also shows world +X (red), +Y (green), +Z (blue).

---

### 2. `chase_camera.gd` — Camera Follow

**Class:** `ChaseCamera extends Camera3D`

Attached to the `ChaseCamera` node in `main.tscn`. The `target_path` NodePath points to `../Drone`.

**Two modes:**

1. **FPV** (default on): Camera is rigidly locked to the drone's position + basis. Offset is at the nose tip (`Vector3(0, 0.02, -0.28)`) so nothing obstructs the view. The camera basis **copies** the drone basis — no smooth interpolation, no lag. FOV = 90°.

2. **Chase / Third-person**: Camera sits behind the drone based on yaw only (ignores pitch/roll tilt). Position lerps toward target with `follow_speed = 8`. Look is at the drone center with `look_at()` — no smoothing. FOV = 70°.

**How it connects:** The camera listens to the `fpv_toggled` signal from `DroneController`. When FPV toggles, `_on_fpv_toggled(enabled)` flips `_fpv` and adjusts FOV.

---

### 3. `terrain_generator.gd` — Procedural Terrain

**Class:** `TerrainGenerator extends Node3D`

Attached to the `Terrain` node in `terrain.tscn` (which is instanced in `main.tscn`). Runs on `_ready()`.

**What it does:**
- Uses `FastNoiseLite` with Simplex noise + FBM (4 octaves) to generate height values.
- 500m × 500m grid at 250 divisions (~2m spacing per vertex).
- A **flat spawn area** (radius 10m) around origin blends smoothly into the noise hills.
- Vertex colors based on height: dark green (low) → green → brown (hills) → gray-brown → light gray (peaks).
- Collision uses `HeightMapShape3D` (efficient with Jolt Physics, avoids triangle mesh index limits).
- Both mesh and collision use the same noise function (`get_height(x, z)`) so they perfectly match.

**Heights:** `get_height(x, z)` is a public method — any other script can query terrain height at any world position (useful for future features like altitude-above-ground or spline following).

---

### 4. `drone_body_mesh.gd` — Visual Body

**Class:** `DroneBodyMesh extends MeshInstance3D`

Builds the drone's 3D model **procedurally from code** — no external 3D model file needed. Marked `@tool` so it renders in the editor viewport.

Constructs a **rhombic (diamond) prism** using `SurfaceTool` — 8 vertices, 12 triangles:
- **Body:** a kite/diamond shape from above. Sharp tip at -Z (forward), widest point pushed ~4/5 to the rear (+Z), giving a long gradual taper forward and a short blunt rear. Height is uniform.
- **Tail fin:** thin vertical box at the rear (+Z), helps read orientation from the side.

Normals are auto-generated via `generate_normals()` — no manual winding needed.

The body uses a double-sided material (`cull_mode = 2`) to avoid see-through artifacts.

---

### 5. `debug_axes.gd` — Orientation Visualizer

**Class:** `DebugAxes extends Node3D`

Child of the drone. Creates three glowing, emissive, unshaded boxes colored:
- **Red** → +X (right)
- **Green** → +Y (up)
- **Blue** → +Z (positive Z axis)

Each box is aligned so its long axis points along the correct direction, with the center offset to start at the origin and extend outward. Because they're children of the drone, they inherit its transform.

The drone's **forward direction** is -Z (indicated by the body tip and teal rotors), which is the opposite of the blue debug arrow.

---

### 6. `debug_hud.gd` — On-Screen Telemetry

**Class:** `DebugHUD extends CanvasLayer`

A `CanvasLayer` in `main.tscn` — draws two panels with green monospace text.

**Top-left panel:** dark background with drone telemetry:
- Stick inputs (4 axes), Euler angles (heading/pitch/roll), speed, altitude, throttle %, flight mode, FPV state.
- Updated every frame.
- Every 60 frames prints a compact one-line telemetry string via `print()` for MCP debug capture.

**Top-right panel:** world-axis gizmo + drone coordinates:
- A small 3-axis cross (red = +X, green = +Y, blue = +Z) showing world axes from the camera's perspective — rotates as the camera turns, like Minecraft's F3 indicator.
- Below it: the drone's world-space XYZ coordinates.

**Telemetry includes:**
- Throttle: stick + hover offset, shown as %
- Pitch/roll angles: from `basis.get_euler()`
- Heading: yaw normalized to 0-360°
- Speed: `linear_velocity.length()`
- Altitude: `global_position.y`
- Flight mode + FPV state

**UI construction:** Builds `ColorRect` (semitransparent background) and `Label` at runtime in `_build_ui()`. Tries to load a monospace font from `assets/fonts/` — silently falls back to default if none found.

---

## Input Map (project.godot)

The project uses Godot's `InputMap` — **named actions**, not raw device codes. This means rebinding and changing controller types doesn't require touching scripts.

| Action | DualSense (PS5) | Keyboard |
|---|---|---|
| `throttle_up` / `throttle_down` | Left stick Y | W / S |
| `yaw_left` / `yaw_right` | Left stick X | A / D |
| `pitch_forward` / `pitch_backward` | Right stick Y | Up / Down |
| `roll_left` / `roll_right` | Right stick X | Left / Right |
| `toggle_flight_mode` | L1 (button 9) | M |
| `toggle_fpv` | R1 (button 10) | C |
| `reset_drone` | Triangle (button 3) | R |

**Axis mapping (DualSense):**
- Axis 0 = Left stick X, Axis 1 = Left stick Y
- Axis 2 = Right stick X, Axis 3 = Right stick Y
- Axis value -1 = up/left on that axis, +1 = down/right
- Deadzone: 0.15 for all analog axes, 0.5 for buttons

**Mode 2 layout:** Left stick → throttle + yaw. Right stick → pitch + roll.

---

## How It All Connects

```
User input (gamepad/keyboard)
       ↓
  Godot InputMap  ←─── project.godot defines action→event bindings
       ↓
DroneController._read_inputs()   ←─── reads action strengths per axis
       ↓
DroneController._physics_process()
  ├── _apply_thrust()     → apply_central_force(Y_up * thrust)
  ├── _apply_torque()     → apply_torque(basis * torque_vec)
  └── _apply_angular_damping() → apply_torque(-ang_vel * damping)
       ↓
  RigidBody3D physics tick  ←─── Jolt Physics computes velocities, collisions
       ↓
ChaseCamera._physics_process()  ←─── reads drone position, updates camera
DebugHUD._process()             ←─── reads drone state, updates display
```

**Messages via signals (Godot's event system):**
- `DroneController.fpv_toggled` → `ChaseCamera._on_fpv_toggled` (switches FOV/mode)
- `DroneController.flight_mode_changed` → future subscribers (no one listens yet)

---

## File Dependency Graph

```
main.tscn
├── drone.tscn
│   ├── drone_controller.gd (DroneController)
│   ├── drone_body_mesh.gd (DroneBodyMesh)
│   └── debug_axes.gd (DebugAxes)
├── chase_camera.gd (ChaseCamera)   ← references DroneController signal
├── terrain.tscn
│   └── terrain_generator.gd (TerrainGenerator)
└── debug_hud.gd (DebugHUD)         ← references DroneController internals
```

No `.tscn` file references script internals — they just attach the `.gd` resource file. All inter-script communication happens through signals, direct node references via `@onready var` / `get_node()`, and exported `NodePath` properties set in the scene inspector.

---

## Running

Open the project in Godot 4.7 and press **F6**, or use the Godot MCP: `mcp_godot_run_project(projectPath="/Users/tim/dev/dronesim")`.
