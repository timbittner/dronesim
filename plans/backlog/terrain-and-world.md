# Terrain & World

Terrain generation is architecturally standalone (`terrain_generator.gd` is
already a pluggable backend per AGENTS.md's "Extension Points") and mostly
independent of flight-model work, so this bucket is a reasonable candidate
for a side-branch that doesn't compete with core sim work.

- **Real locations via OpenStreetMap** — swap or supplement the noise-based
  terrain generator with an OSM-based backend for real-world terrain data.
- **Buildings** — generate/import structures from OSM building footprints,
  giving crash detection and wind deflection real obstacles beyond
  procedural trees/rocks.

Open question: how far to go before this needs its own plan doc (data
fetching/caching, coordinate projection, LOD for large areas).
