import Foundation

/// Area-first planning for `leaveTownQuickly`: decide *where* the ride goes before drawing a
/// loop. Instead of a loop shape around the start (which may have corners on every side of
/// a city), pick an area of open country, ride out to it, loop there, and ride back.
struct RidingArea: Sendable {
    /// Bearing from the start towards the area.
    var bearing: Double
    /// Share of the distance meant for the loop in the area; the rest is the way there and back.
    var loopShare: Double
    var centre: Coordinate
    /// Radius (m) of the area the loop proper covers.
    var radius: Double
    /// 0…1: cyclability of the ride (area and way there), times network and wind factors.
    var score: Double
    /// Mean cyclability (0…1) of the area itself, and the factors for network and wind.
    var areaQuality: Double = 0
    var networkFactor: Double = 1
    var windFactor: Double = 1
    /// The real way in (edges from the start), once `areaCandidates` has found it.
    var stem: [Int] = []
}

extension LoopGenerator {
    static let areaDirections = 24
    static let areaLoopShares = [1.0, 0.8, 0.65, 0.5]
    /// Areas must be at least this far apart in bearing, so the loops offered differ.
    static let areaSeparation = 50.0

    /// The best riding areas for a ride of `distance` metres from `start`, in clearly
    /// different directions, best first, judged on the straight line out. Empty without a
    /// cyclability grid. (`areaCandidates` re-judges them on the real way there.)
    func ridingAreas(from start: Coordinate, distance: Double, request: RideRequest, count: Int) -> [RidingArea] {
        Self.pickDiverse(areaOptions(from: start, distance: distance, request: request), count: count)
    }

    /// Every direction × loop share, scored on the straight line out.
    func areaOptions(from start: Coordinate, distance: Double, request: RideRequest) -> [RidingArea] {
        let grid = graph.cells
        guard !grid.isEmpty, distance > 0 else { return [] }
        let windFactor = areaWindFactor(request: request)
        var options: [RidingArea] = []
        for k in 0..<Self.areaDirections {
            let bearing = Double(k) * 360 / Double(Self.areaDirections)
            for share in Self.areaLoopShares {
                let loop = share * distance
                let stem = (1 - share) * distance / 2
                let radius = loop / (2 * .pi * Self.initialCircuity)
                let centre = Geo.destination(from: start, bearing: bearing, distance: stem / Self.initialCircuity + radius)
                let area = Self.discStats(grid, centre: centre, radius: radius)
                // The way there: cells along the straight line from the start to the area's edge.
                let corridor = stem > 0
                    ? Self.lineStats(grid, from: start, bearing: bearing, length: stem / Self.initialCircuity)
                    : area.mean
                let quality = (loop * area.mean + 2 * stem * corridor) / distance
                // Enough routes in the area to ride a loop of that length (open water has none).
                let network = min(1, area.km / loop * 1_000)
                options.append(RidingArea(bearing: bearing, loopShare: share, centre: centre, radius: radius,
                                          score: quality * network * windFactor(bearing), areaQuality: area.mean,
                                          networkFactor: network, windFactor: windFactor(bearing)))
            }
        }
        return options
    }

    /// The best `count` options at least `areaSeparation` degrees apart, best first.
    static func pickDiverse(_ options: [RidingArea], count: Int) -> [RidingArea] {
        var picked: [RidingArea] = []
        for o in options.sorted(by: { ($0.score, -$0.bearing, $0.loopShare) > ($1.score, -$1.bearing, $1.loopShare) })
        where picked.count < count {
            if picked.allSatisfy({ angle($0.bearing, o.bearing) >= areaSeparation }) { picked.append(o) }
        }
        return picked
    }

    /// How well a direction suits the wind strategy (1 = best). `headwindFirst` favours
    /// riding out into the first-half wind: out and back along the wind is headwind out,
    /// tailwind home. `minimizeHeadwind` favours going across the wind.
    func areaWindFactor(request: RideRequest) -> (Double) -> Double {
        let duration = request.estimatedDuration(distance: request.targetDistance, ascent: 0)
        let mid = request.departure.addingTimeInterval(duration / 2)
        let end = request.departure.addingTimeInterval(duration)
        let local = weather?.forecast(near: request.start)
        switch request.effectiveWindStrategy {
        case .ignore:
            return { _ in 1 }
        case .headwindFirst:
            guard let w = local?.meanWind(from: request.departure, to: mid), w.speed >= 2 else { return { _ in 1 } }
            return { b in 0.7 + 0.3 * (1 + cos(Geo.rad(Self.angle(b, w.fromDegrees)))) / 2 }
        case .minimizeHeadwind:
            guard let w = local?.meanWind(from: request.departure, to: end), w.speed >= 2 else { return { _ in 1 } }
            return { b in 0.85 + 0.15 * abs(sin(Geo.rad(Self.angle(b, w.fromDegrees)))) }
        }
    }

    /// Smallest angle between two bearings, 0…180.
    static func angle(_ a: Double, _ b: Double) -> Double {
        abs(Geo.normalize(a - b + 180) - 180)
    }

    /// Mean cyclability (0…1) of the cells within `radius` of `centre` (cells without routes
    /// count as 0: nothing to ride there), and the km of routes in them.
    static func discStats(_ grid: CyclabilityGrid, centre: Coordinate, radius: Double) -> (mean: Double, km: Double) {
        let reach = max(radius, 1_500)
        let dLat = reach / Geo.metersPerDegreeLatitude
        let dLon = dLat / max(0.1, cos(Geo.rad(centre.latitude)))
        let (i0, j0) = CyclabilityGrid.index(of: Coordinate(latitude: centre.latitude - dLat, longitude: centre.longitude - dLon))
        let (i1, j1) = CyclabilityGrid.index(of: Coordinate(latitude: centre.latitude + dLat, longitude: centre.longitude + dLon))
        var sum = 0.0, n = 0, km = 0.0
        for i in i0...i1 {
            for j in j0...j1 where Geo.distance(CyclabilityGrid.centre(i, j), centre) <= reach {
                n += 1
                if let c = grid.cells[CyclabilityGrid.key(i, j)] {
                    sum += Double(c.cyclability) / 100
                    km += c.networkKm
                }
            }
        }
        return (n > 0 ? sum / Double(n) : 0, km)
    }

    /// Mean cyclability (0…1) of the cells along a straight line, sampled every km; cells
    /// without routes are skipped (the route will find a way round them).
    static func lineStats(_ grid: CyclabilityGrid, from start: Coordinate, bearing: Double, length: Double) -> Double {
        var sum = 0.0, n = 0
        var d = 500.0
        while d <= max(length, 500) {
            if let c = grid.cell(at: Geo.destination(from: start, bearing: bearing, distance: d)) {
                sum += Double(c.cyclability) / 100
                n += 1
            }
            d += 1_000
        }
        return n > 0 ? sum / Double(n) : 0
    }
}
