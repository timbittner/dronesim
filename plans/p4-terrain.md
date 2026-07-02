# P4 — Real-World Terrain: Sebexen Valley from OSM + DGM1

## Context

P4 replaces the procedural noise terrain with the first real map: the user's
hometown Sebexen (Lower Saxony), from the downloaded OSM extract
`~/Downloads/sebexenosm.osm` (~3.4 × 2.4 km, bounds lat 51.8073–51.8285,
lon 10.0059–10.0558; 628 buildings, 247 road ways, waterways, landuse).

**Key scoping fact:** OSM contains no elevation. The valley shape comes from
**LGLN DGM1** — Lower Saxony's open-data 1 m elevation grid, free direct
download (no API key) as 1×1 km tiles from opengeodata.lgln.niedersachsen.de.
The area needs ~12–16 tiles (UTM32 roughly E 569–573 km, N 5740–5743 km).
License dl-de/by-2-0 → needs an attribution line (same for OSM/ODbL).

User decisions (already made):
- **All layers**: heightmap terrain + roads + buildings + water & forest.
- **Spawn**: on the fields between Sebexen and the forest to the north
  (exact point picked from the data, keep the existing flat-pad blend).
- **Pipeline**: whatever works for P4; fully-programmatic "user pinpoints a
  location" is explicitly future work, not P4.

## Architecture: offline bake → dumb runtime

A one-time Python bake script converts DEM + OSM into Godot-friendly baked
assets checked into the repo. Godot parses nothing at runtime — it loads a
float grid and a small JSON. Web export stays lean.

```
tools/bake_map.py  (Python, pyproj for WGS84→UTM32; runs once, not shipped)
  in:  DGM1 tiles (ASCII XYZ) + sebexenosm.osm
  out: assets/maps/sebexen/heightmap.bin   float32 grid (~2 m cell), little-endian
       assets/maps/sebexen/map.json        origin, cell size, dims, spawn point,
                                           roads/water/forest polylines+polygons
                                           in local meters, building footprints+heights
```

- Both data sources are plain text (XYZ = "easting northing height" lines,
  OSM = XML via `xml.etree`). Only real dep: `pyproj` for the lat/lon→UTM32
  transform — hand-rolled equirectangular would misalign roads vs. DEM by
  ~20 m at map edges (UTM convergence ≈0.8° here), so proper transform it is.
- Local coordinates: meters relative to map center, Godot convention
  (x = east, z = south i.e. −north). Heights are absolute meters; subtract
  spawn-point height so the pad sits at y=0 (drone, camera, wind all assume
  ground ≈ 0 near spawn).
- float32 `.bin` + JSON instead of PNG/EXR: `FileAccess.get_buffer()` →
  `PackedFloat32Array` → feeds `HeightMapShape3D.map_data` directly; no image
  format / bit-depth pitfalls. ~8 MB raw at 2 m cells, compresses well.

## Runtime: `OsmTerrain` node (new, parallel to TerrainGenerator)

`scripts/environment/osm_terrain.gd` + `scenes/environment/osm_terrain.tscn`;
`main.tscn`'s Terrain instance swaps to it. `TerrainGenerator` stays for
reference/tests (test scenes use `mock_hill_terrain.gd`, unaffected).

Implements the same duck-typed surface as `TerrainGenerator`
([terrain_generator.gd](scripts/environment/terrain_generator.gd)) so
`WindField` and `Scatter` work unchanged:
- `get_height(x, z)` — bilinear sample of the float grid (flat fallback
  outside bounds).
- Mesh: same `SurfaceTool` + vertex-color pattern as
  `TerrainGenerator._build_mesh()`, but sampling the grid. Mesh vertex step
  coarser than collision (~4 m mesh vs 2 m collision grid) to keep the
  gl_compatibility/web renderer happy; both tunable `@export`s.
- Collision: same `HeightMapShape3D` pattern as `_build_heightmap_shape()`,
  fed straight from the baked grid.

### Layers (phased inside P4)

**Phase A — heightmap terrain (playable milestone)**
Bake script (DEM only) + `OsmTerrain` mesh/collision/`get_height` + spawn
point + existing height/slope vertex-color aesthetic. Swap into `main.tscn`.

**Phase B — surface features via vertex color**
Roads, water, forest tint the terrain mesh's vertex colors (roads gray,
water blue + slight depression, forest darker green). No extra geometry.
Forest polygons also drive tree placement through the existing `Scatter`
system (`scripts/environment/scatter.gd`). Requires point-in-polygon /
distance-to-polyline per vertex — done in the bake script (rasterized into a
per-cell classification byte alongside the heightmap), keeping GDScript dumb.

**Phase C — buildings**
Extrude the 628 footprints into flat-roof prisms (height from
`building:levels` × 3 m, default 6 m), merged into ONE `ArrayMesh` + one
`StaticBody3D` with a `ConcavePolygonShape3D` (they're static; single draw
call). Simple gray/roof-red vertex colors.

## Files

- `tools/bake_map.py` — new bake script (+ short README note: where to
  download DGM1 tiles, how to run).
- `assets/maps/sebexen/heightmap.bin`, `map.json` — baked output, checked in.
- `scripts/environment/osm_terrain.gd`, `scenes/environment/osm_terrain.tscn` — new.
- `scenes/main.tscn` — Terrain instance → OsmTerrain.
- `scripts/test/osm_terrain_test.gd` + test scene — headless: grid loads,
  `get_height` matches known baked values, spawn area flat, in `run_tests.sh`.
- `plans/p4-terrain.md` — this plan, project convention (trashed on completion).
- `AGENTS.md` / `PROJECT_SUMMARY.md` — architecture section + LGLN/OSM
  attribution lines.

## Open item at implementation start

Exact DGM1 tile names/URLs: determined by computing the UTM32 tile indices
for the OSM bounds, then fetched via curl from the LGLN portal (or manually
in the browser if URLs aren't guessable). One-time download, no key.

## Verification

1. `./run_tests.sh` — existing suites stay green (flight/wind scenes use
   mock/no terrain), new osm_terrain suite passes.
2. Bake script self-check: asserts grid dims, spawn height ≈ local 0,
   feature counts > 0.
3. Run `main.tscn` (user flies it): valley shape recognizable, spawn pad
   flat, wind reacts to real ridges (WindField duck-typing), roads/village
   visible from altitude. Telemetry JSONL confirms sane spawn altitude.
4. `./export_web.sh` still builds; zip size delta noted (~few MB).

## Explicitly out of scope (P4)

- Any runtime OSM/DEM fetching or "pinpoint your location" flow (future).
- Textures/materials beyond vertex colors; road meshes; building detail.
- Terrain chunking/LOD — single mesh at ~4 m step is fine for 3.4 km; revisit
  if web perf says otherwise.
