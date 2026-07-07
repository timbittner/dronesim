# Environment Systems

Part of the DroneSim reference; see [PROJECT_SUMMARY.md](../../PROJECT_SUMMARY.md) for the index.

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

**`scripts/ui/hud_theme.gd` (P6.6):** `class_name HUDTheme` — the shared color
palette (panel bg, HUD green text, amber accent, alert red, success green,
marker cyan, wind blue, gizmo axis colors) that `debug_hud.gd` and
`pad_menu.gd` both reference instead of duplicating `Color(...)` literals.
Alpha-variant / faded uses (e.g. compass tick fade, wind-speed alpha) still
build a `Color` at the call site from the constant's RGB — only the palette
values are centralized, not every literal.

**Signal-loss overlay (Phase C):** on `crash_detected`, a pulsing red
"⚠ SIGNAL LOST" banner appears and telemetry dims. The FPV *feed* dies at the
crash instant: if the crash happened in FPV, the last rendered frame is captured
(`get_viewport().get_texture().get_image()`) and frozen fullscreen; if it
happened in chase cam, no frame was ever captured, so entering FPV afterwards
shows a plain black "no signal" screen. Chase cam always renders live — R1
during a crash bails from the dead feed to watch the wreck. Reset (polled via
`is_crashed()`) clears everything.

### `scripts/ui/debug_hud.gd` — Wind Arrow (Phase D)

A small camera-relative arrow (same projection technique as the axis gizmo:
`cam_basis.inverse() * wind_velocity` → `Vector2(x, -y)`) below the gizmo
panel, showing the ambient wind sampled at the drone (`_drone.wind_velocity`,
not the drag force itself). Arrow length and alpha scale with speed; below
0.3 m/s it collapses to a dim center dot and an "WIND CALM" label, otherwise
an "WIND %.1f m/s" readout. Dims alongside the rest of the telemetry on
crash, restores on reset.

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
