# DroneSim — Project Summary

A 3D drone flight simulator in **Godot 4.7 / GDScript** with **Jolt Physics**.
Single drone, flyable with a PS5 DualSense controller. Real-world terrain,
chase/FPV cameras, debug HUD.

Current phase: **P7.1 complete** (per-phase breakdown in AGENTS.md). The stack
so far: per-rotor thrust vectoring, plus **Phase B assisted
flight modes** (altitude hold + brake), **Phase C crash / signal loss**, and
**Phase D wind system** — both acro and stabilized modes use individual rotor
forces applied at each arm position; hard impacts kill the "signal" (rotors
cut, physics tumbles the airframe, SIGNAL LOST overlay, frozen FPV feed); a
terrain-aware prevailing wind field pushes the drone via relative-airspeed
drag, visualized with advected streak particles and a HUD wind arrow. **P3
project health** adds GitHub upstream (README, MIT, CI), JSONL flight
telemetry, an itch.io web export, and a generated GitHub Pages class
reference. **P4 real-world terrain** replaces the procedural map with the
Sebexen valley (Lower Saxony), baked offline from LGLN DGM1 elevation data
and an OSM extract: heightmap terrain with a baked albedo texture,
road/water/forest surface classes, a chunked/LOD'd MultiMesh forest (pine +
roadside/garden deciduous, ~20k trees, trunk colliders), and 628 extruded
building footprints with gable or flat roofs.
**P5 gamification** layers on an analog-FPV identity and objectives: a PS2-era
post shader (posterize + dither + vignette + fisheye) that doubles as the
signal-static shader for both views, a unified `SignalField` signal-quality
scalar (map-boundary belt + jammers) that drives FPV static, control packet
loss, and sustained-zero signal loss, an `AirspaceControl` radar ceiling
(climb too high → countdown → shoot-down), a PUBG-style compass tape,
editor-placeable `MissionTarget`s (observe / crash) with a `MissionTracker`,
and a Blender-authored `JammingNode` EW truck.
**P6 swarm** adds N physics-based follower drones flying formation behind the
player: a `SwarmManager` roster + slot tables (LINE/V/RING/BOHR), one
`FollowerPilot` autopilot per follower driving a dedicated `FlightModeFormation`
from a target pose, a DPad `PadMenu` (formation cycle, auto-land/take-off, call
backup), and FPV crosshair dispatch (send the nearest follower to observe or
kamikaze a target). Followers are full drones, so jamming degrades them like the
player.
**P6.5 QoL** starts the swarm landed on the pad (one TAKE OFF launches
everyone), makes the kamikaze a powered dive, and adds a HUD dispatch marker,
an on-screen event log, and a HUD toggle submenu. **P6.6 polishing** blends
stabilized mode's rate and auto-level laws (no release-snap), gives the kamikaze
a curved glideslope run-in with a climb-to-strike gate and an AGL descent cap,
adds per-prop obstruction (a clipped prop cuts thrust so the airframe tumbles;
hard hits break a rotor for good; stranded followers self-destruct), a shared
`HUDTheme` palette, an instrument-style FPV attitude indicator, and the
per-system doc split into `docs/systems/`.
**P7.1 missions** adds a bottom-right mission-objectives HUD panel, a
polygonal `NoFlyZone` (JAMMING soft-edge signal degradation or a SHOOT_DOWN
countdown mirroring `AirspaceControl`), real payload physics on
`DroneController` (mass/CoG shift, droppable Blender-authored crate), and a
`MissionTarget.Type.DELIVER` cleared by a landed payload.
18 + 6 + 3 + 8 + 9 + 17 headless tests pass.

---

## Scene Tree

```
Main (Node3D)
├── Terrain (Node3D)               # OsmTerrain — real-world Sebexen map (P4)
│   └── [TerrainMesh, TerrainBody, per-chunk Pine/Deciduous Trunks/Canopies +
│        FarCanopies MultiMeshInstance3Ds, Buildings, BuildingsBody]
│        (built at runtime from baked assets; tree trunk colliders are
│        PhysicsServer3D bodies, not scene nodes)
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
├── CrashEffects (Node3D)
├── WindField (Node3D)
│   └── WindParticles (MultiMeshInstance3D)
├── SignalField (Node3D)             # signal-quality field: boundary belt + jammers (P5)
├── AirspaceControl (Node)           # radar ceiling / shoot-down (P5)
├── TargetObserve*/TargetCrash* (MissionTarget Node3D)  # editor-placeable objectives, incl. DELIVER type (P5/P7)
├── MissionTracker (Node)            # fires mission_completed when all cleared (P5)
├── JammingNode (Node3D)             # EW truck, group "jammers" (P5)
├── NoFlyZone (Node3D)                # polygonal JAMMING/SHOOT_DOWN zone (P7)
├── FlightRecorder (Node)         # JSONL telemetry per physics tick (P3)
├── ChaseCamera (Camera3D)
└── DebugHUD (CanvasLayer)          # HUD + PS2/static post shader on sub-layers (P5)
```

---

## Script Architecture

### Three-Layer Flight Pipeline

```
FlightMode.compute()  →  FlightControl(collective, pitch_diff, roll_diff, yaw_torque)
DroneController._mix_rotors()  →  RotorMix(fl, fr, bl, br)  ← anti-clip scaling
Physics: apply_force() at 4 rotor positions + apply_torque() for yaw
```

Detail (mixer anti-clip math, crash/signal-loss state machine, prop
obstruction): [docs/systems/flight.md](docs/systems/flight.md).

### One-line-per-script map

Full per-script deep-dives live in `docs/systems/`, split along these lines:

- **Flight** (`docs/systems/flight.md`) — `drone_controller.gd` (core mixer,
  crash detection, wind drag, prop obstruction, payload mass/CoG), `flight_mode_base.gd`,
  `flight_mode_acro.gd`, `flight_mode_stabilized.gd`,
  `flight_mode_altitude_hold.gd`, `brake_assist.gd`, and the
  `flight_mode_test.gd` harness.
- **Environment** (`docs/systems/environment.md`) — `wind_field.gd`,
  `wind_particles.gd`, `crash_effects.gd`, `chase_camera.gd`,
  `debug_hud.gd` (telemetry/wind arrow/signal-loss overlay/`hud_theme.gd`),
  `flight_recorder.gd`, and the `wind_field_test.gd` /
  `flight_recorder_test.gd` harnesses.
- **Terrain** (`docs/systems/terrain.md`) — `tools/bake_map.py`,
  `osm_terrain.gd`, `osm_terrain_test.gd`.
- **Gamification** (`docs/systems/gamification.md`) — `signal_field.gd`,
  `ps2_post.gdshader`, `airspace_control.gd`, the compass tape, mission
  targets/tracker, `jamming_node.gd`, `no_fly_zone.gd`, `payload.gd`, the
  mission-objectives HUD panel, `mission_test.gd`.
- **Swarm** (`docs/systems/swarm.md`) — `swarm_manager.gd`,
  `flight_mode_formation.gd`, `follower_pilot.gd`, `pad_menu.gd`, the
  dispatch reticle/marker, `swarm_test.gd`.
- **Tuning** (`docs/systems/tuning.md`) — the exhaustive per-parameter table.

---

## Real-World Terrain (P4)

Baked offline (`tools/bake_map.py`) from LGLN DGM1 elevation + an OSM
extract into `assets/maps/sebexen/`; loaded at runtime by `OsmTerrain`
(`scripts/environment/osm_terrain.gd`), duck-type compatible with
`get_height(x, z)`. Detail (bake pipeline, terrain mesh/collision/forest/
buildings, `osm_terrain_test.gd`): [docs/systems/terrain.md](docs/systems/terrain.md).

---

## Gamification (P5 / P7.1)

Analog-FPV identity, boundaries with consequences: one `SignalField` scalar
(map-boundary belt + jammers) feeds FPV/3PV static, control packet loss, and
`lose_signal()`; an `AirspaceControl` radar ceiling reuses the same trigger;
a PUBG-style compass tape; editor-placeable `MissionTarget`s (observe/crash/
deliver) + `MissionTracker`; a Blender-authored `JammingNode`. **P7.1** adds a
polygonal `NoFlyZone` (JAMMING soft edge or SHOOT_DOWN countdown), real
payload physics + a droppable crate, and a mission-objectives HUD panel.
Detail (signal-quality math, the PS2 post shader, mission target/tracker
mechanics, no-fly zone modes, payload landed-detection, `mission_test.gd`):
[docs/systems/gamification.md](docs/systems/gamification.md).

---

## Swarm (P6)

N physics-based follower drones flying formation behind the player:
`SwarmManager` (roster + slot tables for LINE/V/RING/BOHR + the
leader-state radio packet), a `FlightModeFormation` autopilot per follower
(`FollowerPilot` owns behavior state, kamikaze glideslope run-in, stranded
self-destruct), a DPad `PadMenu`, and FPV crosshair dispatch. Followers are
full `DroneController`s — rotor-only, jamming degrades them like the player.
Detail (slot math, autopilot cascade, dispatch/strike mechanics,
`swarm_test.gd`): [docs/systems/swarm.md](docs/systems/swarm.md).

---

## Project Health (P3)

- **CI** (`.github/workflows/ci.yml`): on push/PR to main, downloads Godot
  4.7-stable linux, `--import`s, runs all headless suites. A second
  `docs` job (push to main only) regenerates the class reference from the
  GDScript `##` doc comments (`--doctool --gdscript-docs` → `make_rst.py` →
  Sphinx/furo) and deploys it to GitHub Pages. Doc-comment syntax errors
  (e.g. bare `[...]` brackets, parsed as BBCode) fail the job — intentional.
- **Web export** (`export_web.sh`): headless release export into a clean
  `build/web/` and zips it to `build/dronesim-web.zip` with `index.html` at
  the zip root for itch.io. Upload flow (draft visibility, viewport, browser
  gamepad caveat) documented in `docs/publishing.md`.
- **Docs site source** lives in `docs/` (`conf.py` + `index.rst` only);
  `docs/classes/` and `docs/_build/` are generated and gitignored.
- One-time manual steps (see `docs/publishing.md`): create the GitHub repo +
  add the SSH remote, enable Pages (Source: GitHub Actions), first itch.io
  draft upload.

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
- Near 100% throttle, a uniform downward shift of all four rotors (never up)
  trades a little collective for full pitch/roll authority, rather than
  clipping differential to zero — see `_mix_rotors` above
- Minimum rotor throttle (2%) prevents full cut-out during aggressive maneuvers
- Throttle cut (collective < 0.001) kills all rotors

---

## Flight Modes

| Mode | Stick input mapping | When centered |
|---|---|---|
| **Acro** | Direct differential mapping | Nothing — stays in current orientation |
| **Stabilized** | Rate mode (target angular velocity, P=4.0) | PD auto-level toward upright |

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

## Tuning Knobs

The exhaustive internal parameter table (every tuning constant across every
script) lives in [docs/systems/tuning.md](docs/systems/tuning.md). The two
groups below are the **live-tunable `@export` groups** — edit them in the
running editor via the remote inspector and feel the change immediately;
everything else needs a code edit + reload.

**`DroneController` → "Stabilized Gains"** (`flight_mode_stabilized.gd`'s
compute-both-and-blend law): `stabilized_blend_band` (0.2), rate/auto-level P
& D gains, the two separate gyro low-pass alphas
(`stabilized_rate_gyro_filter_alpha` 0.5, `stabilized_gyro_filter_alpha`
0.35), and the max commanded pitch/roll/yaw rates.

**`SwarmManager` → "Formation Gains"** (pushed into every `FollowerPilot` each
tick): position/velocity P gains + integral trim, `max_speed`, `max_tilt`
(sets terminal approach speed), and the AGL sink-rate cap knobs
(`min_sink_rate`, `agl_sink_gain`, `sink_arrest_gain`).
