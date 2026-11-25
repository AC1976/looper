# Fietsknooppunten extractor

Extracts the Dutch cycle node network (fietsknooppuntennetwerk) from OpenStreetMap
into GeoParquet and/or GeoJSON, with a safety classification and quality flags per segment.

Data © OpenStreetMap contributors, licensed under the ODbL 1.0. The output is a derivative
database: if you distribute it, it must be shared under the ODbL with attribution.

## Run

```
pip install -r requirements.txt
curl -L -o netherlands-latest.osm.pbf https://download.geofabrik.de/europe/netherlands-latest.osm.pbf
python3 extract_knooppunten.py netherlands-latest.osm.pbf -o ../data/nl --geojson
```

The whole country takes about 1.5 minutes and under 1 GB of RAM. Geofabrik refreshes the
extract daily, so re-running it on a schedule keeps the dataset current.

`--geojson` writes junctions and segments as GeoJSON; add `--geojson-ways` for the large ways layer.

## Junction elevation (AHN)

```
python3 extract_knooppunten.py netherlands-latest.osm.pbf -o ../data/nl --geojson --ahn
```

`--ahn` adds a height in metres NAP for every knooppunt, taken from AHN DTM 0.5 m
(bare ground) via the PDOK WCS. AHN is CC0. For each junction the extractor requests a
5 × 5 m window and uses the median of the valid pixels; if all are no-data (buildings,
water, bridges) it widens to 25 × 25 m. Junctions outside AHN coverage (just across the
border) fall back to Copernicus 90 m. The source is recorded per junction.

The first run takes about 30 minutes for the whole country (about 10,500 junctions at 6
parallel requests); results are cached in `elevation_cache.json`, so later runs only
fetch new or moved junctions.

New columns:

- junctions: `elevation_m`, `elevation_source` (`ahn_dtm_05m`, `ahn_dtm_05m_25m_window`, `copernicus_90m`)
- segments: `from_elevation_m`, `to_elevation_m`, `elevation_change_m` (to − from), `grade_pct`

Only the junction points are measured, so the segment climb is a straight-line proxy. A
hill between two knooppunten at similar heights isn't seen, and short steep climbs are
averaged out over the segment.

## Output layers

| File | One row per | Key columns |
|---|---|---|
| `junctions` | knooppunt (Point) | `junction_id`, `number`, `degree`, `expected_degree`, `segment_ids`, `osm_node_ids`, `quality_flags` |
| `segments` | signed route between two knooppunten (Line) | `ref` ("12-45"), `from_junction`, `to_junction`, `length_m`, `safety_score`, `share_*`, `share_urban`, `traffic_signals`, `share_lf`, `share_eurovelo`, `quality_flags` |
| `ways` | underlying OSM way (Line) | `safety_label`, `surface_class`, `maxspeed_kmh`, `mopeds`, `lit`, `urban_share`, `traffic_signal_nodes`, `on_lf`, `on_eurovelo`, `node_ids`, `segment_ids` |

`from_junction`/`to_junction` refer to `junction_id`, so `junctions` + `segments` form the
knooppunt graph directly. `ways.node_ids` gives the street-level graph for detailed routing.

## Safety classification (per way)

| Label | Tier | Score | Meaning |
|---|---|---|---|
| separated | 1 | 100 | own cycleway, designated bike path, or physically separated cycle track |
| bike_priority | 2 | 90 | fietsstraat, car-free road, agricultural track, path |
| quiet_shared | 3 | 70 | shared with cars at ≤30 km/h, residential or living street |
| rural_lane | 4 | 60 | minor rural road ≤60 km/h shared with cars (erftoegangsweg) |
| painted_lane | 4 | 55 | painted cycle lane on a road ≤50 km/h |
| shared_road | 5 | 25 | through road or >60 km/h without a bike facility |
| ferry | 0 | 70 | pont, depends on its timetable |

A segment's `safety_score` is the length-weighted average of its ways' scores;
`worst_safety_tier` is the least safe tier on it. The scores are a first proposal, to tune.

Untagged surfaces on normal road types and cycleways are reported as `assumed_paved`
(nearly always true in NL); `unknown` is kept for tracks and paths.

## Town and traffic lights

For "get out of town quickly", each way and segment says how much of it is in a built-up
area and how many traffic lights it has:

- `urban_share` (ways) / `share_urban` (segments): share of the length inside OSM
  `landuse=residential`, `commercial`, `retail` or `industrial`, each area widened by
  `URBAN_BUFFER_M` (25 m). Dutch landuse is often mapped per block with the streets left
  out, so without the widening a street through town would count as rural. Villages count
  as built-up too. Inner rings of multipolygons (courtyards) are ignored.
  Gaps inside towns (canals, small parks, squares) are then filled: the areas are grown by
  `URBAN_CLOSE_M` (200 m) and shrunk back, which closes openings narrower than about 400 m
  that have town on both sides, without moving a town's outer edge. This is done per 2 km
  tile (`URBAN_TILE_M`), each looking 400 m past its edges, so memory stays low; doing it
  for the whole country at once needed over 17 GB. Large parks and quays along open water
  (Vondelpark, the IJ waterfront) still count as rural; that's accepted to keep the data
  light.
- `traffic_signal_nodes` (ways): nodes tagged `highway=traffic_signals` or
  `crossing=traffic_signals`.
- `traffic_signals` (segments): traffic-light intersections on the route. Lights are often
  mapped at every stop line, so nodes within `SIGNAL_CLUSTER_M` (40 m) count as one.

The landuse areas are read like the routes: filtered passes over the file, then only the
nodes they need, so memory stays low. Shares are computed in the Dutch national grid
(EPSG:28992), in metres. `summary.json` adds `urban_km` and `traffic_signal_intersections`.

As of 2026-11-25: 11,470 km of the 37,715 km network is built-up (30 %), with 2,584
traffic-light intersections. City centres read 72–87 % built-up, polders 0 %. The town step
makes a full run take about 13 minutes instead of 2 (most of it filling gaps).

## Long-distance routes (LF, EuroVelo)

The curated long-distance cycle routes are read from the same file: the Dutch LF routes
(`route=bicycle`, `network=ncn`) and EuroVelo (`network=icn`). EuroVelo routes are often
super-relations made of sub-relations, which may be tagged differently or not at all, so
sub-relations are followed down a few levels.

- `on_lf`, `on_eurovelo` (ways): the way is a member of such a route.
- `share_lf`, `share_eurovelo` (segments): length share of the knooppunt segment on them.
- `summary.json` adds `lf_km` and `eurovelo_km` (knooppunt network km on them).

As of 2026-11-25: 138 LF and 43 EuroVelo relations; 4,032 km of the knooppunt network
(11 %) is on an LF route and 2,146 km (6 %) on EuroVelo. Within 15 km of Domburg it's 23 %
each (the North Sea Route, EuroVelo 12, along the coast); of Amsterdam 15 % LF and no
EuroVelo; of Utrecht 21 % and 10 %.

## Cyclability grid (`cells`)

Where is it good to ride? Above all: out in open space, away from town. The `cells` layer
(`cells.parquet`, `cells.geojson`) has one row per ~2 × 2 km cell with knooppunt routes:
0.018° latitude × 0.03° longitude (`CELL_DLAT`, `CELL_DLON`), a plain lat/lon grid. Cell
(i, j) covers latitudes [i·0.018°, (i+1)·0.018°) and longitudes [j·0.03°, (j+1)·0.03°).

| Column | Meaning |
|---|---|
| `i`, `j` | cell index |
| `built_up` | share of the cell's land in built-up areas (the same widened landuse as `share_urban`, without the gap filling) |
| `built_up_around` | mean `built_up` of the 8 cells around it |
| `network_km` | km of knooppunt routes in the cell |
| `quality` | route quality 0–1: safety score × surface (paved 1, semi-paved or unknown 0.8, unpaved 0.5), length-weighted |
| `traffic_signals` | traffic-light intersections on those routes |
| `scenic` | share of the cell that's water, woods or forest, heath, dunes, sand, beach, wetland, scrub, grassland or nature reserve, or within 500 m of the coastline |
| `cyclability` | 0–100, see below |

`cyclability = 100 × openness³ × (0.6 + 0.4 × quality) × lights × scenery`, where
`openness = 1 − (½ built_up + ½ built_up_around)`, `lights = max(0.5, 1 − 0.15 × traffic_signals)`
and `scenery = 0.8 + 0.2 × min(1, 2 × scenic)`: a cell at least half scenic gets full marks,
plain farmland 20 % less, so openness still dominates.
Cubing openness makes open space dominate: 80 % open keeps half the score, 50 % open an
eighth, so a town's fringe scores low too. How much network a cell has is deliberately
left out (it's in `network_km`): one good route clipping a corner of open country is still
good riding, and including it made open country look patchy.

`cyclability_preview.png` maps the score (green good, red poor, white no routes).
`summary.json` adds `cells` and `cells_by_cyclability`.

Scenery comes from about 1.1 million OSM areas with 23.8 million nodes, ten times the
built-up land. They're read into compact arrays (way node lists in one flat array, then one
filtered node pass whose nodes line up with the sorted ids needed) instead of Python
objects, which would need several GB. Some areas are drawn crossing themselves; a cell
whose shapes can't be merged is repaired with `make_valid` and merged again. Reading the
scenery adds about 6 minutes to a run, rating the cells about 5; a full run now takes
about 18 minutes.

As of 2026-11-25: 8,942 cells; by score 0–19: 988, 20–39: 1,312, 40–59: 3,089,
60–79: 2,664, 80–99: 859. Mean scenic share 27 %; 1,688 cells are at least half scenic.
The Veluwe (85 % scenic) keeps a score around 83, the Kennemerduinen dunes and Utrechtse
Heuvelrug keep theirs, while open polder without scenery drops (Flevoland around Dronten
76 → 64). Around Amsterdam, Waterland (north-east) and the Groene Hart (south, from
Vinkeveen on) score high, Amstelveen, Haarlemmermeer and Zaandam low.

## Quality flags

Segments can be flagged as follows:

- `incomplete_members`: some of its ways are missing from the extract, usually because it crosses the national border.
- `gap`: the ways don't join up.
- `from_junction_not_on_route` / `to_junction_not_on_route`: an end knooppunt's number isn't found on the segment's ways.
- `ambiguous_junction`: more than one knooppunt with that number lies on the route.
- `surface_unknown_gt20pct`: surface is truly unknown on more than 20% of the length.
- `ferry`: includes a ferry.
- `unparsed_ref`: the ref isn't in the "a-b" form.

Junctions can be flagged as follows:

- `unconnected`: no segments end there.
- `dead_end`: only one segment ends there.
- `degree_mismatch`: the number of linked segments doesn't match the mapper-tagged `expected_rcn_route_relations`.

## Modelling notes

- **Multi-node knooppunten:** one knooppunt is often mapped on several OSM nodes, for example on both sides of a road. Nodes with the same number within 200 m are merged into one junction. Short "47-47" relations between such nodes are marked `intra_junction_connector` and don't count towards the degree.
- **One-way splits:** routes split into forward and backward branches are counted once in `length_m`.
- **Unique IDs:** knooppunt numbers are only unique within a region, so segments are linked to the junction *nodes* on their ways, not matched by number alone.
