import Foundation

/// Where the built-up areas are in a routing graph, for `RideRequest.leaveTownQuickly`.
struct TownMap: Sendable {
    /// Mean built-up share (0…1) of the edges at each node.
    let nodeUrban: [Double]
    /// Segments that are mostly built-up (share ≥ 0.5).
    let builtUpSegments: Set<Int>
    let graph: RoadGraph
    /// Built-up length and total length of the network per ~1 km cell.
    private let cells: [Int64: (urban: Double, length: Double)]
    static let cellLatitude = 0.009, cellLongitude = 0.0146  // about 1 km by 1 km in the Netherlands

    init(graph: RoadGraph) {
        self.graph = graph
        var sum = [Double](repeating: 0, count: graph.nodes.count)
        var count = [Int](repeating: 0, count: graph.nodes.count)
        var builtUp = Set<Int>()
        var cells: [Int64: (urban: Double, length: Double)] = [:]
        for e in graph.edges {
            sum[e.from] += e.profile.urban
            count[e.from] += 1
            if e.profile.urban >= 0.5 { builtUp.insert(e.segmentID) }
            if e.index % 2 == 0 {
                let key = Self.cell(graph.nodes[e.from].coordinate)
                let old = cells[key] ?? (0, 0)
                cells[key] = (old.urban + e.profile.urban * e.length, old.length + e.length)
            }
        }
        nodeUrban = zip(sum, count).map { $1 > 0 ? $0 / Double($1) : 0 }
        builtUpSegments = builtUp
        self.cells = cells
    }

    private static func cell(_ c: Coordinate, di: Int = 0, dj: Int = 0) -> Int64 {
        let i = Int((c.latitude / cellLatitude).rounded(.down)) + di
        let j = Int((c.longitude / cellLongitude).rounded(.down)) + dj
        return (Int64(i) << 32) | Int64(UInt32(truncatingIfNeeded: j))
    }

    /// True when the network within about 1.5 km of `c` is mostly outside town.
    func isCountryside(around c: Coordinate) -> Bool {
        var urban = 0.0, length = 0.0
        for di in -1...1 {
            for dj in -1...1 {
                if let v = cells[Self.cell(c, di: di, dj: dj)] {
                    urban += v.urban
                    length += v.length
                }
            }
        }
        return length > 0 && urban / length < 0.25
    }

    /// How built-up the network is in each direction from the start, for turning loop
    /// shapes towards the countryside.
    struct Steering: Sendable {
        static let sectorDegrees = 10.0
        /// Built-up share per 10° sector (index 0 = north), smoothed over ±30°. A sector
        /// without network (open water, a border) counts as fully built-up: no use going there.
        let urban: [Double]

        /// The heading within `spread` degrees of `heading` with the least built-up network
        /// in that direction; slightly favours staying close to `heading`.
        func steer(_ heading: Double, within spread: Double) -> Double {
            var best = heading, bestValue = Double.infinity
            for offset in stride(from: -spread, through: spread, by: Self.sectorDegrees) {
                let h = Geo.normalize(heading + offset)
                let value = urban[Self.sector(h, count: urban.count)] + 0.001 * abs(offset)
                if value < bestValue { best = h; bestValue = value }
            }
            return best
        }

        static func sector(_ bearing: Double, count: Int) -> Int {
            min(count - 1, Int(Geo.normalize(bearing) / sectorDegrees))
        }
    }

    /// Steering for a loop of `loopLength` metres from `start`, or nil when the start isn't
    /// in town (then there's nothing to get out of).
    func steering(around start: Coordinate, loopLength: Double) -> Steering? {
        // How built-up it is right around the start.
        var nearLength = 0.0, nearUrban = 0.0
        // Per sector, over the area the loop will cover: from just outside the start to
        // about the far side of the loop.
        let sectors = Int(360 / Steering.sectorDegrees)
        var length = [Double](repeating: 0, count: sectors), urban = [Double](repeating: 0, count: sectors)
        let inner = 1_500.0, outer = max(3_000, loopLength / .pi)
        // Each segment piece is two edges (one per direction); count it once.
        for e in graph.edges where e.index % 2 == 0 {
            let p = graph.nodes[e.from].coordinate
            let d = Geo.distance(start, p)
            if d <= 2_000 {
                nearLength += e.length
                nearUrban += e.profile.urban * e.length
            }
            guard d >= inner, d <= outer else { continue }
            let s = Steering.sector(Geo.bearing(start, p), count: sectors)
            length[s] += e.length
            urban[s] += e.profile.urban * e.length
        }
        guard nearLength > 0, nearUrban / nearLength >= 0.25 else { return nil }
        let smoothed = (0..<sectors).map { s in
            var l = 0.0, u = 0.0
            for k in -3...3 {
                let i = (s + k + sectors) % sectors
                l += length[i]
                u += urban[i]
            }
            return l > 0 ? u / l : 1
        }
        return Steering(urban: smoothed)
    }
}
