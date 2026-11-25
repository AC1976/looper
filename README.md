# looper — bike loops on the Dutch knooppunten network

Plans cycling **loops** (start = finish) around the rider's position, on the signposted
Dutch *fietsknooppuntennetwerk*, optimised for traffic, surface, climbs, **wind over the
whole ride** and **rain**. Results come back as knooppunt sequences you can follow on the
signs (`31 → 28 → 42 → … → 31`), plus GeoJSON and GPX.

Two parts:

| Part | Language | What it does |
|---|---|---|
| `extractor/` | Python | Builds the network dataset from OpenStreetMap (+ AHN heights). Run occasionally. |
| `Sources/`, `Tests/` | Swift 6 package `LoopRouter` | Loads the dataset and plans loops. Library + `loop-router` runner (parameters set in `main.swift`). |
| `LooperKit/` | Swift 6 package `LooperKit` | Shared app layer for the iOS and watchOS apps: state, preferences, planning. No views. |

---

## Quick start

The repository includes a ready-made `data/nl/network.bin` (and the AHN height cache), so
you can plan loops straight away: skip to "Plan loops" and leave out `pack-network`. The
large GeoJSON/Parquet layers (about 110 MB) aren't in git; the extractor rebuilds them.

```bash
# Build the dataset (once; refresh e.g. weekly)
cd extractor
pip install -r requirements.txt
curl -L -o netherlands-latest.osm.pbf https://download.geofabrik.de/europe/netherlands-latest.osm.pbf
python3 extract_knooppunten.py netherlands-latest.osm.pbf -o ../data/nl --geojson --ahn

# Plan loops
cd ..
swift build -c release
swift run -c release pack-network    # GeoJSON → data/nl/network.bin (after every extractor run)
swift run -c release loop-router     # ride parameters are set in Sources/LoopRouterRunner/main.swift
swift test
cd LooperKit && swift test           # the app layer
```

Requirements: Swift 6.0+ (developed on 6.4.3; builds on macOS/iOS and Linux), Python 3.10+.
Only the weather (Open-Meteo, free, no key) is fetched at run time; everything else is local.

---

## Repository layout

```
looper/
├── Package.swift
├── README.md                      ← this file
├── data/nl/                       ← dataset produced by the extractor
│   ├── network.bin                  compact network for the router ← read by LoopRouter
│   ├── junctions.geojson/.parquet   knooppunten (points)          ← input to pack-network
│   ├── segments.geojson/.parquet    routes between knooppunten    ← input to pack-network
│   ├── ways.parquet                 underlying OSM ways (dataset only)
│   ├── cells.geojson/.parquet       cyclability grid (~2 km cells) ← input to pack-network
│   ├── cyclability_preview.png      map of the grid
│   ├── summary.json                 counts, km per safety label, quality flags
│   └── elevation_cache.json         AHN lookups (makes re-runs fast)
├── extractor/
│   ├── extract_knooppunten.py     OSM .pbf → junctions / segments / ways
│   ├── ahn_elevation.py           AHN 0.5 m junction heights via PDOK WCS
│   └── README.md                  dataset schema, safety tiers, quality flags
├── Sources/LoopRouter/            the library (see "Code map")
├── Sources/LoopRouterRunner/main.swift   ride parameters in code; prints and exports loops
├── Sources/PackNetwork/main.swift        GeoJSON → network.bin
├── Tests/LoopRouterTests/
└── LooperKit/                     ← shared app layer (own package, depends on LoopRouter)
    ├── Sources/LooperKit/
    │   ├── RidePreferences.swift    rider's choices, limits, → RideRequest; preference stores
    │   ├── RoutePlanning.swift      planning protocol; LocalRoutePlanner (loads network.bin once)
    │   ├── PlannerModel.swift       @Observable state for the views
    │   └── PreviewData.swift        sample plan and planner for SwiftUI previews and tests
    └── Tests/LooperKitTests/
```

---

## The dataset (extractor)

Full schema and rules are in `extractor/README.md`. In short:

- **junctions**: one row per knooppunt. Several OSM nodes with the same number within
  200 m are merged into one junction. Columns include `junction_id`, `number`, `degree`,
  `elevation_m` (AHN, m NAP) and `quality_flags`.
- **segments**: one row per signed route `a-b` between two junctions, with `from_junction`,
  `to_junction`, `length_m`, `share_*` (length shares per safety label and surface),
  `safety_score`, elevation change, and `quality_flags`.
- **ways**: the OSM ways each segment is built from, with per-way `safety_label`. This
  layer is part of the "safe bike paths" dataset; LoopRouter doesn't read it.

Safety labels per way, safest first: `separated`, `bike_priority`, `quiet_shared`,
`rural_lane`, `painted_lane`, `shared_road`, and `ferry`.

`pack-network` reads `junctions.geojson` and `segments.geojson` and writes `network.bin`,
which is what the router loads. Only these fields are used:
`junction_id`, `number`, `elevation_m`; `segment_id`, `from_junction`, `to_junction`,
`length_m`, `intra_junction_connector`, and the `share_separated`, `share_bike_priority`,
`share_quiet_shared`, `share_rural_lane`, `share_painted_lane`, `share_shared_road`,
`share_ferry`, `share_semi_paved`, `share_unpaved`, `share_surface_unknown` and `share_urban`
columns, and `traffic_signals`. A dataset from before `share_urban` and `traffic_signals`
existed still loads; both then read as 0.

Numbers as of 2026-11-25: 10,488 knooppunten, 17,019 segments (16,181 after dropping
connectors inside a junction), 37,715 km, of which 11,470 km built-up, with 2,584
traffic-light intersections; 4,032 km on LF routes and 2,146 km on EuroVelo.

### `network.bin`

`network.bin` holds the network after the router's own clean-up of the GeoJSON (connectors
dropped, segment paths oriented, `lengthScale` computed), as plain little-endian numbers.
Each segment has two shapes:

- **routing points**, about 150 m apart: these become the graph edges, so wind is judged on
  the real riding direction without making the graph large;
- **display shape**: the full OpenStreetMap shape simplified to within 3 m
  (`KnooppuntNetwork.displayTolerance`), for maps, GPX and GeoJSON. It passes through every
  routing point, so each graph edge has its own exact piece of it.

The file stores the display shape once, plus the position of each routing point in it. The exact layout is documented in `Providers/NetworkBinary.swift`.
Loading it gives the same network, and so the same loops, as loading the GeoJSON.
`pack-network` checks that before it finishes.

| | GeoJSON | `network.bin` |
|---|---|---|
| Size | 59.7 MB | 9.9 MB (5.3 MB without the display shape) |
| Load time (release build, Windows dev laptop) | 9.2 s | ~0.01–0.02 s |

Re-run `pack-network` after every extractor run; the router doesn't notice a stale file.
If the format changes, bump `binaryVersion`: older files are then refused with a clear error.
The current version is 6 (version 1 had no display shape, version 2 no town share or
traffic lights, version 3 no cyclability grid, version 4 no LF/EuroVelo shares, version 5
no scenic share per cell). The grid is read from `cells.geojson` when
it's there; a dataset without it loads with an empty grid.

---

## How a loop is planned

`LoopPlanner.plan(request)`:

1. **Cut the network.** Take the segments within `searchRadius = max(3 km, D/π × 1.15)`
   of the start and build a graph (`KnooppuntNetwork.graphBuilder`). Junctions become
   nodes, and each segment becomes a chain of points about 150 m apart, so wind is judged
   on the real riding direction. Heights between junctions are interpolated linearly.
2. **Fetch weather over the ride area.** 15 forecast points (start, a ring at ½R, a ring
   at R), one Open-Meteo request, with 15-minute data for the first 8 h and hourly after
   that (`WeatherField`).
3. **Generate loops** (`LoopGenerator`):
   - Start at the nearest knooppunt (≤ 5 km); the access ride comes off the target distance.
   - Create about 18 candidate shapes: polygons with 3–6 corners. Their direction depends
     on the wind strategy, using the forecast for the *whole expected ride*. `first`
     heads into the first-half wind. `min` makes loops stretched 3:1 across the
     ride-mean wind, and also tries "out with the first-half wind, home with the
     second-half wind" for a wind that turns.
   - Snap the corners to junctions and route corner to corner with A* (`Pathfinder`),
     penalising segments already used. Each edge is priced **where and when** the rider
     gets there, using the distance and climbing already ridden.
   - Remove out-and-back spurs, and rescale the shape up to 3 times to hit the distance.
   - Score each candidate (`RouteAnalyzer`) and pick the best *distinct* loops. Score ties
     are broken by candidate id, so the same seed always gives the same loops.
4. **Leave town quickly** (`leaveTownQuickly`, on by default in the app). When the start
   is in town (≥ 25 % of the network within 2 km is built-up):
   - each shape is turned towards the least built-up direction nearby (within 90° with the
     wind ignored, 45° for `first`, 30° for `min`, so the wind strategy still counts);
   - corners snap to a junction outside town when there's one close by;
   - every other candidate is a **lollipop**: the cheapest way out to a *gateway* junction
     with countryside around it (within 30 % of the ride, at most 12 km), then the loop
     from there, and from its last corner home like any other leg. Re-riding built-up
     segments carries no reuse penalty and doesn't count as overlap or against loop
     variety; re-riding countryside still does. So the way home repeats the way out only
     in town (or where there's no other good way): a teardrop, not a lollipop with a long
     stick.
   Routing and scoring then price town metres and traffic lights (below).

   **Area-first** (with a cyclability grid; `RidingAreas.swift`): decide *where* to ride
   before drawing a loop, so a ride that heads south stays south instead of cutting back
   through town to the other side.
   - Options: 24 directions × 4 loop shares (100, 80, 65 or 50 % of the distance in the
     loop; the rest is the way there and back). Each option is an area (a disc the loop
     will cover) at the distance the way out allows.
   - Each option is judged on the **real way in**: the cheapest junction inside the area,
     found on one shortest-path tree from the start (town-aware costs). Score =
     (loop km × area cyclability + 2 × way-in km × the way in's cyclability) ÷ distance,
     × enough routes in the area for the loop (open water has none) × the wind: `first`
     favours heading out into the first-half wind (out and back along it is headwind out,
     tailwind home), `min` favours going across it.
   - The best 4 areas at least 50° apart each get 4 loop variants (3–6 corners), started
     at the way in's end and heading on to the area's centre; the route rides the way in
     first and routes home from the loop's last corner (as above), so it only repeats the
     way in through town.

   Before the way home was routed, it mirrored the way in: from Domburg (120 km, least
   headwind) 14–22 km of each loop was ridden twice (23–36 %); now 0–0.6 km. From Utrecht
   (70 km) the 1–5 km still ridden twice is almost all the way out of town (0–0.6 km in
   the country). The rounder shape can cost some wind: Domburg's best loop now loses
   63 min to the wind against 33 min for the best old one, for more open ground (73 against 66).
   - These join the other candidates; the scoring decides.
5. **Rain advice.** If the rider minds rain and the best loop would get ≥ 0.3 mm, try
   later departures (every 15 min, up to 6 h) and suggest the earliest with ≤ ⅓ of the rain.

### Cost of an edge (routing) and score of a loop (ranking)

```
edge cost (metres-equivalent) = length × multiplier  +  cruisingSpeed × (wind effort s + rain effort s + traffic-light s)
```

- **multiplier**: 1, plus traffic (`trafficAvoidance × 3 × congestion`), minus a bonus for
  separated paths, plus surface penalties (worse when wet), a ferry penalty, climbing
  (per `climbPreference`) and steep descents (comfort limit lowered when wet), and with
  `leaveTownQuickly` `1.5 × urban share` (`CostModel.townPenalty`: 1 km through town costs
  as much as 2.5 km in the country) plus, with a grid, `0.8 × (1 − cyclability)` of the
  edge's cell (`CostModel.closedSpacePenalty`). Clamped at 0.35 × length so the A*
  heuristic stays admissible.
- **Long-distance routes** (LF, EuroVelo) outside town: `0.2 × factor × share × (1 − urban share)`
  off the multiplier (`CostModel.longDistanceBonus`), where the factor comes from
  `RideRequest.longDistanceRoutes`: `ignore` 0, `prefer` 1 (the default), `follow` 2.
  No bonus in town, where many LF routes start from the city centre.
- **Traffic lights**, with `leaveTownQuickly`: 40 effort seconds each
  (`CostModel.trafficLightSeconds`: waiting, stopping and starting).
- **Wind and rain** are both in **effort seconds** (`WeatherCost`). The routing and the
  scoring use the same function, so they always agree:
  - *Wind* is real extra time. `RiderModel` (85 kg, CdA 0.40, Crr 0.005) holds the power
    that gives the cruising speed in still air, about 111 W at 25 km/h; at that power a
    2 m/s headwind gives 20.9 km/h and a 5 m/s headwind 15.6 km/h. The wind strategy then
    weights the time: `min` counts all headwind time and 20 % of tailwind gains; `first`
    counts headwind ×0.4 early to ×1.6 late and tailwind most on the way home.
  - *Rain* is discomfort. A smooth, saturating curve gives the effort seconds per second
    ridden: about 0.2 at 0.1 mm/h, 1.3 at 1 mm/h and 2.1 at 4 mm/h. It's scaled by the
    rain probability and by `RainSensitivity` (ignore 0, low 0.4, normal 1, high 2.5).
  - Calibration, pinned in the tests: at `normal`, 0.5 mm of rain (39 effort-min)
    outweighs +2 m/s of headwind over 70 km (33 min); `low` reverses that.
- **Loop score** (lower is better): distance deviation, traffic, climb, wind, rain,
  surface, descents, overlap and town. Wind and rain are each `3 × effort / still-air ride time`,
  so 10 % extra effort ≈ 0.3 points, the same as missing the distance by 10 %. Town (with
  `leaveTownQuickly`) is the traffic lights as effort seconds the same way, plus, with a
  cyclability grid, `3 × (1 − mean cyclability)` + `1.5 × urban share` (riding through
  cells of 50 on average ≈ 1.5 points; the town share counts half because it also counts
  every village street, which the grid weighs by how built-up the area really is), or
  without a grid `3 × urban share`. A reward of up to 1 point
  (`RouteAnalyzer.longDistanceReward`) for the share ridden on LF/EuroVelo outside town:
  without it the ranking ignored those routes and the routing bonus alone changed little.

Effect of the LF/EuroVelo bonus and reward (same settings, before → after): from Domburg
(120 km, least headwind) the best loop now follows the coast, 58 % on LF/EuroVelo, and
loses 37 min to the wind instead of 63 (open 64 instead of 73). Around Amsterdam, Utrecht
and Amersfoort it's roughly neutral (open within ±5); with the reward counted in town too,
Utrecht's loops were pulled back into the centre (open 35–44), hence outside town only.

The pull is a rider setting, like wind and rain: `longDistanceRoutes` = `.ignore`,
`.prefer` (default) or `.follow`, scaling both the routing bonus and the score reward. From
Domburg (120 km, least headwind) `.ignore` gives a best loop 21 % on LF/EuroVelo and
`.prefer` 67–70 %.

`.follow` also builds the candidates around those routes (`LongDistanceMap.swift`): loop
corners snap to a junction on a long-distance route outside town when there's one within
35 % of the loop radius, and riding areas score up to 1.5 times higher the more
long-distance km outside town they hold (`LoopGenerator.followAreaBonus`). Best loop's LF
share, `.prefer` → `.follow`: Domburg (120 km) 58 → 63 %, Utrecht (70 km) 56 → 60 %,
Amsterdam centre (130 km) 37 → 41 %, with open space about the same or better (Domburg's
second loop: open 74, 13 % in town) and fewer traffic lights from Utrecht (5–6 against
6–10). Without the corner and area steering, `.follow` gave the same loops as `.prefer`
from Domburg and Amsterdam.

Effect of `leaveTownQuickly` with area-first on real runs (headwind first, 3 loops each;
"open" is the mean cyclability ridden through):

| Start | Without | With |
|---|---|---|
| Amsterdam Oud-Zuid, 100 km | open 31–38, 39–42 % in town, 15–19 lights | open 40–51, 30–34 %, 6–15 lights |
| Utrecht, 70 km | open 30–35, 46–54 %, 17–37 lights | open 44–48, 26–28 %, 0–4 lights |
| Amersfoort, 50 km | open 26–47, 35–63 %, 2–10 lights | open 48–52, 22–28 %, 2–7 lights |
| Ommen (countryside), 70 km | open 62–75, 20–26 % | open 74–78, 11–21 % |

From Oud-Zuid the two best loops commit south, about 23 km into the Groene Hart. Planning
a 100 km ride takes about 2 s instead of 1.1 s (more candidates). Before area-first,
Amsterdam gained nothing: its network is 33–51 % built-up in every direction within a
loop's reach, so steering a loop *around* the start had nothing better to steer to.

Scenery in the cyclability score (water, woods, heath, dunes, coast; see the extractor
README) mostly decides which of the near-equal candidates make the top three. Mean scenic
share along the best loop, without → with it: Domburg 43 → 43 %, Amsterdam Oud-Zuid 20 →
30 %, Utrecht 37 → 37 %, Amersfoort 16 → 45 %; one more scenic loop joins the top three
from Domburg (57 %) and Utrecht (41 %). Distance, town share, lights and wind stay about
the same. To make scenery count more, raise its weight in `cyclability` in the extractor
(now 0.2) and re-run it.

Loops within the distance tolerance always rank ahead of loops outside it, so less time
in town (or less wind) never buys a ride clearly shorter or longer than asked.

---

## Code map (`Sources/LoopRouter`)

| File | Contents |
|---|---|
| `RideRequest.swift` | `RideRequest` (everything the rider asks for), `ClimbPreference`, `WindStrategy`, `RainSensitivity`, `LongDistanceRoutes`, ride clock |
| `LoopPlanner.swift` | Entry point: network + weather → `LoopPlan` (routes, weather during ride, `RainAdvice`, warnings) |
| `LoopGenerator.swift` | Candidate shapes, corner snapping, leg routing, spur removal, diversity selection |
| `Pathfinder.swift` | A* with reuse penalty; passes distance/climb so far to the cost function |
| `CostModel.swift` | Per-edge cost (non-weather multiplier + weather effort) |
| `WeatherCost.swift` | `RiderModel` physics, wind and rain effort in one unit |
| `TownMap.swift` | Where the built-up areas are: steering loop shapes, countryside checks for gateways |
| `CyclabilityGrid.swift` | The extractor's ~2 km cyclability cells: lookup by coordinate; each graph edge gets its cell's value |
| `LongDistanceMap.swift` | For `follow`: which junctions are on long-distance routes outside town, and their km per grid cell |
| `RidingAreas.swift` | Area-first planning: scoring riding areas, picking them in different directions |
| `WeatherField.swift` | Multi-point forecast, inverse-distance blending, station layout |
| `Conditions.swift` | `WeatherConditions`, `WeatherForecast` (time interpolation, wind as a vector), traffic model |
| `LoopRoute.swift` | `LoopRoute`, `RouteMetrics`, `ScoreBreakdown`, `RouteAnalyzer` |
| `RoadGraph.swift` | Graph, builder, spatial index |
| `Providers/KnooppuntNetwork.swift` | GeoJSON loading, segment orientation, routing points and display shape, `SegmentProfile` |
| `Providers/NetworkBinary.swift` | `network.bin` writer and reader |
| `Providers/Weather.swift` | `WeatherProvider` protocol, Open-Meteo client (15-min + hourly merge), HTTP retry |
| `Export.swift` | GeoJSON FeatureCollection and GPX (full shape; GPX has a waypoint per knooppunt) |
| `Geo.swift` | Haversine, bearing, destination point; `SplitMix64` seeded RNG |

### Using the library

```swift
import LoopRouter

let network = try KnooppuntNetwork.load(binary: URL(fileURLWithPath: "data/nl/network.bin")) // load once
let planner = LoopPlanner(network: network)

let request = RideRequest(start: Coordinate(latitude: 52.3731, longitude: 4.8926),
                          distanceKm: 70, loopCount: 3,
                          climbPreference: .neutral,
                          windStrategy: .minimizeHeadwind,
                          rainSensitivity: .normal)
let plan = try await planner.plan(request)
for loop in plan.routes { print(loop.knooppunten.joined(separator: " → "), loop.metrics.distance) }
if let advice = plan.rainAdvice { print("Leave at", advice.suggestedDeparture) }
let geojson = try plan.geoJSON()
```

Extension points: `WeatherProvider` (another forecast source) and `TrafficModel` (live
traffic). Both are protocols passed to `LoopPlanner`.

### Using it from an app (SwiftUI, Apple Watch)

`LoopRouter` holds all routing logic and nothing else: it imports only Foundation, prints
nothing and has no UI. A SwiftUI app sits on top of it:

- Create the app in Xcode (on a Mac) with an iOS target (iPhone + iPad) and a watchOS
  target, and add `LooperKit/` as a **local Swift package**; link the `LooperKit` library to
  both targets (it brings `LoopRouter` with it). Both packages declare macOS 14, iOS 17 and
  watchOS 10.
- Write the views per platform: one adaptive set for iPhone and iPad (`NavigationSplitView`),
  a smaller glanceable set for the Watch. Share state, not screens.
- Ship `data/nl/network.bin` in the app bundle (or sync it from the iPhone).

`LooperKit` gives the views one object to work with:

```swift
import LooperKit

let file = Bundle.main.url(forResource: "network", withExtension: "bin")!
let model = PlannerModel(planner: LocalRoutePlanner(networkFile: file))  // keep for the app's lifetime

model.start = Coordinate(latitude: 52.3731, longitude: 4.8926)  // from Core Location
model.preferences.wind = .headwindFirst                           // saved automatically
model.startPlanning()                                             // from a button
// views read model.phase (.idle / .planning / .planned(plan) / .failed(message)),
// model.routes and model.selectedRoute
```

- `RidePreferences` is what the rider picks (distance, loops, climb, traffic, wind, rain,
  unpaved, speed), with limits; it's saved through a `PreferencesStore` (`UserDefaults` by
  default) and turned into a `RideRequest` per ride.
- `RoutePlanning` is the planning protocol. `LocalRoutePlanner` plans on the device and loads
  `network.bin` once (call `preload()` at launch to do that early). A Watch could later use
  an implementation that asks the iPhone instead; the views don't change.
- `PlannerModel` runs one plan at a time: a newer request replaces an older one, and a late
  result from the older one is dropped.
- `PreviewData.plan` and `PreviewRoutePlanner` give SwiftUI previews a plan without the
  network file or internet: `PlannerModel(planner: PreviewRoutePlanner(), store: InMemoryPreferencesStore())`.
- Still to add on a Mac, where Apple's frameworks are available: Core Location for `start`,
  SwiftData for saved loops, App Intents, and WatchConnectivity.
- If the Xcode project moves `LooperKit/` elsewhere, update `.package(path: "..")` in
  `LooperKit/Package.swift` to point at this folder.
- `RideRequest`, `LoopPlan`, `LoopRoute` and `RainAdvice` are `Codable`, so they can be saved
  (for example in SwiftData) or sent between iPhone and Watch. `edgeIndices` and `segments`
  only mean something inside the graph the route was planned on.
- For a map (MapKit for SwiftUI on iPhone, iPad and Watch):
  - draw `route.displayCoordinates` as a `MapPolyline`: the full shape, accurate to a few
    metres. `route.coordinates` are the ~150 m routing points, too coarse at street level;
  - put a badge per knooppunt from `route.junctions`: each has its `number`, `coordinate`,
    `junctionID` (numbers repeat between regions) and `distanceFromStart`, which also gives
    "next knooppunt in 1.2 km" during a ride;
  - Apple's map doesn't show the knooppunt network, so the line and badges are the app's own
    layer; show "© OpenStreetMap contributors" wherever they appear.
- Keep app code (views, intents, persistence) in the Xcode project, not in this package, so
  `LoopRouter` keeps building on Linux and its tests stay fast.

---

## Runner (`loop-router`)

There are no command-line options. The ride parameters are a `RideRequest` filled in at the
top of `Sources/LoopRouterRunner/main.swift` (later they will come from App Intents), along
with the network file (`data/nl/network.bin`), the GeoJSON output file (`loops.geojson`) and whether to
write `loop-<n>.gpx` files. Edit them and run `swift run -c release loop-router`.

### Ride options

Everything a rider can ask for, as `RideRequest` parameters (the runner's `main.swift` and
the app use the same names; the app's `RidePreferences` in LooperKit has the same choices,
with its own defaults and limits).

| Option | Values | Library default | App default (`RidePreferences`) |
|---|---|---|---|
| `start` | coordinate where the rider is | (required) | from Core Location |
| `distanceKm` | loop length in km | (required) | 40 (10–200) |
| `loopCount` | number of different loops | 3 | 3 (1–5) |
| `windStrategy` | `.headwindFirst` headwind out, tailwind home · `.minimizeHeadwind` least headwind over the whole ride · `.ignore` | `.headwindFirst` | `.headwindFirst` |
| `rainSensitivity` | `.ignore` rain only affects surfaces and descents · `.low` a bit of rain is fine · `.normal` prefer to avoid rain · `.high` must stay dry. Anything but `.ignore` also suggests a drier departure when there is one | `.ignore` | `.normal` |
| `longDistanceRoutes` | LF and EuroVelo routes outside town: `.ignore` like any other route · `.prefer` worth a small detour · `.follow` build the loops around them | `.prefer` | `.prefer` |
| `leaveTownQuickly` | `true`: short way out of town, head for open, scenic country (area-first), same way through town fine · `false` | `false` | `true` |
| `weatherAware` | `false` ignores wind and rain altogether | `true` | `true` (`useWeather`) |
| `climbPreference` | `.avoid` · `.neutral` · `.seek` · `.targetAscent(meters:)` | `.neutral` | `.neutral` |
| `trafficAvoidance` | 0 (don't care) … 1 (strongly prefer quiet roads and bike paths) | 0.7 | 0.7 |
| `allowUnpaved` | `true` allows gravel and unpaved paths | `false` | `false` |
| `departure` | start time; the forecast is read for when and where the rider gets to each stretch | now | now |
| `cruisingSpeedKmh` | flat-road speed, for ride time and weather timing | 25 | 25 (12–40) |
| `maxComfortableDescentGrade` | steeper descents cost extra (less when wet) | 0.12 | – |
| `distanceTolerance` | how far from `distanceKm` a loop may be; loops within it always rank first | 0.10 | – |
| `seed` | same seed, same loops | random | random |

Wind, rain and long-distance routes are the three "how do I want to ride" choices; each
has an off setting, and they're weighed against each other in one score (see "Cost of an
edge" above).

Output table columns:

- `headX`: mean headwind (m/s).
- `>3m/s`: share of distance with a headwind above 3 m/s.
- `windΔ`: minutes lost (+) or gained (−) to the wind.
- `town`: share of distance in built-up areas (towns and villages).
- `lights`: expected number of traffic-light intersections.
- `open`: mean cyclability (0–100) of the ground ridden through; high = out in open space.
- `LF/EV`: share of the loop on an LF route / on a EuroVelo route.
- `out/back km`: km ridden before the loop first leaves town (a stretch of ≥ 1 km mostly
  outside built-up areas), and km before the end that it's back in town.
- `rain mm`: expected rain ridden through.
- `effort wind/rain`: wind and rain in effort minutes, as weighed by `windStrategy` and `rainSensitivity`.

---

## Tests

`swift test`: 70 tests. They run on a synthetic 7 × 7 knooppunt grid, built in the
extractor's GeoJSON format with a busy middle row and a 60 m hill (`KnooppuntFixture`
in `KnooppuntTests.swift`).

| File | Covers |
|---|---|
| `KnooppuntTests.swift` | Loading/orientation, junction sequences, distances, preferences (climb, traffic), reproducibility, junction-height climbs, spur removal |
| `WindTests.swift` | Forecast interpolation (direction the short way), coverage, wind strategies, **wind turning mid-ride** |
| `RainTests.swift` | Field blending, station layout, steering to the dry side, departure advice, Open-Meteo multi-location + 15-min parsing |
| `WeatherCostTests.swift` | Rider physics, **pinned wind-vs-rain trade-off** per sensitivity, smooth rain curve, probability scaling |
| `LoopRouterTests.swift` | Geo helpers, headwind sign, Open-Meteo parsing, `RideRequest`/`LoopPlan` JSON round trip |
| `NetworkBinaryTests.swift` | `network.bin` round trip (same network, same loops), missing heights, wrong or truncated files |
| `DisplayGeometryTests.swift` | Display shape within 3 m of the road and through every routing point; loops' knooppunt positions and distances; GPX waypoints |
| `UrbanTests.swift` | Town share and traffic lights from GeoJSON to `network.bin` to loop metrics; older GeoJSON without them |
| `LongDistanceRouteTests.swift` | LF/EuroVelo shares loading and through `network.bin`, loop metrics, routing bonus and score reward only outside town, the `ignore`/`prefer`/`follow` setting scaling both, where `follow` finds the routes outside town |
| `RidingAreaTests.swift` | Edges get their cell's cyclability, best area on the open side and areas in different directions, closed-space cost only when asked, loops ride in open space, the way home doesn't repeat the way out's countryside |
| `CyclabilityGridTests.swift` | Cell lookup by coordinate, loading `cells.geojson` (with and without `scenic`), exact round trip through `network.bin` |
| `LeaveTownTests.swift` | Town and light costs only when asked, less time in town, lollipop starts with the way out and ends at the start, reverse edges, town exit/return distances, shared way out not counting against variety |

`cd LooperKit && swift test`: 12 tests for preferences (limits, request, `UserDefaults`
round trip), `PlannerModel` (selection, errors, saving, latest request wins, cancelling) and
`LocalRoutePlanner` (a real 40 km Amsterdam plan on `network.bin`, skipped when the file is
missing).

On Windows, if LooperKit's tests crash silently after a change to `LoopRouter`, delete
`LooperKit/.build` and run them again: the incremental build can miss changes in the
package one folder up.

When changing weights or the cost model, check real runs as well as the tests. Reference
points: Utrecht centre (`52.0907, 5.1214`), Valkenburg (`50.8573, 5.8302`, hilly) and
Amsterdam (`52.3731, 4.8926`, 70 km).

---

## Design decisions (and why)

- **Knooppunten instead of the raw street network.** The network is curated, signposted
  and much smaller to route on; the knooppunt sequence is a feature in itself. Live
  Overpass and MapKit were dropped: MapKit gives routes, not a network, and the public
  Overpass servers are rate-limited.
- **GeoJSON from the extractor, `network.bin` for the router.** GeoJSON is readable with
  Foundation alone (no Parquet dependency in Swift), but it's large and slow to parse, which
  matters on an Apple Watch. `pack-network` turns it into a small binary file with only what
  the router uses. The format is defined once, in Swift, so writer and reader can't drift
  apart. GeoParquet is kept for the dataset itself.
- **AHN heights at junctions only.** Accurate (0.5 m, CC0) and cheap. The climb between
  junctions is a straight-line proxy: hills between two junctions at similar heights are
  missed, and short steep climbs are averaged out. Expect a real 40 km Valkenburg loop
  to climb about 2× what LoopRouter reports.
- **Weather at the time and place of each edge.** Wind can turn and showers move. The
  forecast is interpolated in time (wind as a vector) and across 15 points in space.
- **One unit for wind and rain.** Avoids hand-picked weights that accidentally let one
  dominate; a single `RainSensitivity` sets the balance.

## Known limits and ideas

- Constant power overstates headwind losses (real riders push harder into the wind),
  and ride timing assumes a constant cruising speed.
- Forecast points about 10 km apart see fronts and rain bands, not single shower cells.
- Ferries are a flat penalty, with no timetables. Knooppunt numbers repeat between regions,
  so use coordinates (in GeoJSON/GPX) to tell repeated numbers apart.
- Planned next: a **Foundation Models intent layer** in a separate Apple-only target. A
  `@Generable` struct turns sentences like "quick 70 km from Amsterdam, minimal
  headwind, avoid rain" into a `RideRequest`. Keep it out of this package so
  LoopRouter keeps building on Linux.

## Licences and attribution

- Road and network data: © OpenStreetMap contributors, **ODbL 1.0**. The dataset in
  `data/` is a derivative database: if you distribute it, share it under the ODbL.
  Show "© OpenStreetMap contributors" wherever maps or routes are displayed.
- Elevation: AHN via PDOK, **CC0** (crediting "AHN" is good practice).
- Weather: Open-Meteo (free tier; check their terms for commercial use).
