# Gamification (P5)

Part of the DroneSim reference; see [PROJECT_SUMMARY.md](../../PROJECT_SUMMARY.md) for the index.

Analog-FPV identity, boundaries with consequences, a compass, and simple
objectives. All environment-side nodes follow the WindField pattern (self-
register into a group, lazily resolved, absent node = neutral behavior).

### Signal quality — one scalar, many consumers

`scripts/environment/signal_field.gd` (`SignalField`, group `"signal_field"`)
computes `get_quality(pos) -> float` in 0..1, the **minimum** of two sources:

- **Map-boundary belt:** ramps 1→0 across `boundary_margin` (150 m) starting
  `boundary_inset` (50 m) *inside* the terrain's `get_bounds()` rect — so the
  degradation and its fog wall kick in before the player can see the map's
  clean edge. `OsmTerrain.get_bounds()` is duck-typed like `get_height`; no
  bounds = no belt.
- **Jammers:** iterates group `"jammers"`, each exposing `strength` + `radius`,
  with a smooth `smoothstep` falloff (full `strength` reduction at the core).
  Linear scan, not Area3D — a few `distance_to` calls per tick beat broadphase
  bookkeeping for a handful of jammers.

`SignalField._process` also ramps the existing `WorldEnvironment` fog density
(base → `edge_fog_max_density` 0.02) by the camera's quality — a free fog wall.

Consumers poll the same scalar, so visuals and controls stay in sync:
- **`DroneController.signal_quality`** (sampled each `_physics_process` via lazy
  group lookup). Drives **control packet loss**: with probability scaling as
  quality drops, the current inputs freeze (held stale, not zeroed) for a short
  random window (`packet_loss_rate`, ~0.1–0.4 s) — like a real RC link.
  Sustained-zero for `signal_loss_grace` (1.5 s) calls **`lose_signal()`**.
- **`DroneController.lose_signal()`** — public entry to the existing CRASHED
  transition (`_enter_crashed()`) minus the impact check: rotors cut, physics
  tumbles the airframe (rotor-only-forces, no magic force), SIGNAL LOST. Shared
  by the sustained-zero path and the radar shoot-down. `reset()` recovers.
- **The post shader** (below) reads a `static_intensity` = `(1 − quality)`,
  plus an FPV-only baseline, for both views.

### PS2 / analog-static post shader — `assets/shaders/ps2_post.gdshader`

One canvas_item shader for **both** camera views (the FPV-only static shader was
merged in so 3PV also *feels* signal loss): color posterize (`color_levels`),
ordered Bayer dither, vignette, pixelate, mild fisheye, plus analog static
(white-noise snow, scanlines, row tearing) scaled by `static_intensity`. Two
shader-noise lessons baked into comments: wrap `TIME` (`mod(floor(TIME*24),
256)`) or the sin-hash loses float precision into sliding bands; feed time as a
*third hash dimension* (`hash3`), never a coordinate offset, or the snow reads
as one scrolling texture. Lives on a `CanvasLayer` **below** the HUD layer (its
`hint_screen_texture` captures only the 3D render + the dead-feed layer, so HUD
telemetry/compass/banners stay crisp; full static renders over the crash
freeze-frame). Uniforms are mirrored as `@export`s on `DebugHUD` and pushed
each frame — the remote inspector can't edit runtime-created ShaderMaterials.

### Radar ceiling — `scripts/mission/airspace_control.gd`

`AirspaceControl` (group `"airspace_control"`). AGL without a raycast:
`drone.y − Terrain.get_height(x, z)` (the value the HUD's "Altitude" line
shows — world Y is height above the spawn pad, which diverges over the valley).
Above `radar_altitude` (100 m) a `countdown_time` (10 s) starts; descending
cancels; expiry calls `drone.lose_signal()` — kept a single call so the P6
interceptor can slot behind the same trigger. DebugHUD shows a pulsing amber
two-line banner.

### Compass tape — `DebugHUD._on_compass_draw`

`_draw`-based Control, bottom center, on the HUD layer (never distorted).
Heading = the camera's forward bearing on the ground plane (0° = north = −Z,
the map's UTM north). Cylinder projection (`x ∝ sin(angle-from-center)`) so it
reads like a rotating ring, marks fading toward the edges; 5° ticks, degree
numbers every 15°, cardinals every 45°. Mission targets render as bearing dots
(amber → green once cleared), clamped to the tape edge when off-bearing. Dims
with the HUD on crash. (Drone spawn now faces south, toward the objectives.)

### Mission targets + tracker — `scripts/mission/`

`mission_target.gd` (`MissionTarget`, group `"mission_targets"`, editor-
placeable `mission_target.tscn`). `@tool`: renders its marker and ground-snaps
as you drag it in the viewport, so placement is X/Z only (Y is discarded — the
capture volume is ground-anchored). One scene, `type` = OBSERVE / CRASH:
- **OBSERVE** — a cyan cylinder (`radius` × `height`); the drone inside
  continuously for `dwell_time` clears it (pulses white while dwelling).
- **CRASH** — a low red drum (stands off sloped terrain); a crash within
  `radius` clears it (listens to `crash_detected`; Triangle reset continues).

Clearing turns the marker green and emits `target_cleared`. `mission_tracker.gd`
(`MissionTracker`, group `"mission_tracker"`, plain Node) collects the group
(deferred so all targets have registered), counts clears, and emits
`mission_completed` once all are cleared → green MISSION SUCCESS banner above
the compass. The drone self-registers into group `"drone"` for path-free
resolution by targets and the tracker.

### Jamming node — `scripts/mission/jamming_node.gd`

`JammingNode` (group `"jammers"`, exports `strength` + `radius` — exactly what
`SignalField` reads, no field change needed). `@tool`, same GLB-preload and
editor ground-snap pattern. Mesh authored in Blender (`assets/models/
jammer.blend`, standalone source) and exported to `jammer.glb` — a low-poly
olive EW/utility truck (sloped-windshield cab, equipment bed, radar dish, whip
antenna), deliberately low-key. Doubles as the backlog's no-fly-zone primitive.

### `scripts/test/mission_test.gd` — Mission/Signal Headless Test Harness (P5)

| Test | Verification |
|---|---|
| Boundary belt ramp | `_boundary_quality` is 1 inside, ~0.5 mid-belt, 0 outside (pure math) |
| Jammer falloff | `_jammer_quality` is `1−strength` at core, 1.0 at/beyond rim, monotonic |
| lose_signal enters CRASHED | `lose_signal()` reaches CRASHED with no impact; idempotent; `reset()` recovers |
| Tracker completes when all cleared | `mission_completed` fires exactly once, only after every target cleared |

Run: `godot --headless --path . scenes/test/mission_test_scene.tscn`
