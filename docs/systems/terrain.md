# Real-World Terrain (P4)

Part of the DroneSim reference; see [PROJECT_SUMMARY.md](../../PROJECT_SUMMARY.md) for the index.

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
[`docs/new-map.md`](../new-map.md) for baking a different area.

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
