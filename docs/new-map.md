# Baking a new map area

`tools/bake_map.py` currently bakes exactly one area (Sebexen) with its
constants hardcoded at the top of the file — there's no `--area` flag or
config system (one map exists; build that when a second one does). To bake a
different area, edit those constants, re-run the script, and point a new
`OsmTerrain.map_dir` at the output. See the script's own module docstring for
the full input/output contract; this doc is the workflow around it.

## 1. Pick the area and get elevation tiles (DGM1)

Requires Lower Saxony (Niedersachsen), since DGM1 is that state's open-data
lidar product. For other German states, find the equivalent portal — same
idea, different endpoint.

Query the tile index for tile URLs covering your bounding box (WGS84
envelope in, tile URLs out):

```
https://services-eu1.arcgis.com/4v3xxN52w88W065F/arcgis/rest/services/lgln_opengeodata_dgm1/FeatureServer/0/query
```

Pass a WGS84 envelope geometry and `outFields=dgm1,tile_id`. Each result
gives a plain S3 GeoTIFF URL (1000×1000 float32, LZW-compressed — Pillow
reads it directly, no GDAL needed), e.g.
`https://dgm1.s3.eu-de.cloud-object-storage.appdomain.cloud/L1606/Vollkacheln/dgm1_32_569_5740_1_ni_2016.tif`.
The filename encodes the tile's SW corner in UTM32 km
(`dgm1_32_<E>_<N>_...`), which is how `bake_map.py`'s `load_mosaic()` finds
and stitches tiles — download enough 1×1 km tiles to cover your map
rectangle with margin, and name them to match that pattern in
`tools/map_sources/<area>/`.

Attribution: dl-de/by-2-0 (keep it in `map.json` and any published build,
same as the Sebexen credit).

## 2. Get an OSM extract

Export an `.osm` XML extract (e.g. from openstreetmap.org's export tool, or
`overpass-api` for a larger area) covering the same rectangle, and drop it in
`tools/map_sources/<area>/<area>.osm`.

## 3. Point the script at the new area

In `tools/bake_map.py`, update:

- `SRC` / `OUT` — swap `"sebexen"` for your area name (or add an `AREA`
  constant and derive both from it).
- `E_MIN, E_MAX, N_MIN, N_MAX` — your map rectangle in EPSG:25832 meters,
  snapped to whole meters within your OSM extract and tile coverage.
- `TILES_E, TILES_N`, `MOSAIC_E0, MOSAIC_N1` — the DGM1 tile grid (in km)
  covering that rectangle, and the mosaic's west/north edge in meters.
- `SPAWN_E, SPAWN_N` — pick a flat, open spot for the drone's spawn pad
  (roughly — the bake's flatten pass forces flatness here regardless of the
  underlying relief, so it doesn't need to be exactly flat, just not, say, a
  cliff edge or a lake).

Leave `CELL`, `TEX_CELL`, road/tree density constants as-is unless you
specifically want a different tuning for the new area.

## 4. Run it

```
.venv/bin/python tools/bake_map.py
```

(create the venv first if you haven't: `python3 -m venv .venv && .venv/bin/pip install pyproj pillow numpy`)

Watch for the self-check assertion at the end of `main()`:

```
assert patch.max() - patch.min() < 5.0, "spawn area too steep for the flatten pass"
```

If this fires, your `SPAWN_E`/`SPAWN_N` sits somewhere with too much local
relief (a slope, riverbank, etc.) for the flatten pass to smooth away
convincingly — pick a flatter spot from the DEM and re-run. The other
assertions (land classes present, building/tree counts > 0) are sanity
checks that your OSM extract actually has the features you expect; a failure
there usually means the extract's bounding box doesn't line up with
`E_MIN..E_MAX, N_MIN..N_MAX`.

## 5. Wire it into a scene

Baked outputs land in `assets/maps/<area>/` (checked in — see the
`bake_map.py` docstring for exactly what's written). Point a scene's
`OsmTerrain.map_dir` export at `res://assets/maps/<area>` (either a new
scene, or swap it in `main.tscn` for testing). `export_presets.cfg` already
includes `assets/maps/*` in the web export filter, so a new area ships
automatically once it's checked in.
