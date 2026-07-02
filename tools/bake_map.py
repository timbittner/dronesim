#!/usr/bin/env python3
"""Bake the Sebexen map: DGM1 elevation tiles + OSM extract -> Godot assets.

One-time offline step (outputs are checked into the repo):

    python3 -m venv .venv && .venv/bin/pip install pyproj pillow numpy
    .venv/bin/python tools/bake_map.py

Inputs (tools/map_sources/sebexen/, gitignored):
  - dgm1_32_<E>_<N>_1_ni_2016.tif  LGLN DGM1 1m elevation, 1x1 km tiles,
    EPSG:25832. Free download, no API key: the tile index at
    https://services-eu1.arcgis.com/4v3xxN52w88W065F/arcgis/rest/services/
    lgln_opengeodata_dgm1/FeatureServer/0/query (portal:
    https://opengeodata.lgln.niedersachsen.de/) lists per-tile URLs like
    https://dgm1.s3.eu-de.cloud-object-storage.appdomain.cloud/L1606/
    Vollkacheln/dgm1_32_569_5740_1_ni_2016.tif
  - sebexen.osm  OSM XML extract (openstreetmap.org export)

Outputs (assets/maps/sebexen/):
  - heightmap.bin  float32 LE grid, row 0 = north edge, heights in meters
                   relative to the spawn point (spawn ground = 0)
  - classmap.bin   uint8 grid, same dims: 0 field, 1 forest, 2 water, 3 road
  - map.json       grid metadata + building footprints in local meters

Local frame (matches Godot): origin = spawn point, x = east, z = south.
"""

import json
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from pyproj import Transformer

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "tools/map_sources/sebexen"
OUT = ROOT / "assets/maps/sebexen"

# Map rectangle in EPSG:25832, snapped to whole meters inside the OSM extract
# bounds (E 569349..572753, N 5740080..5742495) and the 12 downloaded tiles.
E_MIN, E_MAX = 569350, 572750
N_MIN, N_MAX = 5740090, 5742490
TILES_E, TILES_N = range(569, 573), range(5740, 5743)
MOSAIC_E0, MOSAIC_N1 = 569000, 5743000  # west edge / north edge of tile mosaic

# Flat open field between Sebexen and the forest to the north. Originally
# picked from the DEM; moved 2026-07 to the user's preferred in-game spot
# (was local [-269.521, -400.334] under the old origin) — the flatten pass
# forces a pad here regardless of underlying relief, so exact flatness at
# pick time no longer matters.
SPAWN_E, SPAWN_N = 570730, 5742050

CELL = 2.0  # meters per grid cell (DGM1 native 1 m, downsampled 2:1)

CLASS_FIELD, CLASS_FOREST, CLASS_WATER, CLASS_ROAD = 0, 1, 2, 3

ROAD_WIDTHS = {  # meters; anything else gets the default
    "primary": 7.0, "secondary": 7.0, "tertiary": 6.0,
    "residential": 5.0, "unclassified": 5.0, "service": 4.0,
    "track": 3.0, "path": 2.0, "footway": 2.0, "cycleway": 2.0,
}
ROAD_WIDTH_DEFAULT = 4.0
WATERWAY_WIDTH = 2.0
BUILDING_HEIGHT_DEFAULT = 6.0  # no building:levels in this extract


def load_mosaic() -> np.ndarray:
    mos = np.zeros((3000, 4000), np.float32)
    for e in TILES_E:
        for n in TILES_N:
            tile = np.array(Image.open(SRC / f"dgm1_32_{e}_{n}_1_ni_2016.tif"))
            assert tile.shape == (1000, 1000), tile.shape
            r0 = MOSAIC_N1 - (n + 1) * 1000
            c0 = e * 1000 - MOSAIC_E0
            mos[r0:r0 + 1000, c0:c0 + 1000] = tile
    return mos


def build_height_grid(mos: np.ndarray) -> tuple[np.ndarray, float]:
    r0, r1 = MOSAIC_N1 - N_MAX, MOSAIC_N1 - N_MIN
    c0, c1 = E_MIN - MOSAIC_E0, E_MAX - MOSAIC_E0
    grid = mos[r0:r1 + 1:int(CELL), c0:c1 + 1:int(CELL)].copy()
    datum = float(mos[MOSAIC_N1 - SPAWN_N, SPAWN_E - MOSAIC_E0])
    return grid - datum, datum


class Osm:
    """The OSM extract, with node coords already in the local frame."""

    def __init__(self, path: Path):
        to_utm = Transformer.from_crs("EPSG:4326", "EPSG:25832", always_xy=True)
        root = ET.parse(path).getroot()
        self.nodes: dict[str, tuple[float, float]] = {}
        for n in root.iter("node"):
            e, north = to_utm.transform(float(n.get("lon")), float(n.get("lat")))
            self.nodes[n.get("id")] = (e - SPAWN_E, -(north - SPAWN_N))
        self.way_refs: dict[str, list[str]] = {}
        self.way_tags: dict[str, dict[str, str]] = {}
        for w in root.iter("way"):
            wid = w.get("id")
            self.way_refs[wid] = [nd.get("ref") for nd in w.findall("nd")]
            self.way_tags[wid] = {t.get("k"): t.get("v") for t in w.findall("tag")}
        self.relations = list(root.iter("relation"))

    def pts(self, wid: str) -> list[tuple[float, float]]:
        return [self.nodes[r] for r in self.way_refs[wid] if r in self.nodes]

    def outer_rings(self, rel) -> list[list[tuple[float, float]]]:
        """Stitch a multipolygon relation's outer member ways into rings."""
        segs = [list(self.way_refs[m.get("ref")])
                for m in rel.findall("member")
                if m.get("type") == "way" and m.get("role") == "outer"
                and m.get("ref") in self.way_refs]
        rings = []
        while segs:
            ring = segs.pop(0)
            grew = True
            while grew and ring[0] != ring[-1]:
                grew = False
                for i, s in enumerate(segs):
                    if s[0] == ring[-1]:
                        ring += s[1:]
                    elif s[-1] == ring[-1]:
                        ring += list(reversed(s))[1:]
                    elif s[-1] == ring[0]:
                        ring = s + ring[1:]
                    elif s[0] == ring[0]:
                        ring = list(reversed(s)) + ring[1:]
                    else:
                        continue
                    segs.pop(i)
                    grew = True
                    break
            rings.append([self.nodes[r] for r in ring if r in self.nodes])
        return rings


def to_px(pts: list[tuple[float, float]]) -> list[tuple[float, float]]:
    x0, z0 = E_MIN - SPAWN_E, -(N_MAX - SPAWN_N)
    return [((x - x0) / CELL, (z - z0) / CELL) for x, z in pts]


def build_classmap(osm: Osm, shape: tuple[int, int]) -> np.ndarray:
    img = Image.new("L", (shape[1], shape[0]), CLASS_FIELD)
    draw = ImageDraw.Draw(img)

    def polygon(pts, cls):
        if len(pts) >= 3:
            draw.polygon(to_px(pts), fill=cls)

    def line(pts, cls, width_m):
        if len(pts) >= 2:
            draw.line(to_px(pts), fill=cls, width=max(1, round(width_m / CELL)))

    for wid, tags in osm.way_tags.items():
        if tags.get("landuse") == "forest" or tags.get("natural") == "wood":
            polygon(osm.pts(wid), CLASS_FOREST)
    for rel in osm.relations:
        tags = {t.get("k"): t.get("v") for t in rel.findall("tag")}
        if tags.get("type") == "multipolygon" and (
                tags.get("landuse") == "forest" or tags.get("natural") == "wood"):
            for ring in osm.outer_rings(rel):
                polygon(ring, CLASS_FOREST)
    for wid, tags in osm.way_tags.items():
        if tags.get("natural") == "water" or tags.get("landuse") == "reservoir":
            polygon(osm.pts(wid), CLASS_WATER)
        elif "waterway" in tags:
            line(osm.pts(wid), CLASS_WATER, WATERWAY_WIDTH)
    for wid, tags in osm.way_tags.items():
        if "highway" in tags:
            line(osm.pts(wid), CLASS_ROAD,
                 ROAD_WIDTHS.get(tags["highway"], ROAD_WIDTH_DEFAULT))
    return np.array(img, np.uint8)


def collect_buildings(osm: Osm) -> list[dict]:
    out = []
    for wid, tags in osm.way_tags.items():
        if "building" not in tags:
            continue
        pts = osm.pts(wid)
        if len(pts) >= 4 and pts[0] == pts[-1]:
            pts = pts[:-1]
        if len(pts) < 3:
            continue
        levels = tags.get("building:levels")
        height = float(levels) * 3.0 if levels else BUILDING_HEIGHT_DEFAULT
        out.append({"pts": [[round(x, 2), round(z, 2)] for x, z in pts],
                    "h": height})
    return out


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    mos = load_mosaic()
    grid, datum = build_height_grid(mos)
    osm = Osm(SRC / "sebexen.osm")
    classmap = build_classmap(osm, grid.shape)
    buildings = collect_buildings(osm)

    (OUT / "heightmap.bin").write_bytes(grid.astype("<f4").tobytes())
    (OUT / "classmap.bin").write_bytes(classmap.tobytes())
    meta = {
        "name": "sebexen",
        "cell_size": CELL,
        "grid_width": grid.shape[1],
        "grid_height": grid.shape[0],
        "origin_x": float(E_MIN - SPAWN_E),
        "origin_z": float(-(N_MAX - SPAWN_N)),
        "height_datum": round(datum, 2),
        "utm": {"epsg": 25832, "e_min": E_MIN, "n_max": N_MAX,
                "spawn_e": SPAWN_E, "spawn_n": SPAWN_N},
        "classes": {"0": "field", "1": "forest", "2": "water", "3": "road"},
        "buildings": buildings,
        "attribution": [
            "Elevation: DGM1 (c) LGLN Niedersachsen 2016, dl-de/by-2-0",
            "Map data (c) OpenStreetMap contributors, ODbL",
        ],
    }
    (OUT / "map.json").write_text(json.dumps(meta, separators=(",", ":")))

    # Self-checks
    h, w = grid.shape
    assert (w, h) == ((E_MAX - E_MIN) // int(CELL) + 1,
                      (N_MAX - N_MIN) // int(CELL) + 1), (w, h)
    spawn_col = round((0 - meta["origin_x"]) / CELL)
    spawn_row = round((0 - meta["origin_z"]) / CELL)
    assert abs(grid[spawn_row, spawn_col]) < 0.01, "spawn ground must be ~0"
    # Not required to be dead flat here: OsmTerrain flattens the pad at
    # runtime (osm_terrain.gd::_flatten_spawn_pad) regardless of raw relief.
    # This just guards against picking a spot on a cliff/building by mistake.
    patch = grid[spawn_row - 5:spawn_row + 5, spawn_col - 5:spawn_col + 5]
    assert patch.max() - patch.min() < 5.0, "spawn area too steep for the flatten pass"
    counts = {c: int((classmap == c).sum()) for c in range(4)}
    assert all(counts[c] > 0 for c in range(4)), counts
    assert len(buildings) > 600, len(buildings)
    print(f"grid {w}x{h} cells @ {CELL} m, height {grid.min():.1f}..{grid.max():.1f} m rel. spawn (datum {datum:.1f} m)")
    print(f"class cells: {counts}  buildings: {len(buildings)}")
    print(f"wrote {OUT}/heightmap.bin ({grid.nbytes >> 20} MB), classmap.bin, map.json")


if __name__ == "__main__":
    main()
