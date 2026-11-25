import Foundation

/// Where the long-distance routes (LF, EuroVelo) run outside town in a routing graph, for
/// `LongDistanceRoutes.follow`: loop corners snap to them and riding areas with more of
/// them score higher, so the candidates themselves are built around them.
struct LongDistanceMap: Sendable {
    /// Nodes on a stretch that's mostly on a long-distance route and mostly outside town.
    let onRoute: [Bool]
    /// Long-distance km outside town per cyclability-grid cell (packed key).
    private let km: [Int64: Double]

    init(graph: RoadGraph) {
        var on = [Bool](repeating: false, count: graph.nodes.count)
        var km: [Int64: Double] = [:]
        for e in graph.edges {
            let p = e.profile
            if p.longDistance >= 0.5, p.urban < 0.5 {
                on[e.from] = true
                on[e.to] = true
            }
            // Each piece is two edges (one per direction); count it once.
            if e.index % 2 == 0, p.longDistance > 0 {
                let (i, j) = CyclabilityGrid.index(of: graph.nodes[e.from].coordinate)
                km[CyclabilityGrid.key(i, j), default: 0] += p.longDistance * (1 - p.urban) * e.length / 1_000
            }
        }
        onRoute = on
        self.km = km
    }

    /// Long-distance km outside town in the grid cells within `radius` of `centre` (the same
    /// cells `LoopGenerator.discStats` looks at).
    func km(around centre: Coordinate, radius: Double) -> Double {
        let reach = max(radius, 1_500)
        let dLat = reach / Geo.metersPerDegreeLatitude
        let dLon = dLat / max(0.1, cos(Geo.rad(centre.latitude)))
        let (i0, j0) = CyclabilityGrid.index(of: Coordinate(latitude: centre.latitude - dLat, longitude: centre.longitude - dLon))
        let (i1, j1) = CyclabilityGrid.index(of: Coordinate(latitude: centre.latitude + dLat, longitude: centre.longitude + dLon))
        var total = 0.0
        for i in i0...i1 {
            for j in j0...j1 where Geo.distance(CyclabilityGrid.centre(i, j), centre) <= reach {
                total += km[CyclabilityGrid.key(i, j)] ?? 0
            }
        }
        return total
    }
}
