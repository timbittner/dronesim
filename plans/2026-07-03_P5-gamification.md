# P5 — Gamification I: Signal, Sight & Missions

## Progress

- **Phase 1 — PS2 3PV look: DONE** (commit `26dcf74`). Final tuning:
  color_levels 16, dither 1.0, vignette 0.8, pixel_size 2, fisheye 0.1.
  Uniforms mirrored as `@export`s on DebugHud (remote inspector can't edit
  runtime-created ShaderMaterials).
- **Phases 2 + 3 — SignalField + packet loss + FPV static: DONE**
  (built together; deviations from the plan below, all Tim-approved):
  - **One shader for both views, not two.** The planned separate
    `fpv_static.gdshader` was built, then merged into `ps2_post.gdshader`
    (`static_intensity` uniform) so 3PV also *feels* signal loss — and FPV
    now gets the full PS2 treatment too. The effect rect is always on;
    dead-feed black/frozen rects sit on their own CanvasLayer *below* it so
    full static renders over the crash freeze frame.
  - Static intensity: `(1 − quality)` both views, `+ fpv_static_baseline`
    (0.05) in FPV only, `crash_static_intensity` (0.45) while crashed in FPV
    — heavy interference but the frozen frame stays readable (1.0 buries it).
  - Shader noise lessons: wrap TIME (`mod(floor(TIME*24), 256)`) — unbounded
    TIME breaks sin-hash float precision into sliding bands; and feed time as
    a *third hash dimension* (`hash3`), never a coordinate offset, or snow
    reads as one big scrolling texture instead of TV static.
  - Belt starts 50 m *inside* the map edge (`boundary_inset`), and
    SignalField ramps the existing Environment fog density (base → 0.02) with
    the camera's signal quality — a free "fog wall" near the belt.
  - **TerrainApron** (unplanned): coarse 64 m ring in `osm_terrain.gd`
    continuing edge heights 2 km outward (edge-smeared albedo, no collision)
    to soften the map-edge silhouette cut. Still visible from altitude —
    follow-up ideas noted in `plans/backlog/terrain-and-world.md`.
- **Phase 4 — radar ceiling: DONE.** `AirspaceControl` node
  (`scripts/mission/airspace_control.gd`, group "airspace_control") with
  **100 m** AGL ceiling (upped from the planned 60 during testing) and 10 s
  countdown; expiry = single `drone.lose_signal()` call (P6 interceptor
  hook). Two-line amber banner ("RADAR SIGNATURE DETECTED / DESCEND — 7").
  HUD's "Altitude" line now shows AGL from `AirspaceControl.agl` (the exact
  radar value; wind profile is AGL-based too) — the old line duplicated
  world Y, which is already in the coord readout.
- Phases 5–7 + tests/docs: not started.

## Context

P4 (real-world Sebexen terrain) is done. Tim wants to pivot to gamification:
analog-FPV visual identity, map/altitude boundaries with consequences, a
compass, and simple mission targets. From the parked backlog
(`plans/backlog/`), jamming nodes ride along because they fall out of the
signal-degradation system nearly free; payload-drop targets and the visible
air-defense interceptor are deferred to P6 (with DPad menu, quest HUD,
battery, cheats). Scoping decisions confirmed with Tim:

- Air defense in P5 = warning + countdown + shoot-down stub only.
- 3PV gets a PS2-era look (Wings of War vibe) — **built first**.
- Jamming nodes included; jammer mesh authored in Blender via MCP.
- Signal loss degrades **controls** (packet loss) as well as visuals.
- Radar ceiling at **60 m** AGL.
- **After each phase: pause, Tim test-flies and confirms, then commit and
  move on.** No auto-advancing.

## Core architectural idea: one signal-degradation system

FPV analog static, boundary "radiation belt" snow, jamming nodes, and the
existing crash SIGNAL LOST are all *signal quality* — a scalar (0–1). Sources
degrade it; consumers are the static shader, control packet loss, and (at
sustained 0) a full signal-lost crash reusing the existing CRASHED state
(rotors cut, physics tumbles — consistent with rotor-only-forces, no magic
forces).

## Shader layering (UI must stay clean)

Post shaders (PS2 look, FPV static) live on their own `CanvasLayer` with a
layer index **below** the HUD's, added inside DebugHud. Canvas shaders with
`hint_screen_texture` capture only the 3D render + lower layers, so telemetry
panels, compass, and banners on the HUD layer above are never distorted or
posterized. (Diegetically the pilot's ground-station UI is an overlay on the
feed, not part of it.)

## Work items (in build order)

### Phase 1 — PS2-era 3PV look (`assets/shaders/ps2_post.gdshader`)

Full-screen `ColorRect` on the new low post-layer, canvas_item shader with
`hint_screen_texture`: color quantization (~5 bits/channel), ordered Bayer
dither, mild vignette. Enabled only in 3PV (toggle in DebugHud's existing
`fpv_toggled` handler). Works under gl_compatibility. Optional distance-fog
nudge in the main `Environment`, tuned by eye in-editor.

### Phase 2 — SignalField + control packet loss

`scripts/environment/signal_field.gd` — `Node3D` in `main.tscn`, group
`"signal_field"`, same environment-side pattern as `WindField` (lazy group
resolution, absent node = perfect signal). `get_quality(pos) -> float`
combines:

- **Map boundary belt:** ramps 1→0 across a margin (export, ~150 m) outside
  the baked map extent. Add `get_bounds() -> Rect2` to `OsmTerrain` (from
  `_origin_x/_origin_z` + grid dims × cell size, already in `_load_map()`);
  duck-typed like `get_height`, fallback = infinite bounds.
- **Jammers:** iterate group `"jammers"`, min quality with smooth falloff.
  *Why iteration, not Area3D spheres:* a handful of jammers means a few
  `distance_to` calls per physics tick — cheaper and simpler than broadphase
  areas plus enter/exit event bookkeeping, and it gives a continuous falloff
  instead of a binary in/out edge. Revisit only if jammer count reaches
  hundreds (spatial grid then, still no Areas).

`DroneController` polls quality in `_physics_process`:
- **Packet loss:** with probability scaling as quality drops, freeze the
  current control inputs for a short random window (~0.1–0.4 s) — held
  stale, not zeroed, like a real RC link. Visual static and control dropouts
  share the same scalar, so they're automatically in sync.
- **Sustained 0** (~1.5 s grace) → `lose_signal()`: expose the existing
  `_state = CRASHED` transition as a public method (impact-crash path minus
  the impact check).

### Phase 3 — FPV analog static (`assets/shaders/fpv_static.gdshader`)

Second `ColorRect` on the post-layer: white noise + scanlines + occasional
horizontal tear, uniform `intensity = baseline + (1 − signal_quality)`.
Small always-on baseline in FPV only (it's a radio feed); hidden in 3PV.
Existing crash freeze-frame behavior unchanged — full-intensity static
renders over it.

### Phase 4 — Radar ceiling (`scripts/mission/airspace_control.gd`)

`Node` in `main.tscn`. No raycast: AGL = `drone.global_position.y −
Terrain.get_height(x, z)` (same duck-typed contract WindField uses). AGL
above `radar_altitude` (export, **60 m**) starts a countdown (export,
~10 s); descending below cancels. HUD shows a pulsing amber "RADAR
SIGNATURE DETECTED — 7s" banner (styled like SIGNAL LOST). Expiry →
`drone.lose_signal()` ("shot down" stub). Keep expiry a single method call
so the P6 interceptor can slot in.

### Phase 5 — Compass tape (DebugHud)

New `_draw`-based `Control` in `debug_hud.gd`, top center, on the HUD layer
(never distorted) — same pattern as the gizmo/wind canvases. Heading =
camera yaw; north = −Z (map is UTM-aligned, verified in `map.json`). PUBG
style: ticks every 5°, N/NE/E… labels, degrees every 15°, fixed center
caret. Mission targets (group `"mission_targets"`) render as bearing dots,
color by type, dim when cleared. Dims on crash like the rest of the HUD.

### Phase 6 — Mission targets + tracker

`scenes/mission/mission_target.tscn` — **editor-placeable scene** (root
`Area3D` + script `scripts/mission/mission_target.gd`, `class_name
MissionTarget`, group `"mission_targets"`). Exports: `type` (OBSERVE /
CRASH — enum, so P6's DELIVER slots in), `radius`, `dwell_time`. Marker
visuals procedural in-script (observe = translucent cylinder volume, crash =
flat bullseye ring) so one scene serves both types; instances drop into any
scene and get tuned per-instance in the inspector.

- **Observe:** drone inside continuously for `dwell_time` → `cleared`
  signal, visual goes green/dim.
- **Crash:** listens to `crash_detected`; crash position within `radius` →
  cleared. Triangle reset continues the run.

`scripts/mission/mission_tracker.gd` — plain `Node` in `main.tscn`
(CrashEffects pattern): collects group at ready, counts `cleared`, emits
`mission_completed`. DebugHud shows small green "MISSION SUCCESS" bottom
center. No persistence — reset-per-run is fine for P5.

Place 2–3 target instances around the Sebexen village in `main.tscn`.

### Phase 7 — Jamming node

`scenes/mission/jamming_node.tscn` (root `Node3D` + `scripts/mission/
jamming_node.gd`, `class_name JammingNode`, group `"jammers"`, exports
`radius` + `strength`). **Mesh authored in Blender via MCP** — antenna
mast/dish in the low-poly style, exported as `assets/models/jammer.glb`
(same GLB-loading pattern as the drone parts). Place one in `main.tscn`.
This doubles as the backlog's no-fly-zone primitive.

## Tests — lean, essentials only

Suites are getting slow, so: **one** new suite
(`scripts/test/mission_test.gd` + scene), pure-logic assertions only, no
settle-time flight simulation where avoidable:

- SignalField quality math: inside map = 1, mid-belt ramp, outside = 0,
  jammer falloff (pure function calls, near-instant).
- `lose_signal()` enters CRASHED without impact (the one safety-critical
  transition).
- MissionTracker: fires `mission_completed` only when all targets cleared
  (signal wiring, mocked targets — no physics).

**Deliberately not tested** (overkill / covered by Tim's per-phase test
flights): dwell-timer edge cases, countdown cancel timing, packet-loss
statistics, all shader/HUD visuals. If a bug shows up in one of these later,
add the one test that would have caught it — not a suite up front.

Existing suites untouched. Separately worth considering (not P5): timing the
four current suites to find where the runtime actually goes.

## Files touched

- **New:** `signal_field.gd`, `airspace_control.gd`, `mission_target.gd` +
  `.tscn`, `mission_tracker.gd`, `jamming_node.gd` + `.tscn`, `jammer.glb`,
  two `.gdshader` files, `mission_test.gd` + scene.
- **Modified:** `drone_controller.gd` (quality poll, packet loss,
  `lose_signal()`), `debug_hud.gd` (post-layer + shaders, compass, radar
  banner, mission text), `osm_terrain.gd` (`get_bounds()`), `main.tscn`,
  `run_tests.sh`.
- **Docs:** AGENTS.md + PROJECT_SUMMARY.md sections; `##` doc comments on
  new public members (escape bare brackets — docs CI parses BBCode).

## Docs compaction (Tim's question)

Yes — AGENTS.md is drifting from "guide" toward "changelog". Proposal: after
P5, a separate `docs:` chore that moves P2–P4 implementation detail from
AGENTS.md into PROJECT_SUMMARY.md, leaving AGENTS.md as conventions +
architecture map + pointers. Not bundled into P5 (scope), but P5's doc
updates will be written summary-terse to avoid making it worse.

## Workflow

Feature branch. **Each phase ends with: Tim test-flies in-editor and
confirms → commit → next phase.** No pushing to main / PR without asking.

## Deferred to P6 (agreed)

Visible air-defense interceptor (first NPC aircraft), DPad menu, quest HUD,
battery model, cheats, payload-drop target type.

## Verification

- `./run_tests.sh` green (new `class_name`s need
  `godot --headless --path . --import` first).
- Per-phase flight checks: 3PV PS2 look toggles with R1; FPV baseline
  static; fly to map edge → snow + control dropouts ramp → SIGNAL LOST past
  the belt; climb >60 m AGL → countdown → shot down, descend → cancels;
  compass headings match map north; hover/crash targets clear → dots dim →
  green MISSION SUCCESS; jammer radius → snow + dropouts.
