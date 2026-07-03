# P4 Tweaks — Sebexen Map Polish

## Context

P4 base (commit c6cc0c8 + cb38db3) is done: real Sebexen terrain, roads/water/
forest classes, extruded buildings, forest MultiMesh. First proper flights
surfaced visual bugs and wishlist items (user screenshot + discussion):

1. **Building faces light-split per triangle** — root cause is the
   `cull_mode = CULL_DISABLED` band-aid from cb38db3: Godot flips normals on
   backfaces of double-sided materials, so triangles whose winding disagrees
   with the `set_normal()` value light inverted. Winding must be fixed for
   real. Possible shadow-acne contribution from default DirectionalLight
   shadow settings on a 3.4 km scene.
2. **Ground blurry, roads have sharp clips every few meters** — inherent to
   painting classes via vertex colors on a 4 m mesh; interpolation blurs,
   per-vertex class flips alias. Needs a texture, not a denser mesh.
3. **Gable roofs** wanted for typical houses (triangular prism, ridge along
   long axis); big buildings keep flat roofs for variety.
4. **Forest too sparse** — raise ~3× for a woodland feel (user picked
   ~10000/km² ≈ 20k trees; density is already an `@export` for tuning).
5. **Roadside trees** (10–30 m spacing outside the village) + sparse
   **garden trees** in residential zones.
6. **Tree trunk colliders**, on by default, `@export` toggle (user approved).

All work on branch `feat/p4-osm-terrain`; no push/PR without asking.

**Working agreement:** stop after EACH phase with a short summary in chat;
the user does a test flight before giving the go-ahead for the next phase.
No autonomous phase-to-phase continuation.

## Phase A — building winding fix + shadow pass

`scripts/environment/osm_terrain.gd::_build_buildings()`:
- Establish ONE winding convention: after the shoelace normalization, verify
  empirically (an `@tool` scene reload makes this instant) which direction
  `Geometry2D.triangulate_polygon` triangles face in the x/z→Vector2 mapping,
  and derive BOTH the wall vertex order and the roof triangle order from that
  same convention. Suspect: the shoelace sign convention vs.
  `triangulate_polygon`'s expectation disagree, which is what the old culled
  build showed as missing walls.
- Re-enable backface culling (drop `cull_mode = CULL_DISABLED`) once winding
  is provably consistent — that also fixes the flipped-normal lighting.
- Sanity check: with culling on, every footprint must render all walls —
  verify visually in editor plus the existing AABB/verts test.

`scenes/main.tscn` DirectionalLight3D (only if streaks persist after the
winding fix): set `directional_shadow_max_distance` (~300–500 m) and nudge
`shadow_bias`/`shadow_normal_bias` — defaults are tuned for room-scale, not
km-scale, scenes.

## Phase B — ground albedo texture (kills blur + road clips)

Move color synthesis from runtime vertex colors into the bake:

`tools/bake_map.py`:
- New output `assets/maps/sebexen/albedo.png`, 1 m/px (3400×2400): render the
  same palette as `osm_terrain.gd::_class_color()` — field green with
  altitude/slope tint (bake has the DEM: use an np gradient), forest, water,
  road colors — from a 1 m-resolution classmap rasterization (rasterize
  classes at 1 m for the texture; the 2 m `classmap.bin` stays as-is for
  `get_land_class`). Bilinear texture filtering smooths edges for free.
- Keep `classmap.bin`/`map.json` otherwise unchanged. Re-bake.

`scripts/environment/osm_terrain.gd`:
- `_build_terrain_mesh()`: add UVs (linear map of x/z over the map rect),
  drop per-vertex class colors (keep the water −0.4 m depression, which is
  geometry, and keep normals). Material becomes `StandardMaterial3D` with
  `albedo_texture` loaded via `Image.load_from_file(map_dir + "/albedo.png")`
  → `ImageTexture` (raw-file pattern, same as the .bin loads — no import
  dependency, `include_filter="assets/maps/*"` already ships it to web).
- `_class_color()` moves to bake-only (delete from GDScript; palette now
  lives in the bake script — leave a comment pointing there).
- Forest/building vertex-color materials unaffected.

## Phase C — gable roofs

`scripts/environment/osm_terrain.gd::_build_buildings()`:
- Footprint qualifies for a gable roof if it has exactly 4 corners (after
  closing-point strip) and area < ~250 m²; else flat roof as today.
- Gable: eave height = current `top`; ridge = midline connecting the two
  shorter edges at `top + ridge_rise` (ridge_rise ≈ 0.45 × shorter footprint
  side, clamped ~1.5–3 m). Two sloped roof quads + two gable-end triangles
  (roof color on slopes, wall color on gable ends). Normals per face, winding
  per Phase A's convention.
- Trimesh collision comes from the same mesh — no extra work.

## Phase D — forest density + trunk colliders

`scripts/environment/osm_terrain.gd`:
- `tree_density_per_km2` default 3000 → 10000 (~20k trees, ~+1M verts —
  desktop fine; Phase F adds LOD, web verified in Phase G).
- New `@export var tree_collision := true`: trunk-only colliders via
  **PhysicsServer3D directly** (one static body, `body_add_shape` with a
  cylinder shape per trunk transform) — 20k `CollisionShape3D` nodes would
  bloat the scene tree; the server API skips node overhead. Free the body on
  the `@tool` rebuild-clear / `_exit_tree`. Canopies stay non-solid (flying
  through foliage feels better than an invisible cone wall).
- Skip colliders in the editor (`Engine.is_editor_hint()`) — gameplay-only.

## Phase E — roadside + garden trees (bake-computed positions)

`tools/bake_map.py` (road polylines only exist at bake time, so positions are
computed offline and shipped):
- Roadside: walk each `highway` polyline outside residential landuse
  polygons; trees at 10–30 m jittered intervals, offset perpendicular by road
  half-width + 1.5–3 m, random side(s); reject positions whose classmap cell
  isn't `field`.
- Garden: sparse random points inside `landuse=residential` polygons
  (~1 tree / 1000–2000 m²), rejected within ~3 m of a building footprint or
  on road/water cells.
- Ship as `"trees": [[x, z, scale], ...]` in `map.json` (rounded to cm).
  Re-bake.

`scripts/environment/osm_terrain.gd::_build_forest()`:
- Append `map.json` trees as **deciduous** instances — trunk + `SphereMesh`
  canopy (two more MultiMeshes, same pattern as the pines; cones along roads
  would read as conifer plantation, spheres read as the lindens/oaks that
  actually line roads there). Trunks join the Phase D collider body.

## Phase F — forest LOD (chunked visibility ranges)

At 20k+ trees the far half of the forest is thousands of sub-pixel meshes.
MultiMesh has no per-instance LOD, so chunk it:

`scripts/environment/osm_terrain.gd::_build_forest()`:
- Partition trees into ~128 m square chunks; per chunk, one near
  MultiMeshInstance3D pair (trunk + canopy, as today) and one far MMI (single
  merged cone at canopy color — no trunk; trunks are invisible at range).
- LOD switch via `visibility_range_begin/end` on each MMI (GeometryInstance3D
  feature, works in gl_compatibility), near ends ~250–350 m with a fade
  margin, far picks up from there to the map edge. Distances as `@export`s.
- Trunk colliders (Phase D) are unaffected — physics has no LOD.
- Measure before/after with the same flight path (FPS + the build-time print);
  if the far-cone batch alone isn't a clear win, stop there rather than
  adding impostor billboards.

## Phase G — tests, docs, verify

- `scripts/test/osm_terrain_test.gd`: extend existing suite — albedo.png
  loads with expected dims; `map.json` has >0 trees; buildings test still
  green with culling re-enabled. A few asserts, no new suite.
- `plans/p4-tweaks.md`: this plan, project convention (trashed on completion).
- `AGENTS.md` + `PROJECT_SUMMARY.md`: albedo-texture pipeline, gable roofs,
  tree density/colliders, deciduous roadside trees — check `@export` defaults
  match docs (past doc-drift lesson).
- **New map developer guide** (`docs/new-map.md` or a section in
  `tools/bake_map.py`'s own header — pick whichever reads better once it's
  drafted): end-to-end steps for baking a new area — finding/downloading DGM1
  tiles for the target region (point at the `reference_lgln_dgm1_tile_index`
  approach), getting an OSM extract, setting `SPAWN_E`/`SPAWN_N` and the map
  bounding box constants, running `tools/bake_map.py`, and pointing a new
  `OsmTerrain.map_dir` at the output; note the self-check assertion (flat
  spawn area) and what to do if it fails on a hilly candidate spot.
- Verify: `./run_tests.sh` all green; `@tool` editor reload for visual check
  of winding/roofs/texture; user flies `main.tscn` (lighting, road crispness,
  woodland feel, trunk collisions); `./export_web.sh` builds and user
  smoke-tests web perf at the new density — if it chugs, drop
  `tree_density_per_km2` and/or disable `tree_collision` for web.

## Out of scope

- Road geometry (curbs/meshes), building textures, LOD/chunking.
- Seasonal/deciduous variety beyond the one sphere-canopy tree type.
- Any push or PR — ask first, per convention.
