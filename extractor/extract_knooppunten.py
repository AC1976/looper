#!/usr/bin/env python3
"""
Extract the Dutch fietsknooppuntennetwerk (cycle node network) from an OSM .pbf.

Input : a Geofabrik extract, e.g. netherlands-latest.osm.pbf
Output: three layers, as GeoParquet (default) and/or GeoJSON
  junctions  – numbered knooppunten (Point)
  segments   – one row per signed route between two knooppunten (LineString/MultiLineString)
  ways       – the underlying OSM ways with per-way safety tier (LineString); routing layer

How OSM models the network (verified on the NL extract):
  * junction  = node with rcn_ref=<number>, network:type=node_network
  * segment   = relation type=route, route=bicycle, network=rcn, network:type=node_network,
                ref="<a>-<b>", members = ways (role "", "forward" or "backward")
Knooppunt numbers are only unique locally, so segments are tied to junctions by
finding the junction *nodes* on the segment's ways, not by number alone.

Memory: three filtered passes, so only the nodes we need are held in RAM
(~1 GB peak for the whole of NL).

Data © OpenStreetMap contributors, ODbL 1.0. Outputs are a derivative database
and must be shared under ODbL if distributed.

Usage:
  python3 extract_knooppunten.py netherlands-latest.osm.pbf -o out/ [--geojson] [--no-parquet]
"""
from __future__ import annotations

import argparse
import json
import math
import re
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

import osmium
import geopandas as gpd
from shapely.geometry import LineString, MultiLineString, Point
from shapely.ops import linemerge

# ----------------------------------------------------------------------------
# Tag vocabulary
# ----------------------------------------------------------------------------

WAY_TAGS = [
    "highway", "name", "surface", "smoothness", "tracktype", "lit", "width",
    "cycleway", "cycleway:left", "cycleway:right", "cycleway:both",
    "bicycle", "bicycle_road", "cyclestreet", "moped", "mofa", "motor_vehicle",
    "motorcar", "access", "foot", "segregated", "maxspeed", "oneway",
    "oneway:bicycle", "route", "duration", "bridge", "tunnel", "cycle_highway",
]
NODE_TAGS = ["rcn_ref", "network:type", "expected_rcn_route_relations", "name", "survey:date"]

PAVED = {"asphalt", "paved", "concrete", "concrete:plates", "concrete:lanes",
         "paving_stones", "sett", "chipseal", "metal", "wood", "bricks", "clay"}
SEMI = {"compacted", "fine_gravel", "gravel", "pebblestone", "shells"}
UNPAVED = {"dirt", "earth", "ground", "grass", "mud", "sand", "unpaved",
           "woodchips", "rock", "grass_paver"}

# Safety classification: a coarse tier (1 = safest) and a finer label explaining why.
# label -> (tier, score 0–100 used for the length-weighted segment safety score)
LABELS = {
    "separated":     (1, 100),  # own cycleway / designated bike path / cycle track
    "bike_priority": (2, 90),   # fietsstraat, car-free road, agricultural track, path
    "quiet_shared":  (3, 70),   # shared with cars at ≤30 km/h, living/residential street
    "rural_lane":    (4, 60),   # minor rural road ≤60 km/h shared with cars (erftoegangsweg)
    "painted_lane":  (4, 55),   # cycle lane on a road with motor traffic ≤50 km/h
    "shared_road":   (5, 25),   # through road or >60 km/h, no bike facility
    "ferry":         (0, 70),   # pont – timetable-dependent
}
TIER_ORDER = ["separated", "bike_priority", "quiet_shared", "rural_lane", "painted_lane", "shared_road", "ferry"]

# Untagged surface on these road types is paved in practice in NL.
ASSUME_PAVED = {"cycleway", "residential", "living_street", "unclassified", "tertiary",
                "tertiary_link", "secondary", "secondary_link", "primary", "primary_link", "service"}

# Built-up land, for "how much of this route is in town". Villages count too: in OSM a
# village core is mapped the same way as a city.
URBAN_LANDUSE = ("residential", "commercial", "retail", "industrial")
# Dutch landuse is often mapped per block, with the streets between blocks left outside
# the polygons; widen each polygon so the streets through a town count as urban.
URBAN_BUFFER_M = 25
# Parks, canals and quays inside a town have no residential/commercial landuse, but riding
# there is still riding in town. Grow the merged areas by this much and shrink them back:
# gaps narrower than about twice this are filled, the outer edge of each town stays put.
URBAN_CLOSE_M = 200
URBAN_TILE_M = 2_000  # gaps are filled per tile of this size, to keep memory low
# Traffic-light nodes closer together than this along a route are one intersection
# (lights are often mapped at every stop line).
SIGNAL_CLUSTER_M = 40
RD_NEW = "EPSG:28992"  # Dutch national grid, metres

REF_RE = re.compile(r"^\s*(\d{1,3})\s*-\s*(\d{1,3})\s*$")
JUNCTION_CLUSTER_M = 200  # one knooppunt is often mapped on several nodes (both sides of a road)


def norm_number(v: str | None) -> str | None:
    """'09' -> '9', so refs and rcn_ref compare equal."""
    if v is None:
        return None
    v = v.strip()
    return str(int(v)) if v.isdigit() else v


def surface_class(t: dict) -> str:
    s = t.get("surface")
    if s in PAVED:
        return "paved"
    if s in SEMI:
        return "semi_paved"
    if s in UNPAVED:
        return "unpaved"
    if s is None:
        return "assumed_paved" if t.get("highway") in ASSUME_PAVED else "unknown"
    return "unknown"


def maxspeed_kmh(v: str | None) -> float | None:
    if not v:
        return None
    if v.startswith("NL:"):
        return {"NL:urban": 50, "NL:rural": 80, "NL:zone30": 30, "NL:zone60": 60}.get(v)
    if v in ("walk", "NL:living_street"):
        return 10
    m = re.match(r"^\s*(\d+(?:\.\d+)?)", v)
    if not m:
        return None
    x = float(m.group(1))
    return x * 1.609 if "mph" in v else x


def safety_label(t: dict) -> str:
    hw = t.get("highway")
    bike = t.get("bicycle")
    if t.get("route") == "ferry":
        return "ferry"
    side = [t.get(k) for k in ("cycleway", "cycleway:left", "cycleway:right", "cycleway:both")]
    if hw == "cycleway":
        return "separated"
    if hw in ("path", "footway", "bridleway", "pedestrian") and bike in ("designated", "yes", "permissive"):
        return "separated"
    if any(v in ("track", "opposite_track") for v in side):
        return "separated"
    if t.get("bicycle_road") == "yes" or t.get("cyclestreet") == "yes":
        return "bike_priority"
    if t.get("motor_vehicle") in ("no", "agricultural", "forestry") or t.get("motorcar") == "no":
        return "bike_priority"
    if hw in ("track", "path", "footway", "pedestrian", "bridleway"):
        return "bike_priority"
    v = maxspeed_kmh(t.get("maxspeed"))
    if any(x in ("lane", "opposite_lane", "shoulder", "share_busway") for x in side):
        return "painted_lane" if (v is None or v <= 50) else "shared_road"
    if hw == "living_street" or (v is not None and v <= 30):
        return "quiet_shared"
    if hw in ("residential", "service") and v is None:
        return "quiet_shared"
    if hw in ("unclassified", "residential", "service") and (v is None or v <= 60):
        return "rural_lane"
    return "shared_road"


# ----------------------------------------------------------------------------
# Geometry helpers
# ----------------------------------------------------------------------------

R = 6_371_008.8


def haversine(lon1, lat1, lon2, lat2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1, math.sqrt(h)))


def polyline_length(coords) -> float:
    return sum(haversine(*a, *b) for a, b in zip(coords, coords[1:]))


# ----------------------------------------------------------------------------
# Pass 1 – relations
# ----------------------------------------------------------------------------

@dataclass
class Segment:
    id: int
    ref: str
    tags: dict
    members: list  # [(way_id, role)]
    timestamp: str
    version: int


def read_segments(path: str) -> list[Segment]:
    segs = []
    fp = osmium.FileProcessor(path, osmium.osm.RELATION).with_filter(
        osmium.filter.TagFilter(("network", "rcn")))
    for r in fp:
        t = r.tags
        if t.get("type") != "route" or t.get("route") != "bicycle":
            continue
        if t.get("network:type") != "node_network":
            continue
        members = []
        for m in r.members:
            if m.type == "w":
                members.append((m.ref, m.role))
        segs.append(Segment(r.id, t.get("ref", ""), dict(t), members,
                            r.timestamp.isoformat(), r.version))
    return segs


# ----------------------------------------------------------------------------
# Pass 2 – ways, Pass 3 – nodes
# ----------------------------------------------------------------------------

def read_long_distance_routes(path: str) -> tuple[dict[int, set[str]], dict[str, list[str]]]:
    """Ways on the curated long-distance cycle routes: the Dutch LF routes (route=bicycle,
    network=ncn) and EuroVelo (network=icn).

    Returns way id -> {"lf", "eurovelo"} and, per kind, the route names/refs found.
    EuroVelo routes are often super-relations made of sub-relations (which may be tagged
    ncn, rcn or nothing), so sub-relations are followed down, a few levels deep.
    """
    kinds = {"ncn": "lf", "icn": "eurovelo"}
    relations: dict[int, tuple[str | None, list[tuple[str, int]]]] = {}
    names: dict[str, list[str]] = {"lf": [], "eurovelo": []}
    fp = osmium.FileProcessor(path, osmium.osm.RELATION).with_filter(
        osmium.filter.TagFilter(("network", "ncn"), ("network", "icn")))
    for r in fp:
        if r.tags.get("type") not in ("route", "superroute") or r.tags.get("route") != "bicycle":
            continue
        kind = kinds[r.tags.get("network")]
        relations[r.id] = (kind, [(m.type, m.ref) for m in r.members if m.type in ("w", "r")])
        names[kind].append(r.tags.get("ref") or r.tags.get("name") or str(r.id))
    # Sub-relations not read yet (any tags): read them by id, a few levels deep.
    for _ in range(3):
        missing = {ref for _, members in relations.values() for t, ref in members if t == "r"} - set(relations)
        if not missing:
            break
        for r in osmium.FileProcessor(path, osmium.osm.RELATION).with_filter(osmium.filter.IdFilter(missing)):
            relations[r.id] = (None, [(m.type, m.ref) for m in r.members if m.type in ("w", "r")])

    on: dict[int, set[str]] = defaultdict(set)
    def mark(rid: int, kind: str, depth: int = 0):
        if rid not in relations or depth > 4:
            return
        for t, ref in relations[rid][1]:
            if t == "w":
                on[ref].add(kind)
            else:
                mark(ref, kind, depth + 1)
    for rid, (kind, _) in relations.items():
        if kind is not None:
            mark(rid, kind)
    return on, names


def read_ways(path: str, way_ids: set[int]) -> dict:
    ways = {}
    fp = osmium.FileProcessor(path, osmium.osm.WAY).with_filter(osmium.filter.IdFilter(way_ids))
    for w in fp:
        tags = {k: w.tags[k] for k in WAY_TAGS if k in w.tags}
        ways[w.id] = {"nodes": [n.ref for n in w.nodes], "tags": tags,
                      "timestamp": w.timestamp.isoformat(), "version": w.version}
    return ways


def is_traffic_signal(tags) -> bool:
    return tags.get("highway") == "traffic_signals" or tags.get("crossing") == "traffic_signals"


def read_nodes(path: str, node_ids: set[int]) -> tuple[dict, dict, set[int]]:
    """Returns coordinates for the requested nodes, *all* junction nodes in the file, and
    which of the requested nodes are traffic lights."""
    coords, junctions, signals = {}, {}, set()
    fp = osmium.FileProcessor(path, osmium.osm.NODE)
    # Two filters can't be OR-ed cheaply, so do the junction scan in a second, tag-filtered read.
    for n in fp.with_filter(osmium.filter.IdFilter(node_ids)):
        if n.location.valid():
            coords[n.id] = (n.location.lon, n.location.lat)
            if is_traffic_signal(n.tags):
                signals.add(n.id)
    for n in osmium.FileProcessor(path, osmium.osm.NODE).with_filter(osmium.filter.KeyFilter("rcn_ref")):
        if not n.location.valid():
            continue
        junctions[n.id] = {
            "tags": {k: n.tags[k] for k in NODE_TAGS if k in n.tags},
            "lonlat": (n.location.lon, n.location.lat),
            "timestamp": n.timestamp.isoformat(),
        }
        coords.setdefault(n.id, (n.location.lon, n.location.lat))
    return coords, junctions, signals


# ----------------------------------------------------------------------------
# Urban areas (landuse) – read like the route data: filtered passes, then only the
# nodes needed, instead of osmium's area builder (which indexes every node location).
# ----------------------------------------------------------------------------

def read_urban_landuse(path: str) -> tuple[list[list[int]], dict[int, list[int]], set[int]]:
    """Closed landuse ways, plus the outer member ways of landuse multipolygons.

    Returns (closed ways as node lists, multipolygon id -> outer way ids, node ids needed).
    Inner rings (courtyards inside a residential area) are ignored: they don't change
    whether a street is in town.
    """
    tag_filter = osmium.filter.TagFilter(*[("landuse", v) for v in URBAN_LANDUSE])
    outers: dict[int, list[int]] = {}
    for r in osmium.FileProcessor(path, osmium.osm.RELATION).with_filter(tag_filter):
        if r.tags.get("type") == "multipolygon":
            outers[r.id] = [m.ref for m in r.members if m.type == "w" and m.role in ("outer", "")]
    member_ids = {w for ws in outers.values() for w in ws}

    closed: list[list[int]] = []
    for w in osmium.FileProcessor(path, osmium.osm.WAY).with_filter(tag_filter):
        nodes = [n.ref for n in w.nodes]
        if len(nodes) >= 4 and nodes[0] == nodes[-1]:
            closed.append(nodes)
    member_nodes: dict[int, list[int]] = {}
    if member_ids:
        for w in osmium.FileProcessor(path, osmium.osm.WAY).with_filter(osmium.filter.IdFilter(member_ids)):
            member_nodes[w.id] = [n.ref for n in w.nodes]

    rings = closed + [[*member_nodes[w]] for ws in outers.values() for w in ws if w in member_nodes]
    needed = {n for ring in rings for n in ring}
    relation_rings = {rid: [member_nodes[w] for w in ws if w in member_nodes] for rid, ws in outers.items()}
    return closed, relation_rings, needed


def urban_polygons(closed: list[list[int]], relation_rings: dict[int, list[list[int]]], coords: dict) -> list:
    """Shapely polygons (lon/lat) from the landuse ways and multipolygon outer rings."""
    from shapely.geometry import Polygon
    from shapely.ops import polygonize

    polys = []
    for nodes in closed:
        pts = [coords[n] for n in nodes if n in coords]
        if len(pts) >= 4:
            p = Polygon(pts)
            if p.is_valid and p.area > 0:
                polys.append(p)
    for rings in relation_rings.values():
        lines = [LineString([coords[n] for n in r if n in coords]) for r in rings]
        lines = [l for l in lines if len(l.coords) >= 2]
        if lines:
            polys.extend(p for p in polygonize(linemerge(MultiLineString(lines))) if p.area > 0)
    return polys


def grow_urban(polys: list):
    """The urban areas in the Dutch grid (metres), each widened by URBAN_BUFFER_M, and a
    spatial index over them."""
    import shapely
    grown = gpd.GeoSeries(polys, crs="EPSG:4326").to_crs(RD_NEW).buffer(URBAN_BUFFER_M).values
    return grown, shapely.STRtree(grown)


def urban_shares(way_geoms: dict[int, LineString], grown, grown_tree) -> dict[int, float]:
    """Share (0–1) of each way's length inside the (widened) urban areas."""
    import shapely
    if len(grown) == 0 or not way_geoms:
        return {wid: 0.0 for wid in way_geoms}
    from shapely.geometry import box
    ids = list(way_geoms)
    lines = gpd.GeoSeries([way_geoms[w] for w in ids], crs="EPSG:4326").to_crs(RD_NEW).values

    # Fill the gaps tile by tile: growing and shrinking the whole country's areas at once
    # takes tens of GB. Closing at a point only depends on shapes within 2 × URBAN_CLOSE_M,
    # so each tile looks that far past its edges and the result matches the one-piece version.
    tile, margin = URBAN_TILE_M, 2 * URBAN_CLOSE_M
    needed = set()
    for line in lines:
        x0, y0, x1, y1 = line.bounds
        for i in range(int(x0 // tile), int(x1 // tile) + 1):
            for j in range(int(y0 // tile), int(y1 // tile) + 1):
                needed.add((i, j))
    pieces = []
    for i, j in needed:
        cell = box(i * tile, j * tile, (i + 1) * tile, (j + 1) * tile)
        around = cell.buffer(margin, join_style="mitre")
        hits = grown_tree.query(around, predicate="intersects")
        if len(hits) == 0:
            continue
        local = shapely.union_all(grown[hits]).intersection(around)
        closed = local.buffer(URBAN_CLOSE_M, quad_segs=4).buffer(-URBAN_CLOSE_M, quad_segs=4)
        piece = closed.intersection(cell)
        if not piece.is_empty:
            pieces.append(piece)
    tree = shapely.STRtree(pieces)

    shares = {}
    for wid, line in zip(ids, lines):
        if line.length == 0:
            shares[wid] = 0.0
            continue
        # Tiles don't overlap, so the lengths inside each tile's piece simply add up.
        hits = tree.query(line, predicate="intersects")
        inside = sum(line.intersection(pieces[h]).length for h in hits)
        shares[wid] = min(1.0, inside / line.length)
    return shares


def count_intersections(points: list[tuple[float, float]]) -> int:
    """Traffic-light nodes along a route, with nodes within SIGNAL_CLUSTER_M merged."""
    seen: list[tuple[float, float]] = []
    for p in points:
        if all(haversine(*p, *q) > SIGNAL_CLUSTER_M for q in seen):
            seen.append(p)
    return len(seen)


# ----------------------------------------------------------------------------
# Cyclability grid – where is it good to ride? Above all: away from town, in open space.
# ----------------------------------------------------------------------------

# Cells of 0.018° latitude × 0.03° longitude, about 2 km × 2 km in the Netherlands. Cell
# (i, j) covers latitudes [i·dlat, (i+1)·dlat) and longitudes [j·dlon, (j+1)·dlon); a plain
# lat/lon grid so the router can find a cell without map projections.
CELL_DLAT, CELL_DLON = 0.018, 0.03
# Scenery: what makes a ride nicer than plain farmland. Areas with these tags count, plus a
# strip along the coast (the sea has no area in OSM, only the coastline).
SCENIC_TAGS = [("natural", v) for v in ("water", "wood", "heath", "beach", "dune", "sand", "wetland", "scrub",
                                        "grassland")] + [("landuse", "forest"), ("leisure", "nature_reserve"),
                                                         ("waterway", "riverbank")]
COAST_STRIP_M = 500
# Route quality of a way's surface, on top of its safety score.
SURFACE_QUALITY = {"paved": 1.0, "assumed_paved": 1.0, "semi_paved": 0.8, "unpaved": 0.5, "unknown": 0.8}


def read_scenery(path: str, log=print):
    """Scenic areas and the coast, as shapes in the Dutch grid (metres), with a spatial index.

    There are about 940,000 such areas with 23 million nodes in the Netherlands, ten times
    the built-up land, so they're read into compact arrays rather than Python objects: way
    node lists in one flat array, then one filtered node pass. Nodes come out of the file
    sorted by id, so they line up with the sorted list of ids needed.
    """
    import numpy as np
    import shapely
    from array import array
    from shapely.ops import polygonize

    tag_filter = osmium.filter.TagFilter(*SCENIC_TAGS)
    outers: dict[int, list[int]] = {}
    for r in osmium.FileProcessor(path, osmium.osm.RELATION).with_filter(tag_filter):
        if r.tags.get("type") == "multipolygon":
            outers[r.id] = [m.ref for m in r.members if m.type == "w" and m.role in ("outer", "")]
    member_ids = {w for ws in outers.values() for w in ws}

    refs = array("q")               # all node refs, way after way
    starts = array("q", [0])        # where each way's refs start
    kind = array("b")               # 0 = closed area, 1 = multipolygon member, 2 = coastline
    member_index: dict[int, int] = {}
    def add(nodes, k):
        refs.extend(nodes)
        starts.append(len(refs))
        kind.append(k)
    coast_filter = osmium.filter.TagFilter(("natural", "coastline"))
    for w in osmium.FileProcessor(path, osmium.osm.WAY).with_filter(tag_filter):
        nodes = [n.ref for n in w.nodes]
        if len(nodes) >= 4 and nodes[0] == nodes[-1]:
            add(nodes, 0)
    for w in osmium.FileProcessor(path, osmium.osm.WAY).with_filter(coast_filter):
        add([n.ref for n in w.nodes], 2)
    if member_ids:
        for w in osmium.FileProcessor(path, osmium.osm.WAY).with_filter(osmium.filter.IdFilter(member_ids)):
            member_index[w.id] = len(kind)
            add([n.ref for n in w.nodes], 1)
    all_refs = np.frombuffer(refs, dtype=np.int64)
    needed = np.unique(all_refs)
    log(f"  scenery: {len(kind):,} ways, {len(needed):,} nodes to read")

    ids, lons, lats = array("q"), array("d"), array("d")
    for n in osmium.FileProcessor(path, osmium.osm.NODE).with_filter(osmium.filter.IdFilter(needed.tolist())):
        if n.location.valid():
            ids.append(n.id)
            lons.append(n.location.lon)
            lats.append(n.location.lat)
    ids = np.frombuffer(ids, dtype=np.int64)
    order = np.argsort(ids, kind="stable")  # normally already sorted
    ids, lons, lats = ids[order], np.frombuffer(lons)[order], np.frombuffer(lats)[order]
    from pyproj import Transformer
    x, y = Transformer.from_crs("EPSG:4326", RD_NEW, always_xy=True).transform(lons, lats)
    pos = np.searchsorted(ids, all_refs)
    pos = np.clip(pos, 0, max(0, len(ids) - 1))
    found = (len(ids) > 0) & (ids[pos] == all_refs) if len(ids) else np.zeros(len(all_refs), bool)

    def coords(k):
        a, b = starts[k], starts[k + 1]
        ok = found[a:b]
        return np.column_stack([x[pos[a:b]][ok], y[pos[a:b]][ok]])

    shapes, coast = [], []
    for k in range(len(kind)):
        if kind[k] == 0:
            c = coords(k)
            if len(c) >= 4:
                p = shapely.Polygon(c)
                shapes.append(p if p.is_valid else p.buffer(0))
        elif kind[k] == 2:
            c = coords(k)
            if len(c) >= 2:
                coast.append(shapely.LineString(c))
    for ws in outers.values():
        lines = [shapely.LineString(c) for w in ws if w in member_index and len(c := coords(member_index[w])) >= 2]
        if lines:
            shapes.extend(polygonize(linemerge(MultiLineString(lines))))
    if coast:
        shapes.extend(shapely.buffer(np.array(coast), COAST_STRIP_M, quad_segs=2))
    shapes = [g for g in shapes if not g.is_empty and g.area > 0]
    log(f"  scenery: {len(shapes):,} areas (incl. {len(coast):,} coastline strips)")
    arr = np.array(shapes, dtype=object)
    return arr, shapely.STRtree(arr)


def cell_of(lon: float, lat: float) -> tuple[int, int]:
    return math.floor(lat / CELL_DLAT), math.floor(lon / CELL_DLON)


def cyclability(built_up: float, around: float, quality: float, signals: int, scenic: float = 0.0) -> int:
    """0–100: how good a cell is to ride in, dominated by open space.

    openness = 1 − (half the cell's own built-up share + half its 8 neighbours'), so the
    fringe of a town scores low too. Cubing it makes open space dominate: 80 % open keeps
    half the score, 50 % open an eighth. Then route quality (safety and surface), few
    traffic lights, and scenery: a cell at least half water, woods, dunes, heath, nature
    reserve or coast scores full marks for it, plain farmland 20 % less. How much network a
    cell has is left out on purpose (it's in `network_km`): one good route clipping a corner
    of open country is still good riding.
    """
    openness = max(0.0, 1 - (0.5 * built_up + 0.5 * around))
    lights = max(0.5, 1 - 0.15 * signals)
    scenery = 0.8 + 0.2 * min(1.0, 2 * scenic)
    return round(100 * openness ** 3 * (0.6 + 0.4 * quality) * lights * scenery)


def rate_cells(route_lines: dict[int, LineString], ways: dict, signal_points: list[tuple[float, float]],
               grown, grown_tree, scenery=None, scenery_tree=None) -> gpd.GeoDataFrame:
    """One row per cell with knooppunt routes in it: built-up share of the land, route km,
    route quality, traffic lights, scenic share and the combined cyclability."""
    import shapely
    from shapely.geometry import box
    from pyproj import Transformer

    # Route length and quality per cell.
    km: Counter = Counter()
    good: Counter = Counter()
    for wid, line in route_lines.items():
        t = ways[wid]["tags"]
        quality = LABELS[safety_label(t)][1] / 100 * SURFACE_QUALITY[surface_class(t)]
        x0, y0, x1, y1 = line.bounds
        i0, j0 = cell_of(x0, y0)
        i1, j1 = cell_of(x1, y1)
        for i in range(i0, i1 + 1):
            for j in range(j0, j1 + 1):
                part = line.intersection(box(j * CELL_DLON, i * CELL_DLAT, (j + 1) * CELL_DLON, (i + 1) * CELL_DLAT))
                if part.is_empty:
                    continue
                parts = getattr(part, "geoms", [part])
                L = sum(polyline_length(list(g.coords)) for g in parts if g.geom_type == "LineString") / 1000
                km[(i, j)] += L
                good[(i, j)] += quality * L

    signals_in: dict[tuple[int, int], list] = defaultdict(list)
    for p in signal_points:
        signals_in[cell_of(*p)].append(p)

    # Built-up share of the land, for the route cells and their neighbours (for "around").
    to_rd = Transformer.from_crs("EPSG:4326", RD_NEW, always_xy=True)
    wanted = {(i + di, j + dj) for i, j in km for di in (-1, 0, 1) for dj in (-1, 0, 1)}
    built: dict[tuple[int, int], float] = {}
    def rd_cell(i, j):
        corners = [(j * CELL_DLON, i * CELL_DLAT), ((j + 1) * CELL_DLON, i * CELL_DLAT),
                   ((j + 1) * CELL_DLON, (i + 1) * CELL_DLAT), (j * CELL_DLON, (i + 1) * CELL_DLAT)]
        return shapely.Polygon([to_rd.transform(x, y) for x, y in corners])
    def covered(cell, shapes, tree):
        hits = tree.query(cell, predicate="intersects") if tree is not None else []
        if len(hits) == 0:
            return 0.0
        try:
            union = shapely.union_all(shapes[hits])
        except shapely.errors.GEOSException:
            # Some OSM areas are drawn crossing themselves; repair this cell's shapes and retry.
            union = shapely.union_all(shapely.make_valid(shapes[hits]))
        return union.intersection(cell).area / cell.area
    for i, j in wanted:
        built[(i, j)] = covered(rd_cell(i, j), grown, grown_tree)

    rows, geoms = [], []
    for (i, j), L in km.items():
        around = sum(built.get((i + di, j + dj), 0.0) for di in (-1, 0, 1) for dj in (-1, 0, 1)
                     if (di, dj) != (0, 0)) / 8
        quality = good[(i, j)] / L if L else 0.0
        n_signals = count_intersections(signals_in.get((i, j), []))
        scenic = min(1.0, covered(rd_cell(i, j), scenery, scenery_tree))
        rows.append({
            "i": i, "j": j,
            "built_up": round(built[(i, j)], 3),
            "built_up_around": round(around, 3),
            "network_km": round(L, 2),
            "quality": round(quality, 3),
            "traffic_signals": n_signals,
            "scenic": round(scenic, 3),
            "cyclability": cyclability(built[(i, j)], around, quality, n_signals, scenic),
        })
        geoms.append(box(j * CELL_DLON, i * CELL_DLAT, (j + 1) * CELL_DLON, (i + 1) * CELL_DLAT))
    return gpd.GeoDataFrame(rows, geometry=geoms, crs="EPSG:4326")


def write_preview_png(cells: gpd.GeoDataFrame, path: Path, scale: int = 3):
    """A map of the cells: green = good riding in open space, red = poor or built-up,
    white = no knooppunt routes. Plain PNG, no plotting library needed."""
    import struct
    import zlib
    if cells.empty:
        return
    i0, i1, j0, j1 = cells.i.min(), cells.i.max(), cells.j.min(), cells.j.max()
    h, w = (i1 - i0 + 1) * scale, (j1 - j0 + 1) * scale
    px = [[(255, 255, 255)] * w for _ in range(h)]
    for i, j, c in zip(cells.i, cells.j, cells.cyclability):
        t = c / 100
        colour = (int(215 * (1 - t) + 26 * t), int(48 * (1 - t) + 150 * t), int(39 * (1 - t) + 65 * t))
        for dy in range(scale):
            row = px[(i1 - i) * scale + dy]  # north up
            for dx in range(scale):
                row[(j - j0) * scale + dx] = colour
    raw = b"".join(b"\x00" + bytes(v for p in row for v in p) for row in px)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    path.write_bytes(png)


# ----------------------------------------------------------------------------
# Assembly
# ----------------------------------------------------------------------------

def components(way_node_lists: list[list[int]]) -> int:
    """Number of connected groups among ways that share nodes."""
    parent = list(range(len(way_node_lists)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    seen: dict[int, int] = {}
    for i, nodes in enumerate(way_node_lists):
        for n in nodes:
            if n in seen:
                a, b = find(i), find(seen[n])
                if a != b:
                    parent[a] = b
            else:
                seen[n] = i
    return len({find(i) for i in range(len(way_node_lists))})


def cluster_junctions(junctions: dict) -> dict[int, int]:
    """Map each junction node id -> knooppunt id (smallest node id in its cluster).

    Nodes with the same number within JUNCTION_CLUSTER_M metres are one physical knooppunt
    (typically mapped on both sides of a road or at each arm of a roundabout).
    """
    by_num = defaultdict(list)
    for nid, j in junctions.items():
        by_num[norm_number(j["tags"].get("rcn_ref"))].append(nid)
    parent = {n: n for n in junctions}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for nids in by_num.values():
        for i, a in enumerate(nids):
            la = junctions[a]["lonlat"]
            for b in nids[i + 1:]:
                lb = junctions[b]["lonlat"]
                if abs(la[1] - lb[1]) > 0.003:  # cheap reject (~330 m)
                    continue
                if haversine(*la, *lb) <= JUNCTION_CLUSTER_M:
                    ra, rb = find(a), find(b)
                    if ra != rb:
                        parent[max(ra, rb)] = min(ra, rb)
    return {n: find(n) for n in junctions}


def build(path: str, log=print):
    t0 = time.time()
    segs = read_segments(path)
    log(f"pass 1: {len(segs):,} segment relations ({time.time() - t0:.0f}s)")
    long_distance, long_distance_names = read_long_distance_routes(path)
    log(f"pass 1b: {len(long_distance_names['lf']):,} LF and {len(long_distance_names['eurovelo']):,} EuroVelo"
        f" relations, {len(long_distance):,} ways on them ({time.time() - t0:.0f}s)")

    way_ids = {wid for s in segs for wid, _ in s.members}
    ways = read_ways(path, way_ids)
    log(f"pass 2: {len(ways):,} of {len(way_ids):,} member ways present ({time.time() - t0:.0f}s)")

    closed_landuse, landuse_relations, landuse_nodes = read_urban_landuse(path)
    log(f"pass 2b: {len(closed_landuse):,} urban landuse ways, {len(landuse_relations):,} multipolygons"
        f" ({time.time() - t0:.0f}s)")

    node_ids = {n for w in ways.values() for n in w["nodes"]}
    coords, junctions, signals = read_nodes(path, node_ids | landuse_nodes)
    log(f"pass 3: {len(coords):,} node locations, {len(junctions):,} junction nodes,"
        f" {len(signals & node_ids):,} traffic-light nodes on routes ({time.time() - t0:.0f}s)")

    polys = urban_polygons(closed_landuse, landuse_relations, coords)
    route_lines = {wid: LineString(pts) for wid, w in ways.items()
                   if len(pts := [coords[n] for n in w["nodes"] if n in coords]) >= 2}
    grown, grown_tree = grow_urban(polys) if polys else ([], None)
    way_urban = urban_shares(route_lines, grown, grown_tree)
    log(f"urban: {len(polys):,} polygons, shares for {len(way_urban):,} ways ({time.time() - t0:.0f}s)")
    scenery, scenery_tree = read_scenery(path, log)
    log(f"scenery read ({time.time() - t0:.0f}s)")
    cells = rate_cells(route_lines, ways, [coords[n] for n in signals & node_ids if n in coords],
                       grown, grown_tree, scenery, scenery_tree)
    log(f"cells: {len(cells):,} cells rated ({time.time() - t0:.0f}s)")
    for n in landuse_nodes - node_ids - set(junctions):
        coords.pop(n, None)  # free the landuse-only nodes

    kp_of = cluster_junctions(junctions)

    # --- ways layer --------------------------------------------------------
    way_segments: dict[int, list[int]] = defaultdict(list)
    for s in segs:
        for wid, _ in s.members:
            way_segments[wid].append(s.id)

    way_rows, way_geom = [], []
    way_len: dict[int, float] = {}
    way_label: dict[int, str] = {}
    for wid, w in ways.items():
        pts = [coords[n] for n in w["nodes"] if n in coords]
        if len(pts) < 2:
            continue
        L = polyline_length(pts)
        t = w["tags"]
        label = safety_label(t)
        way_len[wid], way_label[wid] = L, label
        way_rows.append({
            "way_id": wid,
            "segment_ids": sorted(set(way_segments[wid])),
            "node_ids": w["nodes"],
            "highway": t.get("highway"),
            "name": t.get("name"),
            "safety_tier": LABELS[label][0],
            "safety_label": label,
            "surface": t.get("surface"),
            "surface_class": surface_class(t),
            "smoothness": t.get("smoothness"),
            "lit": t.get("lit"),
            "width": t.get("width"),
            "maxspeed_kmh": maxspeed_kmh(t.get("maxspeed")),
            "mopeds": t.get("moped") or t.get("mofa"),
            "segregated": t.get("segregated"),
            "oneway": t.get("oneway"),
            "oneway_bicycle": t.get("oneway:bicycle"),
            "is_ferry": label == "ferry",
            "is_fietsstraat": t.get("bicycle_road") == "yes" or t.get("cyclestreet") == "yes",
            "cycle_highway": t.get("cycle_highway"),
            "on_lf": "lf" in long_distance.get(wid, ()),
            "on_eurovelo": "eurovelo" in long_distance.get(wid, ()),
            "urban_share": round(way_urban.get(wid, 0.0), 3),
            "traffic_signal_nodes": sum(1 for n in w["nodes"] if n in signals),
            "length_m": round(L, 1),
            "osm_version": w["version"],
            "last_edit": w["timestamp"],
        })
        way_geom.append(LineString(pts))

    # --- segments layer ----------------------------------------------------
    seg_rows, seg_geom = [], []
    kp_segments: dict[int, set[int]] = defaultdict(set)

    for s in segs:
        present = [(wid, role) for wid, role in s.members if wid in way_len]
        missing = len(s.members) - len(present)
        lines, node_lists = [], []
        label_len: Counter = Counter()
        surf_len: Counter = Counter()
        lit_len = fiets_len = moped_len = forward_len = backward_len = urban_len = 0.0
        lf_len = ev_len = 0.0
        signal_points: list[tuple[float, float]] = []
        max_shared_speed = None
        last_edit = s.timestamp
        touching: dict[str, list[int]] = defaultdict(list)  # number -> knooppunt ids on route

        for wid, role in present:
            w = ways[wid]
            t = w["tags"]
            L = way_len[wid]
            lines.append([coords[n] for n in w["nodes"] if n in coords])
            node_lists.append(w["nodes"])
            label = way_label[wid]
            label_len[label] += L
            surf_len[surface_class(t)] += L
            if t.get("lit") == "yes":
                lit_len += L
            urban_len += way_urban.get(wid, 0.0) * L
            if "lf" in long_distance.get(wid, ()):
                lf_len += L
            if "eurovelo" in long_distance.get(wid, ()):
                ev_len += L
            signal_points += [coords[n] for n in w["nodes"] if n in signals and n in coords]
            if t.get("bicycle_road") == "yes" or t.get("cyclestreet") == "yes":
                fiets_len += L
            if t.get("moped") in ("yes", "designated") or t.get("mofa") in ("yes", "designated"):
                moped_len += L
            if role == "forward":
                forward_len += L
            elif role == "backward":
                backward_len += L
            if label in ("rural_lane", "painted_lane", "shared_road", "quiet_shared"):
                v = maxspeed_kmh(t.get("maxspeed"))
                if v is not None:
                    max_shared_speed = max(max_shared_speed or 0, v)
            last_edit = max(last_edit, w["timestamp"])
            for n in w["nodes"]:
                if n in kp_of:
                    num = norm_number(junctions[n]["tags"].get("rcn_ref"))
                    kp = kp_of[n]
                    if kp not in touching[num]:
                        touching[num].append(kp)

        # One-way splits (forward/backward) are two parallel branches; count the ride once.
        total_len = sum(way_len[w] for w, _ in present)
        ride_len = total_len - min(forward_len, backward_len)

        m = REF_RE.match(s.ref)
        ref_a, ref_b = (norm_number(m.group(1)), norm_number(m.group(2))) if m else (None, None)
        cand_a = touching.get(ref_a, []) if ref_a else []
        cand_b = touching.get(ref_b, []) if ref_b else []
        from_kp = cand_a[0] if cand_a else None
        to_kp = cand_b[0] if cand_b else None
        # "47-47": either a short connector between two OSM nodes of the *same* knooppunt
        # (both ends fall in one cluster) or a link between two distinct knooppunten numbered 47.
        intra = False
        if ref_a is not None and ref_a == ref_b:
            if len(cand_a) >= 2:
                from_kp, to_kp = cand_a[0], cand_a[1]
            elif cand_a:
                from_kp = to_kp = cand_a[0]
                intra = True
        if not intra:
            for kp in (from_kp, to_kp):
                if kp is not None:
                    kp_segments[kp].add(s.id)

        parts = components(node_lists) if node_lists else 0
        score = round(sum(LABELS[k][1] * v for k, v in label_len.items()) / total_len) if total_len else None

        flags = []
        if missing:
            flags.append("incomplete_members")  # usually crosses the extract border
        if not present:
            flags.append("no_geometry")
        if parts > 1:
            flags.append("gap")
        if ref_a is None:
            flags.append("unparsed_ref")
        else:
            if from_kp is None:
                flags.append("from_junction_not_on_route")
            if to_kp is None:
                flags.append("to_junction_not_on_route")
            if len(cand_a) > 1 and ref_a != ref_b or len(cand_b) > 1 and ref_a != ref_b:
                flags.append("ambiguous_junction")
        if total_len and surf_len["unknown"] / total_len > 0.2:
            flags.append("surface_unknown_gt20pct")
        if label_len["ferry"]:
            flags.append("ferry")

        share = lambda x: round(x / total_len, 3) if total_len else None
        row = {
            "segment_id": s.id,
            "ref": s.ref,
            "from_ref": ref_a,
            "to_ref": ref_b,
            "from_junction": from_kp,
            "to_junction": to_kp,
            "length_m": round(ride_len, 1),
            "safety_score": score,
            "worst_safety_tier": max((LABELS[k][0] for k in label_len if k != "ferry"), default=None),
            "intra_junction_connector": intra,
        }
        for k in TIER_ORDER:
            row[f"share_{k}"] = share(label_len[k])
        row.update({
            "share_paved": share(surf_len["paved"]),
            "share_assumed_paved": share(surf_len["assumed_paved"]),
            "share_semi_paved": share(surf_len["semi_paved"]),
            "share_unpaved": share(surf_len["unpaved"]),
            "share_surface_unknown": share(surf_len["unknown"]),
            "share_lit": share(lit_len),
            "share_fietsstraat": share(fiets_len),
            "share_mopeds_allowed": share(moped_len),
            "share_urban": share(urban_len),
            "share_lf": share(lf_len),
            "share_eurovelo": share(ev_len),
            "traffic_signals": count_intersections(signal_points),
            "max_shared_speed_kmh": max_shared_speed,
            "n_ways": len(present),
            "n_ways_missing": missing,
            "n_parts": parts,
            "quality_flags": flags,
            "survey_date": s.tags.get("survey:date"),
            "osm_version": s.version,
            "last_edit": last_edit,
        })
        seg_rows.append(row)
        seg_geom.append(linemerge(MultiLineString(lines)) if lines else None)

    # --- junctions (knooppunten) layer -------------------------------------
    members_of: dict[int, list[int]] = defaultdict(list)
    for n, kp in kp_of.items():
        members_of[kp].append(n)

    jn_rows, jn_geom = [], []
    for kp, nodes in members_of.items():
        js = [junctions[n] for n in nodes]
        tags = {}
        for j in js:
            for k, v in j["tags"].items():
                tags.setdefault(k, v)
        expected = max((int(j["tags"]["expected_rcn_route_relations"]) for j in js
                        if j["tags"].get("expected_rcn_route_relations", "").isdigit()), default=None)
        deg = len(kp_segments.get(kp, ()))
        flags = []
        if deg == 0:
            flags.append("unconnected")
        elif deg == 1:
            flags.append("dead_end")
        # expected_rcn_route_relations is tagged per OSM node. For a knooppunt mapped on
        # several nodes it counts that node's relations only, so we can only say a
        # multi-node knooppunt is short of links if it has fewer than any single node expects.
        if expected is not None and (deg != expected if len(nodes) == 1 else deg < expected):
            flags.append("degree_mismatch")
        lon = sum(j["lonlat"][0] for j in js) / len(js)
        lat = sum(j["lonlat"][1] for j in js) / len(js)
        jn_rows.append({
            "junction_id": kp,
            "number": norm_number(tags.get("rcn_ref")),
            "osm_node_ids": sorted(nodes),
            "name": tags.get("name"),
            "degree": deg,
            "expected_degree": expected,
            "segment_ids": sorted(kp_segments.get(kp, ())),
            "quality_flags": flags,
            "survey_date": tags.get("survey:date"),
            "last_edit": max(j["timestamp"] for j in js),
        })
        jn_geom.append(Point(lon, lat))

    crs = "EPSG:4326"
    layers = {
        "junctions": gpd.GeoDataFrame(jn_rows, geometry=jn_geom, crs=crs),
        "segments": gpd.GeoDataFrame(seg_rows, geometry=seg_geom, crs=crs),
        "ways": gpd.GeoDataFrame(way_rows, geometry=way_geom, crs=crs),
        "cells": cells,
    }
    for col in ("from_junction", "to_junction", "worst_safety_tier"):
        layers["segments"][col] = layers["segments"][col].astype("Int64")
    layers["junctions"]["expected_degree"] = layers["junctions"]["expected_degree"].astype("Int64")
    log(f"assembled ({time.time() - t0:.0f}s)")
    return layers


# ----------------------------------------------------------------------------
# Summary & output
# ----------------------------------------------------------------------------

def summarize(layers) -> dict:
    j, s, w = layers["junctions"], layers["segments"], layers["ways"]
    flag_counts = Counter(f for fl in s["quality_flags"] for f in fl)
    jflag_counts = Counter(f for fl in j["quality_flags"] for f in fl)

    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    linked = s.dropna(subset=["from_junction", "to_junction"])
    for a, b in zip(linked["from_junction"], linked["to_junction"]):
        parent[find(int(a))] = find(int(b))
    sizes = sorted(Counter(find(n) for n in list(parent)).values(), reverse=True)

    km_label = (w.groupby("safety_label")["length_m"].sum() / 1000).round(0)
    with_expected = j[j["expected_degree"].notna() & (j["osm_node_ids"].map(len) == 1)]
    return {
        "junctions": int(len(j)),
        "junction_osm_nodes": int(sum(len(x) for x in j["osm_node_ids"])),
        "segments": int(len(s)),
        "ways": int(len(w)),
        "network_km": round(float(s["length_m"].sum()) / 1000),
        "way_km_by_safety_label": {k: float(km_label.get(k, 0)) for k in TIER_ORDER},
        "urban_km": round(float((s["share_urban"].fillna(0) * s["length_m"]).sum()) / 1000),
        "lf_km": round(float((s["share_lf"].fillna(0) * s["length_m"]).sum()) / 1000),
        "eurovelo_km": round(float((s["share_eurovelo"].fillna(0) * s["length_m"]).sum()) / 1000),
        "traffic_signal_intersections": int(s["traffic_signals"].sum()),
        **({"cells": int(len(layers["cells"])),
            "cells_by_cyclability": {f"{lo}-{lo + 19}": int(((layers["cells"].cyclability >= lo)
                                                             & (layers["cells"].cyclability < lo + 20)).sum())
                                     for lo in range(0, 100, 20)}}
           if "cells" in layers else {}),
        "length_weighted_safety_score": round(float(
            (s["safety_score"].fillna(0) * s["length_m"]).sum() / max(1, s["length_m"].sum())), 1),
        "segment_flags": dict(flag_counts.most_common()),
        "junction_flags": dict(jflag_counts.most_common()),
        "single_node_junction_degree_matches_expected": f"{int((with_expected['degree'] == with_expected['expected_degree']).sum())}"
                                            f" / {len(with_expected)}",
        "graph_components": len(sizes),
        "largest_component_junctions": sizes[0] if sizes else 0,
        **({"junction_elevation_sources": {str(k): int(v) for k, v in
                                           j["elevation_source"].value_counts(dropna=False).items()},
            "elevation_range_m": [float(j["elevation_m"].min()), float(j["elevation_m"].max())],
            "segments_steeper_than_4pct": int((s["grade_pct"].abs() > 4).sum()),
            "elevation_attribution": "AHN DTM 0.5 m via PDOK (CC0)"}
           if "elevation_m" in j else {}),
        "osm_attribution": "© OpenStreetMap contributors, ODbL 1.0",
    }


def add_elevation(layers, cache_path: Path, log=print):
    """AHN elevation per junction, plus a straight-line climb proxy per segment.

    Only junction points are sampled: elevation_change_m is the height difference
    between the two end knooppunten, so a hill *between* two junctions is not seen.
    """
    from ahn_elevation import junction_elevations

    j, s = layers["junctions"], layers["segments"]
    points = {int(jid): (g.x, g.y) for jid, g in zip(j["junction_id"], j.geometry)}
    elev = junction_elevations(points, cache_path, log=log)
    j["elevation_m"] = [round(elev[int(i)][0], 2) if elev[int(i)][0] is not None else None
                        for i in j["junction_id"]]
    j["elevation_source"] = [elev[int(i)][1] for i in j["junction_id"]]

    z = {int(i): e for i, e in zip(j["junction_id"], j["elevation_m"]) if e is not None}
    import pandas as pd
    fz = [None if pd.isna(x) else z.get(int(x)) for x in s["from_junction"]]
    tz = [None if pd.isna(x) else z.get(int(x)) for x in s["to_junction"]]
    s["from_elevation_m"] = fz
    s["to_elevation_m"] = tz
    s["elevation_change_m"] = [round(b - a, 2) if a is not None and b is not None else None for a, b in zip(fz, tz)]
    s["grade_pct"] = [round(100 * d / L, 2) if d is not None and L > 0 else None
                      for d, L in zip(s["elevation_change_m"], s["length_m"])]
    for col in ("from_elevation_m", "to_elevation_m", "elevation_change_m", "grade_pct"):
        s[col] = s[col].astype("Float64")
    j["elevation_m"] = j["elevation_m"].astype("Float64")


def write(layers, out: Path, parquet: bool, geojson: bool, geojson_ways: bool = False):
    out.mkdir(parents=True, exist_ok=True)
    for name, gdf in layers.items():
        if parquet:
            gdf.to_parquet(out / f"{name}.parquet", index=False, compression="zstd")
        # The ways layer is ~160 MB as GeoJSON and slow to write; opt in separately.
        if geojson and (name != "ways" or geojson_ways):
            g = gdf.copy()
            for col in g.columns:  # GeoJSON has no list type in GDAL's writer; store as JSON text
                if col != "geometry" and g[col].map(lambda v: isinstance(v, list)).any():
                    g[col] = g[col].map(json.dumps)
            g.to_file(out / f"{name}.geojson", driver="GeoJSON")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pbf")
    ap.add_argument("-o", "--out", default="knooppunten_out")
    ap.add_argument("--geojson", action="store_true", help="also write junctions/segments as GeoJSON")
    ap.add_argument("--geojson-ways", action="store_true", help="also write the (large) ways layer as GeoJSON")
    ap.add_argument("--no-parquet", action="store_true", help="skip GeoParquet")
    ap.add_argument("--ahn", action="store_true",
                    help="add AHN 0.5 m elevation per junction (online, PDOK WCS; cached)")
    ap.add_argument("--elevation-cache", default=None,
                    help="cache file (default: <out>/elevation_cache.json)")
    a = ap.parse_args(argv)
    layers = build(a.pbf)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    if a.ahn:
        add_elevation(layers, Path(a.elevation_cache) if a.elevation_cache else out / "elevation_cache.json")
    write(layers, out, parquet=not a.no_parquet, geojson=a.geojson, geojson_ways=a.geojson_ways)
    write_preview_png(layers["cells"], out / "cyclability_preview.png")
    summary = summarize(layers)
    (out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
