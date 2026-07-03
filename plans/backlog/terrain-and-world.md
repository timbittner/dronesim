# Terrain & World

Terrain generation is architecturally standalone (`terrain_generator.gd` is
already a pluggable backend per AGENTS.md's "Extension Points") and mostly
independent of flight-model work, so this bucket is a reasonable candidate
for a side-branch that doesn't compete with core sim work.

- **Real locations via OpenStreetMap** — swap or supplement the noise-based
  terrain generator with an OSM-based backend for real-world terrain data.

- **Better map-edge horizon** (noted during P5) — the `TerrainApron` ring in
  `osm_terrain.gd` (edge heights continued outward 2 km, edge-smeared albedo,
  fades into fog) beats the old razor cut against the skybox, but the
  transition is still visible from altitude. Ideas: bake a wider low-res
  DGM25/DGM50 "context" heightmap ring around the playable DGM1 area
  (LGLN has coarser products, same no-key download), or a horizon gradient /
  matched skybox instead of flat continuation. Reducing render distance is
  off the table — looking down the whole valley is the point of the map.
