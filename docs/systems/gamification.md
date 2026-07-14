# Gamification (P5 / P7.1)

Part of the DroneSim reference; see [PROJECT_SUMMARY.md](../../PROJECT_SUMMARY.md) for the index.

Analog-FPV identity, boundaries with consequences, a compass, and simple
objectives — extended in P7.1 with hostile no-fly airspace and cargo
delivery. All environment-side nodes follow the WindField pattern (self-
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
  bookkeeping for a handful of jammers. A jammer may instead expose
  `signal_quality_at(pos) -> float` for a non-circular shape (P7.1's
  `NoFlyZone`, below) — `get_quality` tries that duck-type hook first and
  falls back to the radius/strength math otherwise; `signal_field.gd` itself
  needed no shape changes.

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
capture volume is ground-anchored). One scene, `type` = OBSERVE / CRASH / DELIVER
(`_build_marker` is a `match` over the enum since P7.1 — OBSERVE/CRASH stayed
byte-identical, DELIVER just adds a case):
- **OBSERVE** — a cyan cylinder (`radius` × `height`); the drone inside
  continuously for `dwell_time` clears it (pulses white while dwelling).
- **CRASH** — a low red drum (stands off sloped terrain); a crash within
  `radius` clears it (listens to `crash_detected`; Triangle reset continues).
- **DELIVER** (P7.1) — an amber drum, same low-profile shape as CRASH; each
  tick scans group `"payloads"` for a `Payload` with `landed == true` within
  horizontal `radius` (same idiom as OBSERVE/CRASH — no signal wiring, just a
  group scan). Clears on the first landed crate inside; a crate landing
  outside, or an unlanded one inside, doesn't count.

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

### No-fly zone — `scripts/mission/no_fly_zone.gd` (P7.1)

`NoFlyZone` (group `"no_fly_zones"`, `@tool`, editor-placeable
`no_fly_zone.tscn`). Footprint is a child `Path3D` named "Footprint" — its
curve point positions, flattened to local X/Z in authoring order, are the
polygon corners (implicitly closed last→first, straight edges only, bezier
handles ignored). `contains_2d(world_pos)` is a pure X/Z
`Geometry2D.is_point_in_polygon` test — **infinite height**, no top/bottom
containment — and is the one shape predicate both modes and the marker mesh
build off. Dragging a Footprint point handle in the editor reconnects to
`curve.changed` and rebuilds live. `enum Mode { JAMMING, SHOOT_DOWN }`:

- **JAMMING** — also joins group `"jammers"`. Exposes `signal_quality_at(pos)`
  (the `SignalField` duck-type hook above): outside the polygon returns 1.0
  (clean); inside, eases from clean at the boundary to a full `strength`
  reduction over `edge_falloff` meters inward (`smoothstep` on distance-to-
  nearest-edge) — a soft edge instead of a hard wall.
- **SHOOT_DOWN** — near-verbatim copy of `AirspaceControl`'s per-drone
  countdown dict (`_tracks`), with `contains_2d` standing in for the altitude
  test: a tracked drone gets `countdown_time` seconds inside before
  `drone.lose_signal()` fires (the same slot-in point P7.2's SAM launch will
  replace). `tracking`/`seconds_left` mirror `AirspaceControl`'s HUD contract
  for the player drone specifically. The HUD (below) shows a pulsing red
  NO-FLY ZONE banner below the radar banner off the same two fields — both
  banners can be live at once (e.g. climbing inside a zone).

Marker is an open column of side walls only (no caps) from `-COLUMN_BURY`
(60 m) to `+COLUMN_TOP` (240 m, above the radar ceiling) — reads as
"infinite height" visually, matching `contains_2d`'s 2D-only test, and
sidesteps the old fixed-height box's slope-clipping. `@tool` so it renders and
ground-snaps in the editor and rebuilds live on a footprint edit; authored Y
is otherwise irrelevant. An empty/missing Footprint (< 3 points) is a neutral
zone — no marker, `contains_2d` always false.

### Payload — `scripts/mission/payload.gd` (P7.1)

`Payload extends RigidBody3D` (group `"payloads"`), spawned by
`DroneController.drop_payload()` — see `docs/systems/flight.md` for the
attach/detach mechanics on the drone side. Preloads `payload.glb` (Blender-
authored, ~0.24 × 0.15 × 0.23 m) as its mesh and builds a matching
`BoxShape3D` in code, same idiom as the drone's code-built prop-debug meshes
— keeps `payload.tscn` itself minimal.

`landed: bool` goes true once the crate has sustained contact
(`get_contact_count() > 0`) and near-zero speed (`linear_velocity.length() <
0.5`) for `_LAND_SETTLE_TIME` (0.3 s) — no signal, `MissionTarget.DELIVER`
polls the group directly per tick. On spawn, `drop_payload()` adds a
collision exception against the dropping drone that this script clears after
`_EXCEPTION_CLEAR_TIME` (0.5 s), long enough to clear the spawn-point overlap
without a physics pop on release.

### Mission-objectives HUD panel — `debug_hud.gd` (P7.1)

`_update_mission_objectives()`: a `ColorRect` + `Label` panel, bottom-right,
stacked above the on-screen event log and growing upward to fit its row
count. One row per member of group `"mission_targets"` — iterated directly,
**no `MissionTracker` involvement** — reading `CLEARED` / OBSERVE dwell
progress (`2.1/3.0s`) / horizontal distance (`▸ 240m`) off each target's own
state. No targets in the scene = no panel. Gated by `show_missions` (default
on), toggled from the pad menu's HUD submenu (`MISSIONS` entry, alongside
LOG/TELEMETRY/WIND/AXES/GIZMO/ATTITUDE/PROP DBG). Header style
(`=== OBJECTIVES ===`) matches the swarm command panel's `=== SWARM
COMMAND ===` and the telemetry box — P7.1 unified all three onto one
bracketed-green title convention.

### `scripts/test/mission_test.gd` — Mission/Signal Headless Test Harness (P5 / P7.1)

| Test | Verification |
|---|---|
| Boundary belt ramp | `_boundary_quality` is 1 inside, ~0.5 mid-belt, 0 outside (pure math) |
| Jammer falloff | `_jammer_quality` is `1−strength` at core, 1.0 at/beyond rim, monotonic |
| No-fly zone jamming degrades signal | `SignalField.get_quality` ≈0 at a JAMMING zone's center, ≈1 beyond the rim (polygon, soft edge) |
| No-fly zone shoot-down countdown | SHOOT_DOWN zone with a short `countdown_time`: drone inside crashes; outside stays untouched, no phantom retrack |
| lose_signal enters CRASHED | `lose_signal()` reaches CRASHED with no impact; idempotent; `reset()` recovers |
| Tracker completes when all cleared | `mission_completed` fires exactly once, only after every target cleared |
| Payload load updates mass and hover | `load_payload()` adds `payload_mass`, pushes recomputed `hover_throttle` into `_stabilized`/`_altitude_hold`/installed modes; drop restores; mid-air load refused |
| Payload drop falls and lands | Dropped `Payload` inherits the drone's velocity, free-falls, and `landed` goes true after settling on the ground |
| Deliver target clears on landed payload | Outside-landed and inside-unlanded don't clear; inside-landed does (ordering pins only the last case clears) |

Run: `godot --headless --path . scenes/test/mission_test_scene.tscn`
