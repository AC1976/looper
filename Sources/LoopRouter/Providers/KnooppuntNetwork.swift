import Foundation

// MARK: - Segment profile

/// Length shares (0...1) of a knooppunt segment, as computed by the extractor.
public struct SegmentProfile: Sendable, Hashable {
    public var separated = 0.0
    public var bikePriority = 0.0
    public var quietShared = 0.0
    public var ruralLane = 0.0
    public var paintedLane = 0.0
    public var sharedRoad = 0.0
    public var ferry = 0.0
    public var semiPaved = 0.0
    public var unpaved = 0.0
    public var surfaceUnknown = 0.0
    /// Signed route length ÷ simplified geometry length; applied to edge lengths.
    public var lengthScale = 1.0
    /// Share of length in built-up areas (towns and villages), from OSM landuse.
    public var urban = 0.0
    /// Traffic-light intersections per km of the segment.
    public var trafficSignalsPerKm = 0.0
    /// Share of length also on a Dutch long-distance (LF) route, and on a EuroVelo route:
    /// curated, signposted, usually scenic and well surfaced.
    public var lf = 0.0
    public var euroVelo = 0.0

    /// Share on either kind of long-distance route (the larger of the two shares; they
    /// mostly overlap where both exist).
    public var longDistance: Double { max(lf, euroVelo) }

    /// Expected motor traffic (0...1) before the time-of-day factor.
    public var baseCongestion: Double {
        0.03 * bikePriority + 0.15 * quietShared + 0.25 * ruralLane
            + 0.45 * paintedLane + 0.7 * sharedRoad
    }
}

// MARK: - GeoJSON model (output of extractor/extract_knooppunten.py)

struct GeoJSONGeometry: Decodable {
    let lines: [[Coordinate]]   // Point → one line with one point
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func coord(_ p: [Double]) -> Coordinate { Coordinate(latitude: p[1], longitude: p[0]) }
        switch type {
        case "Point": lines = [[coord(try c.decode([Double].self, forKey: .coordinates))]]
        case "LineString": lines = [try c.decode([[Double]].self, forKey: .coordinates).map(coord)]
        case "MultiLineString": lines = try c.decode([[[Double]]].self, forKey: .coordinates).map { $0.map(coord) }
        default: lines = []
        }
    }
    enum CodingKeys: String, CodingKey { case type, coordinates }
}

struct JunctionProperties: Decodable {
    let junction_id: Int64
    let number: String?
    let elevation_m: Double?
}

struct SegmentProperties: Decodable {
    let segment_id: Int64
    let from_junction: Int64?
    let to_junction: Int64?
    let length_m: Double?
    let intra_junction_connector: Bool?
    let share_separated: Double?
    let share_bike_priority: Double?
    let share_quiet_shared: Double?
    let share_rural_lane: Double?
    let share_painted_lane: Double?
    let share_shared_road: Double?
    let share_ferry: Double?
    let share_semi_paved: Double?
    let share_unpaved: Double?
    let share_surface_unknown: Double?
    let share_urban: Double?
    let traffic_signals: Int?
    let share_lf: Double?
    let share_eurovelo: Double?
}

struct Feature<P: Decodable>: Decodable {
    let properties: P
    let geometry: GeoJSONGeometry?
}

struct FeatureCollection<P: Decodable>: Decodable {
    let features: [Feature<P>]
}

// MARK: - Network

/// The knooppunt network loaded from `junctions.geojson` + `segments.geojson`.
/// Load once at startup; it is immutable and safe to share across requests.
public struct KnooppuntNetwork: Sendable {
    public struct Junction: Sendable, Equatable {
        public let id: Int64
        public let number: String
        public let coordinate: Coordinate
        /// Metres NAP from the extractor's AHN lookup, if run with `--ahn`.
        public let elevation: Double?
    }

    public struct Segment: Sendable, Equatable {
        public let id: Int64
        public let from: Int64
        public let to: Int64
        public let length: Double
        /// Routing geometry: oriented from `from` to `to`, thinned to about `pointSpacing`,
        /// junction points included. Each pair of consecutive points becomes a graph edge.
        public let path: [Coordinate]
        /// Display geometry: the full shape, oriented the same way and simplified to within
        /// `displayTolerance`, junction points included. It passes through every `path` point.
        public let displayPath: [Coordinate]
        /// Where each `path` point sits in `displayPath`: `displayPath[pathIndices[k]] == path[k]`.
        public let pathIndices: [Int]
        public let profile: SegmentProfile

        init(id: Int64, from: Int64, to: Int64, length: Double,
             displayPath: [Coordinate], pathIndices: [Int], profile: SegmentProfile) {
            self.id = id
            self.from = from
            self.to = to
            self.length = length
            self.path = pathIndices.map { displayPath[$0] }
            self.displayPath = displayPath
            self.pathIndices = pathIndices
            self.profile = profile
        }

        /// Display points from `path[k]` to `path[k + 1]`, both ends included.
        public func displayPiece(_ k: Int) -> ArraySlice<Coordinate> {
            displayPath[pathIndices[k]...pathIndices[k + 1]]
        }
    }

    public let junctions: [Int64: Junction]
    public let segments: [Segment]
    /// Where it's good to ride, per ~2 km cell; empty for a dataset without `cells.geojson`.
    public let cells: CyclabilityGrid

    /// True when the junctions carry elevations (extractor run with `--ahn`).
    public var hasElevation: Bool { junctions.values.contains { $0.elevation != nil } }

    /// Minimum spacing of intermediate geometry points. Smaller = better wind modelling, bigger graph.
    public static let pointSpacing = 150.0
    /// How far (m) the display geometry may stray from the original shape: close enough to
    /// follow streets at the nearest map zoom, loose enough to drop redundant points.
    public static let displayTolerance = 3.0

    public init(junctions: [Int64: Junction], segments: [Segment], cells: CyclabilityGrid = .empty) {
        self.junctions = junctions
        self.segments = segments
        self.cells = cells
    }

    public static func load(directory: URL) throws -> KnooppuntNetwork {
        try load(junctions: Data(contentsOf: directory.appendingPathComponent("junctions.geojson")),
                 segments: Data(contentsOf: directory.appendingPathComponent("segments.geojson")),
                 cells: try? Data(contentsOf: directory.appendingPathComponent("cells.geojson")))
    }

    /// `cells`, if given, is the extractor's `cells.geojson` (the cyclability grid).
    public static func load(junctions jData: Data, segments sData: Data, cells cData: Data? = nil) throws -> KnooppuntNetwork {
        let decoder = JSONDecoder()
        var junctions: [Int64: Junction] = [:]
        for f in try decoder.decode(FeatureCollection<JunctionProperties>.self, from: jData).features {
            guard let p = f.geometry?.lines.first?.first else { continue }
            junctions[f.properties.junction_id] = Junction(id: f.properties.junction_id,
                                                           number: f.properties.number ?? "?", coordinate: p,
                                                           elevation: f.properties.elevation_m)
        }

        var segments: [Segment] = []
        for f in try decoder.decode(FeatureCollection<SegmentProperties>.self, from: sData).features {
            let p = f.properties
            guard p.intra_junction_connector != true,
                  let from = p.from_junction, let to = p.to_junction, from != to,
                  let a = junctions[from], let b = junctions[to],
                  let lines = f.geometry?.lines, !lines.isEmpty else { continue }
            let (displayPath, pathIndices) = orientedPaths(lines: lines, from: a.coordinate, to: b.coordinate)
            let path = pathIndices.map { displayPath[$0] }
            let pathLength = zip(path, path.dropFirst()).reduce(0) { $0 + Geo.distance($1.0, $1.1) }
            let length = p.length_m ?? pathLength
            let profile = SegmentProfile(
                separated: p.share_separated ?? 0, bikePriority: p.share_bike_priority ?? 0,
                quietShared: p.share_quiet_shared ?? 0, ruralLane: p.share_rural_lane ?? 0,
                paintedLane: p.share_painted_lane ?? 0, sharedRoad: p.share_shared_road ?? 0,
                ferry: p.share_ferry ?? 0, semiPaved: p.share_semi_paved ?? 0,
                unpaved: p.share_unpaved ?? 0, surfaceUnknown: p.share_surface_unknown ?? 0,
                lengthScale: pathLength > 1 ? min(3, max(0.8, length / pathLength)) : 1,
                urban: p.share_urban ?? 0,
                trafficSignalsPerKm: length > 0 ? Double(p.traffic_signals ?? 0) / (length / 1_000) : 0,
                lf: p.share_lf ?? 0, euroVelo: p.share_eurovelo ?? 0)
            segments.append(Segment(id: p.segment_id, from: from, to: to, length: length,
                                    displayPath: displayPath, pathIndices: pathIndices, profile: profile))
        }
        let cells = try cData.map { try CyclabilityGrid.load(geoJSON: $0) } ?? .empty
        return KnooppuntNetwork(junctions: junctions, segments: segments, cells: cells)
    }

    /// Picks the longest part (one-way splits and gaps yield several), orients it from
    /// `from` to `to` and pins both ends to the junctions. Returns the display geometry
    /// (simplified to `displayTolerance`) and the indices in it of the routing points
    /// (thinned to `pointSpacing`). Every routing point is kept in the display geometry,
    /// so each routing edge has an exact piece of it.
    static func orientedPaths(lines: [[Coordinate]], from: Coordinate,
                              to: Coordinate) -> (display: [Coordinate], pathIndices: [Int]) {
        func length(_ l: [Coordinate]) -> Double { zip(l, l.dropFirst()).reduce(0) { $0 + Geo.distance($1.0, $1.1) } }
        guard var main = lines.max(by: { length($0) < length($1) }), main.count >= 2 else { return ([from, to], [0, 1]) }
        let keep = Geo.distance(main.first!, from) + Geo.distance(main.last!, to)
        let flip = Geo.distance(main.last!, from) + Geo.distance(main.first!, to)
        if flip < keep { main.reverse() }

        // Routing points: original points at least `pointSpacing` apart and not too close
        // to the end junction, as indices into `main`.
        var kept: [Int] = []
        var last = from
        for (i, p) in main.dropLast().enumerated()
        where Geo.distance(p, last) >= pointSpacing && Geo.distance(p, to) >= pointSpacing / 2 {
            kept.append(i)
            last = p
        }

        // Display points: between each pair of routing points, the original points the
        // simplification keeps.
        var display = [from]
        var indices = [0]
        var previous = -1
        for anchor in kept + [main.count] {
            let end = anchor < main.count ? main[anchor] : to
            let interior = main[(previous + 1)..<anchor]
            display += simplify(from: display.last!, interior, to: end, tolerance: displayTolerance)
            display.append(end)
            indices.append(display.count - 1)
            previous = anchor
        }
        return (display, indices)
    }

    /// The routing points only (thinned to `pointSpacing`), junction points included.
    static func orientedPath(lines: [[Coordinate]], from: Coordinate, to: Coordinate) -> [Coordinate] {
        let (display, indices) = orientedPaths(lines: lines, from: from, to: to)
        return indices.map { display[$0] }
    }

    /// Douglas–Peucker: the points of `interior` to keep so that `start → kept → end` stays
    /// within `tolerance` metres of `start → interior → end`.
    static func simplify(from start: Coordinate, _ interior: ArraySlice<Coordinate>, to end: Coordinate,
                         tolerance: Double) -> [Coordinate] {
        let points = [start] + interior + [end]
        guard points.count > 2 else { return [] }
        // Local flat projection in metres; accurate enough over a few kilometres.
        let k = Geo.metersPerDegreeLatitude
        let cosLat = cos(Geo.rad(start.latitude))
        let xy = points.map { (($0.longitude - start.longitude) * cosLat * k, ($0.latitude - start.latitude) * k) }
        func offset(_ i: Int, _ a: Int, _ b: Int) -> Double {
            let (px, py) = xy[i], (ax, ay) = xy[a], (bx, by) = xy[b]
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / len2)) : 0
            let ex = ax + t * dx - px, ey = ay + t * dy - py
            return (ex * ex + ey * ey).squareRoot()
        }
        var keep = [Bool](repeating: false, count: points.count)
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = a, worstOffset = 0.0
            for i in (a + 1)..<b {
                let d = offset(i, a, b)
                if d > worstOffset { worst = i; worstOffset = d }
            }
            if worstOffset > tolerance {
                keep[worst] = true
                stack.append((a, worst))
                stack.append((worst, b))
            }
        }
        return (1..<(points.count - 1)).filter { keep[$0] }.map { points[$0] }
    }

    /// Builds a routing graph of the segments touching the circle around `center`.
    public func graphBuilder(around center: Coordinate, radius: Double) -> RoadGraphBuilder {
        var b = RoadGraphBuilder()
        b.cells = cells
        for s in segments {
            guard let a = junctions[s.from], let z = junctions[s.to],
                  Geo.distance(a.coordinate, center) <= radius || Geo.distance(z.coordinate, center) <= radius
            else { continue }
            // Only junctions have measured heights; points in between are interpolated
            // linearly by distance, so a segment's climb is (to − from) spread evenly.
            let za = a.elevation ?? z.elevation ?? 0
            let zz = z.elevation ?? a.elevation ?? 0
            var cumulative = [0.0]
            for (p, q) in zip(s.path, s.path.dropFirst()) { cumulative.append(cumulative.last! + Geo.distance(p, q)) }
            let total = max(cumulative.last!, 1)
            var idx = [b.addNode(id: a.id, coordinate: a.coordinate, elevation: za, label: a.number)]
            for (k, p) in s.path.enumerated().dropFirst().dropLast() {
                // Intermediate points get negative synthetic IDs so they never collide with junctions.
                let t = cumulative[k] / total
                idx.append(b.addNode(id: -(s.id * 1_000 + Int64(k)), coordinate: p, elevation: za + (zz - za) * t))
            }
            idx.append(b.addNode(id: z.id, coordinate: z.coordinate, elevation: zz, label: z.number))
            let shapes = (0..<(s.path.count - 1)).map { Array(s.displayPiece($0).dropFirst().dropLast()) }
            b.addPath(nodeIndices: idx, profile: s.profile, shapes: shapes)
        }
        return b
    }
}
