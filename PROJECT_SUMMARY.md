# DroneSim — Project Summary

A 3D drone flight simulator in **Godot 4.7 / GDScript** with **Jolt Physics**.
Single drone, flyable with a PS5 DualSense controller. Real-world terrain,
chase/FPV cameras, debug HUD.

Current phase: **Per-rotor thrust vectoring complete**, plus **Phase B assisted
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
15 + 6 + 3 + 8 headless tests pass.

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
├── FlightRecorder (Node)         # JSONL telemetry per physics tick (P3)
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
MIN_ROTOR (0.02) protection, in two stages (the same approach real flight-
controller mixers use): clip the differential only if `|pitch| + |roll|`
exceeds `min(collective - MIN_ROTOR, (1.0 - MIN_ROTOR) / 2)` — the second
term is the max spread achievable by *shifting*, see next — then, if the
resulting mix's highest rotor still exceeds 1.0 (only possible at high
collective), shift **all four rotors down uniformly** by the overshoot. This
trades a little collective (climb rate) for full pitch/roll authority near
100% throttle, instead of the differential collapsing to zero the instant
any single rotor would exceed 1.0 (the original behavior — full differential
was impossible at 100% throttle because it required equal headroom to raise
*and* lower rotors around the exact commanded collective; shifting only
needs headroom to lower). Shifts only ever go down, never up, so a centered
stick still gets exactly `collective` on all four rotors — max climb rate at
full throttle is unaffected. Early-returns all zeros if collective < 0.001
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
state → CRASHED, `crash_detected` emitted, inputs zeroed, rotor visuals to idle.
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

### `scripts/drone/flight_mode_acro.gd` — Acro/Rate Mode

Stick-to-differential mapping. No auto-leveling. Collective isn't a flat
`hover + stick * range`: at and above center stick, throttle floors at
`idle_throttle` (0.08) so the self-centering stick never zeros rotor
authority on release; only an explicit throttle-down past center lets thrust
drop below idle, down to a full cutoff at -1. Pitch/roll get an expo curve
(`pitch_roll_expo = 0.3`) to soften twitchiness near center without blunting
full-deflection response.
- `idle_throttle = 0.08` — rotor floor at neutral stick and above
- `max_differential = 0.057` — rotor throttle offset per unit (expo'd) stick input
- `yaw_torque_factor = 1.5` — Nm per unit yaw input

### `scripts/drone/flight_mode_stabilized.gd` — Stabilized (120 lines)

Two sub-modes:
- **Sticks active (>0.05 deadzone):** Rate mode — stick maps to target angular
  velocity (max 1.5 rad/s pitch/roll, 1.0 rad/s yaw), PD drives toward target
  with `rate_p_gain = 4.0`. Yaw uses direct stick-to-torque (same as acro),
  no rate PD.
- **Sticks centered:** PD auto-level using world-frame cross product
  (body_up × world_up) → angle → linear P gain (no deadzone needed — it
  tapers to zero as angle approaches 0 on its own). D gain always active,
  driven off a one-pole low-pass-filtered gyro reading (`gyro_filter_alpha =
  0.35`) rather than raw angular velocity, to kill PD limit-cycle jitter.
  `stabilize_p_gain = 15.0`, `stabilize_d_gain = 4.0`. The same filtered gyro
  signal also feeds rate-mode's D-term — see AGENTS.md "Known Issues" for the
  lag/jump tradeoffs that shared filter causes.

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

### `scripts/environment/crash_effects.gd` — Crash Effects (environment-side)

`CrashEffects extends Node3D`, a node in `main.tscn` that listens to the
drone's `crash_detected` signal — the controller owns flight/crash logic only,
world reactions live here. On crash: one-shot white-sand dust burst
(`CPUParticles3D`, built in code, CPU for gl_compatibility safety) at the
impact point. Fast initial puff (~5–9 m/s against 4.5–7 damping coasts to a
~3–6m radius in ~1.5s), then the cloud hangs at 80%→60% alpha and fades out
over a ~10–13s lifetime. Emits in world space (`local_coords = false` +
`top_level`), so the cloud stays put while the wreck tumbles away. Purely
visual — no collision, no forces.

### `scripts/environment/wind_field.gd` — Terrain-Aware Wind (Phase D)

`WindField extends Node3D`, a node in `main.tscn` (same environment-side
pattern as `CrashEffects` — not an autoload), self-registered into group
`"wind_field"`. `DroneController` discovers it lazily on the first physics
tick (group lookup, not `_ready()` — Drone precedes WindField in tree order)
and samples `get_wind(global_position)` every tick; no `WindField` in a scene
(e.g. the flight-mode test scene) simply means zero wind everywhere.

`get_wind(pos) -> Vector3` pipeline: a protected calm zone around the spawn
pad (independent of terrain) zeroes wind within `calm_radius`; an
altitude-above-ground profile ramps speed from `ground_wind_fraction` of
`base_speed` at ground level up to full speed at `boundary_layer_height`
AGL; upwind terrain crests cast a shelter "shadow" (checked at several
upwind sample distances) that can cut speed to near-zero in a lee valley;
taller ground gets a ridge speed boost; and a terrain-gradient check deflects
wind horizontally around (rather than through) windward slopes — preserving
magnitude, not attenuating it — while adding a proportional updraft. Gentle
gusts and a slow direction wobble come from two low-octave `FastNoiseLite`
instances. Terrain access is duck-typed on `get_height(x, z)` with a
flat-ground (`0.0`) fallback, so `WindField` works with no terrain node at
all (used by the headless test suite's `MockHillTerrain`).

### `scripts/environment/wind_particles.gd` — Wind Streak Visualization (Phase D)

`WindParticles extends MultiMeshInstance3D`, a child of `WindField`. Custom
advected-streak system rather than `CPUParticles3D`, because each streak
needs to sample the wind at its own world position — something
`CPUParticles3D` can't do per-particle. ~300 thin box-mesh streaks roam a box
volume centered on the drone (camera fallback if not found), each carrying a
cached wind-velocity sample that's refreshed on a staggered schedule
(`resample_interval` frames, offset by index so the per-frame sample cost is
spread evenly) rather than every frame. Per streak: age → respawn (uniform in
the box, fresh sample) when expired or too far from the focus; advect by the
cached velocity; write a `MultiMesh` instance transform oriented along the
wind direction and scaled in length by speed, with alpha from speed (calm →
invisible) and a short fade-in/out. Unshaded, alpha-blended, no shadows.

### `scripts/drone/drone_controller.gd` — Wind Drag (Phase D)

Relative-airspeed drag, `F = air_drag_coefficient * (wind_velocity -
linear_velocity)`, applied as a central force **before** the `FLYING` state
gate in `_physics_process` (so it also acts while `CRASHED` — the wreck
drifts downwind, same as the old engine damping did). This replaced the old
body `linear_damp = 0.5`, which is now `0.0`; `air_drag_coefficient = 1.0`
N·s/m at `mass = 2.0` kg reproduces the old damping exactly in still air
(`wind_velocity == 0`), on top of the untouched engine default
`physics/3d/default_linear_damp = 0.1` — this is why the existing 15
flight-mode tests stay green unmodified. **Do not re-add body `linear_damp`**
to "fix" drift or damping feel — tune `air_drag_coefficient` instead, or the
parity with the old feel breaks silently.

### `scripts/ui/debug_hud.gd` — Wind Arrow (Phase D)

A small camera-relative arrow (same projection technique as the axis gizmo:
`cam_basis.inverse() * wind_velocity` → `Vector2(x, -y)`) below the gizmo
panel, showing the ambient wind sampled at the drone (`_drone.wind_velocity`,
not the drag force itself). Arrow length and alpha scale with speed; below
0.3 m/s it collapses to a dim center dot and an "WIND CALM" label, otherwise
an "WIND %.1f m/s" readout. Dims alongside the rest of the telemetry on
crash, restores on reset.

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

### `scripts/test/wind_field_test.gd` — Wind Headless Test Harness (Phase D)

6 tests against a deterministic `WindField` (`wind_direction_deg = 90`,
turbulence and direction wobble disabled) over `MockHillTerrain` (a single
12m Gaussian hill at `(60, 0)`, flat elsewhere):

| Test | Verification |
|---|---|
| Spawn zone calm | Wind ≈ 0 inside the spawn calm radius, > 1 m/s just outside |
| Wind grows with AGL | Speed increases with altitude on flat ground, → base_speed |
| Ridge windier than valley | A crest is > 2× windier than its sheltered downwind wake |
| Wind deflects around hill | Opposite-sign lateral deflection on either flank, magnitude preserved |
| Null terrain fallback | A `WindField` with no terrain reduces to `dir * base_speed`, finite |
| Hover drifts downwind | A hovering drone accumulates downwind drift under wind drag |

Run: `godot --headless --path . scenes/test/wind_test_scene.tscn`
(or `./run_tests.sh`, which runs all suites)

### `scripts/environment/flight_recorder.gd` — Telemetry Logging (P3)

Environment-side observer (same pattern as CrashEffects/WindField): streams
one JSONL line per physics tick to `user://telemetry/flight_<ts>_<n>.jsonl` —
`t`, `pos`, `quat`, `vel`, `angvel`, rotor `mix`, `sticks` (pitch, roll, yaw,
throttle), `ah`/`brake` flags, `mode`, `wind`, `crashed`. First line is a meta
header (`version`, `tick_hz`, `mass`); flushed ~1/s (live-tailable, survives a
kill); rotated to a new file on the controller's `drone_reset` signal; the
absolute path is printed at startup so headless/agent runs find it from
stdout. The controller exposes only `last_mix` for this (commanded rotor
outputs aren't observable otherwise). Greppable, e.g. `grep '"crashed":true'`.
In-sim replay/scrubbing is backlog, not built.

### `scripts/test/flight_recorder_test.gd` — Recorder Headless Test Harness (P3)

| Test | Verification |
|---|---|
| One frame per tick | ~60 log lines appended across 60 physics ticks |
| Valid JSONL + meta header | Every line parses; header meta correct; pressed throttle shows in `mix` |
| Reset rotates log file | `reset()` closes the old file and opens a fresh one |

Run: `godot --headless --path . scenes/test/flight_recorder_test_scene.tscn`

---

## Real-World Terrain (P4)

### Offline bake — `tools/bake_map.py`

One-time Python step (inputs gitignored, outputs checked in). Converts 12
LGLN **DGM1** elevation tiles (1 m grid, EPSG:25832, free direct download —
tile URLs come from the LGLN ArcGIS tile-index FeatureServer, see script
header) plus an **OSM extract** into `assets/maps/sebexen/`:

- `heightmap.bin` — float32 LE grid, 1701×1201 @ 2 m cells (3.4 × 2.4 km),
  row 0 = north; heights relative to the spawn point (pad = 0).
- `classmap.bin` — uint8 land class per cell: 0 field, 1 forest, 2 water,
  3 road (rasterized from OSM polygons/polylines with Pillow; multipolygon
  forest relations get their outer rings stitched).
- `map.json` — grid metadata, UTM anchors, 628 building footprints (local
  meters + height), and the LGLN/OSM attribution strings.

Local frame: origin = spawn (a flat field at UTM 570730 E, 5742050 N between
the village and the forest to the north), x = east, z = south. lat/lon →
UTM32 uses pyproj — an equirectangular approximation would misalign OSM
features against the DEM by ~20 m at map edges (UTM grid convergence ≈0.8°).
Also computes `albedo.png` (1 m/px ground color texture: field/forest/water/
road palette with altitude+slope field tint, Gaussian-blurred to soften hard
class edges) and bakes roadside + garden tree positions by walking OSM road
polylines and scattering points inside `landuse=residential` polygons — both
need the OSM way geometry, which only exists at bake time. See
[`docs/new-map.md`](../docs/new-map.md) for baking a different area.

### `scripts/environment/osm_terrain.gd` — Runtime (`OsmTerrain`)

Node named `Terrain` in `main.tscn` (swapped in for the procedural
`TerrainGenerator`, which remains for reference/tests). Duck-type compatible:
`get_height(x, z)` (bilinear, edge-clamped) keeps `WindField` working
unchanged. Builds on `_ready()` (~2 s, not `@tool`):

- **Terrain mesh**: one ArrayMesh at `mesh_step` (4 m default) with analytic
  normals, UV-mapped to `albedo.png` (loaded via `load()`, so it goes through
  Godot's normal texture-import pipeline, unlike the raw `.bin` grids). Water
  vertices are dropped 0.4 m for a visible channel; ground color/blur lives
  in the bake (`build_albedo`), not per-vertex at runtime.
- **Collision**: `HeightMapShape3D` fed the full-res grid directly
  (same pattern as TerrainGenerator), XZ-recentered on the map rect.
- **Spawn pad**: the grid itself is flattened radially around the origin at
  load (same smoothstep profile as TerrainGenerator), so mesh, collision and
  `get_height` agree by construction.
- **Forest**: pine trees scattered onto forest-class cells
  (`tree_density_per_km2 = 10000`, ~20 k trees) plus baked-in deciduous
  roadside/garden trees from `map.json` (`trees: [[x, z, scale], ...]`).
  Trunk + canopy per species (pine = cylinder trunk + cone canopy, deciduous
  = cylinder trunk + sphere canopy), batched into ~128 m
  (`forest_chunk_size`) chunks, each with a near-tier MultiMesh pair (full
  detail) and a far-tier single merged-cone MultiMesh, switched via
  `GeometryInstance3D.visibility_range_begin/end` (`forest_lod_near_distance
  = 300`, `forest_lod_fade_margin = 30`) — chunking exists because
  `visibility_range` is a per-node property, so LOD granularity is
  chunk-sized, not per-instance. Trunk colliders (`tree_collision = true`,
  on by default) are cylinders added directly via `PhysicsServer3D`
  (`body_add_shape`, batched 200 shapes/body — one shape per call scales
  worse than O(1) as a body's shape count grows, and one body per shape hits
  Jolt's default 10240-body cap) — no `CollisionShape3D` nodes, which would
  bloat the scene tree at this count. Canopies stay non-solid. Colliders are
  skipped in the editor (`Engine.is_editor_hint()`).
- **Buildings**: all footprints extruded into one ArrayMesh + one trimesh
  StaticBody3D, winding normalized via shoelace area so backface culling
  stays on (no `cull_mode` override). Default height 6 m (extract has no
  `building:levels`). 4-corner footprints under 250 m² get a gable roof
  (ridge along the shorter pair of edges, rise ∝ eave span, clamped
  1.5–3 m); larger/irregular footprints keep a flat roof.

`export_presets.cfg` has `include_filter="assets/maps/*"` — the baked files
are not Godot resources and would otherwise be dropped from the web export.

### `scripts/test/osm_terrain_test.gd` — Terrain Headless Test Harness (P4)

| Test | Verification |
|---|---|
| Map loads with expected dims | grid/class sizes match map.json; mesh/body/buildings nodes exist |
| Spawn pad flat at zero | \|height\| < 0.01 m inside `flat_radius` |
| get_height matches baked grid | bilinear sample equals raw file values at grid points |
| All land classes present | field/forest/water/road all seen in classmap |
| Collision matches get_height | physics raycasts hit within 0.5 m of `get_height` at 5 spots |
| Buildings built with collision | building mesh AABB/vert count sane, trimesh body exists |
| Albedo texture loads | `albedo.png` loads and its dims match the 1 m/px bake of the grid extent |
| map.json has trees | roadside/garden tree array is non-empty |

Run: `godot --headless --path . scenes/test/osm_terrain_test_scene.tscn`

---

## Project Health (P3)

- **CI** (`.github/workflows/ci.yml`): on push/PR to main, downloads Godot
  4.7-stable linux, `--import`s, runs all three headless suites. A second
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

## Tuning Parameters

| Parameter | Location | Value |
|---|---|---|
| max_thrust (per rotor) | drone_controller.gd | 17.5 N |
| hover_throttle (per rotor) | drone_controller.gd | 0.28 (auto, at 2.0 kg mass) |
| Angular damping | drone_controller.gd | (0.08, 1.0, 0.08) |
| MIN_ROTOR | drone_controller.gd | 0.02 |
| Acro idle_throttle | flight_mode_acro.gd | 0.08 |
| Acro max_differential | flight_mode_acro.gd | 0.057 |
| Acro pitch_roll_expo | flight_mode_acro.gd | 0.3 |
| Acro yaw_torque_factor | flight_mode_acro.gd | 1.5 |
| Stab P gain | flight_mode_stabilized.gd | 15.0 |
| Stab D gain | flight_mode_stabilized.gd | 4.0 |
| Stab rate_P gain | flight_mode_stabilized.gd | 4.0 |
| Stab max rates | flight_mode_stabilized.gd | 1.5 / 1.5 / 1.0 rad/s |
| Stab input deadzone | flight_mode_stabilized.gd | 0.05 |
| Stab gyro_filter_alpha | flight_mode_stabilized.gd | 0.35 |
| FPV rotation smoothing | chase_camera.gd | 0.92 |
| Chase distance / height | chase_camera.gd | 2.2 m / 0.9 m |
| Crash momentum threshold | drone_controller.gd | 8.0 kg·m/s |
| Crash max impact angle | drone_controller.gd | 60° |
| Altitude hold P gain | flight_mode_altitude_hold.gd | 0.15 |
| Altitude hold D gain | flight_mode_altitude_hold.gd | 0.3 |
| Altitude hold release blend time | flight_mode_altitude_hold.gd | 0.3 s |
| Brake P gain | brake_assist.gd | 6.0 |
| Brake D gain | brake_assist.gd | 1.5 |
| Brake max tilt | brake_assist.gd | 25° |
| Brake time constant | brake_assist.gd | 1.0 s |
| air_drag_coefficient | drone_controller.gd | 1.0 N·s/m |
| WindField wind_direction_deg | wind_field.gd | 70.0° (0° = −Z) |
| WindField base_speed | wind_field.gd | 6.0 m/s |
| WindField boundary_layer_height | wind_field.gd | 35.0 m AGL |
| WindField ground_wind_fraction | wind_field.gd | 0.35 |
| WindField shelter_strength | wind_field.gd | 0.95 |
| WindField shadow_angle_deg | wind_field.gd | 22.0° |
| WindField deflection_strength | wind_field.gd | 1.2 |
| WindField updraft_strength | wind_field.gd | 0.6 |
| WindField ridge_boost | wind_field.gd | 0.35 |
| WindField ridge_reference_height | wind_field.gd | 12.0 m |
| WindField turbulence_strength | wind_field.gd | 0.25 |
| WindField direction_wobble_deg | wind_field.gd | 12.0° |
| WindField calm_radius / calm_falloff | wind_field.gd | 18.0 m / 12.0 m |
| WindParticles streak_count | wind_particles.gd | 300 |
| WindParticles volume_extents | wind_particles.gd | (45, 25, 45) m |
| WindParticles resample_interval | wind_particles.gd | 4 frames |
