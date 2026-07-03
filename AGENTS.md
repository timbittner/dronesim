# DroneSim — Project Guide

## What This Is

A 3D drone flight simulator built in Godot 4.7 / GDScript, iterating toward a
drone swarm simulator with realistic flight physics, autonomous routing,
weather, and threat simulation.

**Current phase:** P5 complete. Shipped so far:
- **P2** — per-rotor thrust vectoring, assisted flight modes (altitude
  hold + brake), crash / signal loss, terrain-aware wind.
- **P3** — project health: GitHub upstream + CI
  (`.github/workflows/ci.yml`), JSONL telemetry (`FlightRecorder`), itch.io
  web export (`export_web.sh`, `docs/publishing.md`), and a GitHub Pages class
  reference generated from GDScript `##` doc comments.
- **P4** — real-world terrain: the Sebexen valley (Lower Saxony), baked
  offline from LGLN DGM1 + OSM by `tools/bake_map.py`, loaded by `OsmTerrain`.
- **P5** — gamification: analog-FPV PS2 post/static shader, a unified
  `SignalField` scalar (boundary belt + jammers), `AirspaceControl` radar
  ceiling, compass tape, `MissionTarget`s + `MissionTracker`, `JammingNode`.

**`PROJECT_SUMMARY.md` is the deep-dive reference** — architecture, per-system
internals, and all tuning parameters live there. This file stays a lean guide:
conventions, file-map, canonical coordinate system, controller layout, and
known issues, with pointers into the summary for detail. **Doc-comment
gotcha:** the docs CI job fails on a bare `[...]` in a GDScript `##` comment
(parses as BBCode) — keep public members documented and escape brackets.

## Tech Stack

- **Engine:** Godot 4.7
- **Language:** GDScript
- **Physics:** Jolt Physics (3D)
- **Renderer:** gl_compatibility (low-poly aesthetic, lightweight, VR-friendly later)
- **Controller:** DualSense (PS5) via Godot input system
- **Godot MCP:** `@coding-solo/godot-mcp` — run/stop scenes, read debug output,
  syntax-check GDScript
- **Blender MCP:** drives Blender directly (inspect/edit `drone_parts.blend` /
  `jammer.blend`, re-export GLBs) when connected

## Architecture

```
scenes/
  main.tscn              Root scene
  drone/drone.tscn        Drone instance
  environment/terrain.tscn      Procedural terrain (retired from main, P4)
  environment/osm_terrain.tscn  Real-world Sebexen map (in main since P4)
  mission/                Editor-placeable objectives / props (P5)
    mission_target.tscn
    jamming_node.tscn
  test/                   Headless test scenes
    flight_mode_test_scene.tscn
    wind_test_scene.tscn
    flight_recorder_test_scene.tscn
    osm_terrain_test_scene.tscn
    mission_test_scene.tscn
scripts/
  drone/
    drone_controller.gd          Core — input, mixer, damping, FLYING/CRASHED, wind drag
    flight_mode_base.gd          Abstract base — FlightControl, RotorMix
    flight_mode_acro.gd          Idle-floor throttle + expo differential, no auto-level
    flight_mode_stabilized.gd    PD auto-level + rate mode
    flight_mode_altitude_hold.gd Post-compute collective filter (assist, not a mode)
    brake_assist.gd              Rotor-thrust tilt brake (assist, not a mode)
    drone_body_mesh.gd           Procedural body (RETIRED — kept for reference)
    debug_axes.gd                RGB orientation arrows
  camera/
    chase_camera.gd              FPV + chase camera (FPV rotation smoothed)
  environment/
    terrain_generator.gd         Procedural noise terrain (retired from main)
    osm_terrain.gd               Real-world terrain from baked map assets (P4)
    crash_effects.gd             Dust burst on crash (listens to crash_detected)
    wind_field.gd                Terrain-aware wind (group "wind_field")
    wind_particles.gd            Advected wind-streak MultiMesh (child of WindField)
    flight_recorder.gd           JSONL telemetry per tick → user://telemetry/ (P3)
    signal_field.gd              Signal quality: boundary belt + jammers + fog wall (P5)
  mission/
    airspace_control.gd          Radar ceiling / shoot-down stub (P5)
    mission_target.gd            MissionTarget observe/crash, @tool (P5)
    mission_tracker.gd           Fires mission_completed when all cleared (P5)
    jamming_node.gd              JammingNode EW truck, group "jammers" (P5)
  ui/
    debug_hud.gd                 Telemetry + wind arrow + compass + banners + post shader
  test/
    flight_mode_test.gd          15 headless tests
    wind_field_test.gd           6 headless wind-field tests
    flight_recorder_test.gd      3 headless telemetry tests
    osm_terrain_test.gd          8 headless map/terrain tests (P4)
    mission_test.gd              4 headless mission/signal tests (P5)
    mock_hill_terrain.gd         Deterministic terrain stand-in for wind tests
assets/
  shaders/ps2_post.gdshader      PS2 look + analog signal static, both views (P5)
  maps/sebexen/                  Baked map (heightmap/classmap/map.json/albedo, checked in)
  models/                        drone_parts.blend + GLBs; jammer.blend + jammer.glb (P5)
tools/
  bake_map.py                    Offline DGM1+OSM → baked map assets (P4)
```

### Drone geometry

Body / arms / props authored in Blender (`drone_parts.blend`), exported as
GLB. `drone.tscn` holds bare `Node3D` markers at the correct transforms (no
"missing mesh" editor warnings); `DroneController._setup_visuals()` attaches
the GLB meshes at runtime, tints props (front cyan / back pink), and swaps in
code-built blur discs when armed. Nose faces −Z. Full detail:
`PROJECT_SUMMARY.md → Drone Geometry`.

### Flight Pipeline

Three layers: `Mode.compute()` → `FlightControl` → `_mix_rotors()` (anti-clip
scaling + MIN_ROTOR) → `RotorMix` → `apply_force()` at 4 rotor positions +
`apply_torque()` for yaw → `_apply_angular_damping()`. Full breakdown:
`PROJECT_SUMMARY.md → Three-Layer Flight Pipeline`.

### Per-system detail — see PROJECT_SUMMARY.md

The deep-dive lives in `PROJECT_SUMMARY.md`. Load-bearing invariants that are
easy to break, kept here as terse warnings:

- **Crash / signal loss (P2):** two states `FLYING` / `CRASHED`, detected in
  `_integrate_forces` (needs `contact_monitor` + `continuous_cd` in
  `drone.tscn` — without CCD the thin body tunnels above ~10 m/s). On crash,
  rotor forces stop and physics tumbles the airframe — **no magic forces**.
  Environment-side reactions (dust burst) live in `crash_effects.gd`, not the
  controller. Detail: `PROJECT_SUMMARY.md → drone_controller.gd`,
  `crash_effects.gd`.
- **Wind (P2):** relative-airspeed drag, not a magic push. **Do not re-add
  body `linear_damp`** to tune drift/damping — `air_drag_coefficient = 1.0`
  at `mass = 2.0` reproduces the old `linear_damp = 0.5` exactly in still air;
  re-adding it double-damps and silently breaks that parity. Tune
  `air_drag_coefficient` instead. `WindField` is an environment-side node
  (group `"wind_field"`, lazily resolved); **no `WindField` in a scene = zero
  wind everywhere**. Detail: `PROJECT_SUMMARY.md → wind_field.gd`,
  `wind_particles.gd`, and the Wind Drag note.
- **Real-world terrain (P4):** `OsmTerrain` loads baked assets from
  `assets/maps/sebexen/`; `get_height(x, z)` keeps the same duck-typed
  contract as `TerrainGenerator` so `WindField` needs no changes.
  `export_presets.cfg` needs `include_filter="assets/maps/*"` — the baked
  `.bin`/`.json`/`.png` are not Godot resources and would otherwise be
  dropped from the web export. The procedural `TerrainGenerator` is retired
  from `main.tscn` but kept for reference/wind tests. Detail:
  `PROJECT_SUMMARY.md → Real-World Terrain (P4)`.
- **Gamification (P5):** one `SignalField` scalar (0..1) feeds the static
  shader, control packet loss, and (sustained-zero) `lose_signal()` — the
  crash transition minus the impact check, still **rotor-only, no magic
  force**. `AirspaceControl` radar ceiling reuses the same `lose_signal()`.
  All P5 nodes follow the WindField pattern (group-registered, lazily
  resolved, absent node = neutral). Detail: `PROJECT_SUMMARY.md →
  Gamification (P5)`.

### Extension Points

- **Flight modes:** New modes implement `FlightModeBase.compute()` interface
- **Terrain:** any node named `Terrain` exposing `get_height(x, z)` works;
  new real-world areas = new baked map dir + `map_dir` export
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
- **Git workflow:** work on a feature branch, not directly on `main` — every
  push to `main` triggers CI + the Pages docs deploy (`.github/workflows/ci.yml`),
  so pushes there should be deliberate, not incidental to normal iteration.
  **Always ask before pushing to `main` or opening a PR into it** — this is
  the last step of a task, never a background/automatic one, regardless of
  how many local commits were made getting there.

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
- **Run tests:** `./run_tests.sh` (all five headless suites; new
  `class_name`s need a `godot --headless --path . --import` first if the
  editor isn't open to refresh the global class cache)
- **Re-bake the map** (only when map data/extent/spawn changes):
  `.venv/bin/python tools/bake_map.py` — see the script header for venv
  setup and DGM1 tile downloads
- **Re-export a Blender mesh** (`jammer.blend`, `drone_parts.blend`): export the
  GLB via the Blender MCP; Godot reimports a changed `.glb` on editor focus or
  `--import`
- **Run game:** F6 in editor or `godot --path .`
- **Web export:** `./export_web.sh` → `build/dronesim-web.zip` (itch.io flow
  in `docs/publishing.md`)
- **Telemetry:** every run of `main.tscn` logs JSONL to `user://telemetry/`
  (absolute path printed at startup) — grep it instead of watching a live run

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
  (`flight_mode_stabilized.gd`): rate-mode and auto-level are two different
  control laws, hard-switched at `input_deadzone` with no blending — releasing
  the stick while still tilted can snap into level. Likely fix: blend the two
  laws across the deadzone. Full rationale:
  `PROJECT_SUMMARY.md → flight_mode_stabilized.gd`.
- **Stabilized mode feels "sticky" near level under active stick input**
  (`flight_mode_stabilized.gd`): the auto-level gyro low-pass filter is reused
  for rate-mode's feedback, adding lag that's proportionally worse for the
  small commanded rates near level. Likely fix: separate filtered signals for
  the two paths. Full rationale:
  `PROJECT_SUMMARY.md → flight_mode_stabilized.gd`.

## License

MIT (see `LICENSE`, added in P3).

Map data attribution (also embedded in `assets/maps/sebexen/map.json`):
elevation © LGLN Niedersachsen (DGM1, dl-de/by-2-0); map features
© OpenStreetMap contributors (ODbL). Keep these credits with any published
build that ships the Sebexen map.
