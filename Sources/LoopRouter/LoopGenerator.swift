import Foundation

public enum LoopRouterError: Error, CustomStringConvertible {
    case noJunctionNearStart(Coordinate)
    case noLoopsFound
    case provider(String)

    public var description: String {
        switch self {
        case .noJunctionNearStart(let c): "No knooppunt within \(Int(LoopGenerator.maxJunctionAccess / 1000)) km of \(c)."
        case .noLoopsFound: "Could not construct any loop; try a different distance or start point."
        case .provider(let msg): "Data provider error: \(msg)"
        }
    }
}

/// Generates loops around the start point.
///
/// Algorithm ("waypoint polygon" + cost-aware A*):
/// 1. Start at the nearest knooppunt; the ride there and back comes off the target.
/// 2. Create many candidate shapes: a polygon with 3–6 corners whose first corner
///    is the start, sized so its perimeter × typical road circuity ≈ target distance.
///    Headings follow the wind strategy, using the forecast over the whole ride:
///    `headwindFirst` heads into the first-half wind; `minimizeHeadwind` stretches
///    loops across the ride-mean wind, and also tries "out with the first-half wind,
///    home with the second-half wind" for when the wind turns.
/// 3. Snap the corners to junctions and route corner→corner with A* using the
///    `CostModel`; segments already used are penalised so we avoid out-and-back.
/// 4. Rescale the polygon up to 3 times until the routed length hits the target.
/// 5. Score each candidate and pick the best `loopCount` that are mutually distinct.
public struct LoopGenerator: Sendable {
    public let graph: RoadGraph
    public let traffic: any TrafficModel
    public let weather: WeatherField?

    /// Typical ratio of road distance to straight-line distance.
    static let initialCircuity = 1.3
    static let reusePenalty = 3.0
    /// With `LongDistanceRoutes.follow`: how much more a riding area scores when its loop
    /// could run entirely on long-distance routes (1.5 times at most).
    static let followAreaBonus = 0.5
    static let maxRescaleIterations = 3
    /// Length ÷ width of `minimizeHeadwind` loops. Tuned on live Amsterdam runs (70 km,
    /// 5 m/s easterly): 3.0 cut mean headwind ~15 % vs headwindFirst; 1.8 only ~9 %.
    static let crosswindElongation = 3.0
    /// How far the rider may be from the nearest knooppunt.
    public static let maxJunctionAccess = 5_000.0

    public init(graph: RoadGraph, traffic: any TrafficModel = HeuristicTrafficModel(), weather: WeatherField?) {
        self.graph = graph
        self.traffic = traffic
        self.weather = weather
    }

    /// Same forecast everywhere (single point).
    public init(graph: RoadGraph, traffic: any TrafficModel = HeuristicTrafficModel(), weather: WeatherForecast? = nil) {
        self.init(graph: graph, traffic: traffic, weather: weather.map(WeatherField.uniform))
    }

    public func generate(_ request: RideRequest) async throws -> [LoopRoute] {
        // Start at the nearest signposted junction; the rider gets there on ordinary
        // roads, so that access distance comes off the loop.
        guard let startNode = graph.nearestNode(to: request.start, maxDistance: Self.maxJunctionAccess, where: {
            graph.nodes[$0].label != nil && graph.degree[$0] >= 2
        }) else { throw LoopRouterError.noJunctionNearStart(request.start) }

        let accessDistance = Geo.distance(request.start, graph.nodes[startNode].coordinate)
        var shapedRequest = request
        shapedRequest.targetDistance = max(request.targetDistance * 0.5,
                                           request.targetDistance - 2 * accessDistance * Self.initialCircuity)
        let town = request.leaveTownQuickly ? TownMap(graph: graph) : nil
        // Follow long-distance routes: build the candidates around them, not just pull towards them.
        let routes = request.longDistanceRoutes == .follow ? LongDistanceMap(graph: graph) : nil
        let steering = town?.steering(around: graph.nodes[startNode].coordinate, loopLength: shapedRequest.targetDistance)
        var specs = candidateShapes(for: shapedRequest, steering: steering)
        let loopRequest = shapedRequest

        // Leave town quickly from a start in town: every other candidate is a "lollipop",
        // the cheapest way out to a junction with countryside around it (a gateway), the
        // loop from there, and the same way back.
        var stems = [[Int]](repeating: [], count: specs.count)
        if let town, steering != nil {
            let gateways = self.gateways(from: startNode, request: loopRequest, town: town)
            for i in specs.indices where i % 2 == 0 {
                guard let g = gateways.best(towards: specs[i].headingDegrees) else { continue }
                let stemLength = g.stem.reduce(0) { $0 + graph.edges[$1].length }
                let loopPart = loopRequest.targetDistance - 2 * stemLength
                guard loopPart >= 0.4 * loopRequest.targetDistance else { continue }
                stems[i] = g.stem
                // The loop proper starts at the gateway and heads on outwards.
                specs[i].headingDegrees = Geo.bearing(graph.nodes[startNode].coordinate, graph.nodes[g.node].coordinate)
                specs[i].radius *= loopPart / loopRequest.targetDistance
            }
        }

        // Area-first (leaveTownQuickly with a cyclability grid): pick the best areas of open
        // country within reach, ride out to each, loop there, and ride back the same way.
        if request.leaveTownQuickly, !graph.cells.isEmpty {
            let (areaSpecs, areaStems) = areaCandidates(startNode: startNode, request: loopRequest, routes: routes)
            specs += areaSpecs
            stems += areaStems
        }

        let candidates: [LoopRoute] = await withTaskGroup(of: LoopRoute?.self) { group in
            for (i, spec) in specs.enumerated() {
                let stem = stems[i]
                group.addTask {
                    buildLoop(id: i, shape: spec, startNode: startNode, request: loopRequest, town: town, stem: stem,
                              routes: routes)
                }
            }
            var out: [LoopRoute] = []
            for await r in group {
                if var r {
                    r.accessDistance = accessDistance
                    out.append(r)
                }
            }
            return out
        }
        guard !candidates.isEmpty else { throw LoopRouterError.noLoopsFound }
        // Loops within the distance tolerance always rank ahead of the rest: a good score
        // (less town, less wind) mustn't buy a ride that's clearly shorter or longer than asked.
        // Candidates arrive in completion order; break score ties by id so a seed always gives the same loops.
        func outside(_ r: LoopRoute) -> Bool {
            abs(r.metrics.distance - loopRequest.targetDistance) > request.distanceTolerance * loopRequest.targetDistance
        }
        let ranked = candidates.sorted {
            (outside($0) ? 1 : 0, $0.score.total, $0.id) < (outside($1) ? 1 : 0, $1.score.total, $1.id)
        }
        return selectDiverse(ranked, count: request.loopCount, ignoring: town?.builtUpSegments ?? [])
    }

    // MARK: Candidate shapes

    /// `steering`, when given, turns each shape towards the least built-up direction nearby.
    func candidateShapes(for request: RideRequest, steering: TownMap.Steering? = nil) -> [LoopShape] {
        var rng = SplitMix64(seed: request.seed)
        let count = max(12, request.loopCount * 6)

        // Wind over the expected ride, not just at departure.
        let duration = request.estimatedDuration(distance: request.targetDistance, ascent: 0)
        let mid = request.departure.addingTimeInterval(duration / 2)
        let end = request.departure.addingTimeInterval(duration)
        let strategy = request.effectiveWindStrategy
        let local = weather?.forecast(near: request.start)
        let firstHalf = local?.meanWind(from: request.departure, to: mid)
        let secondHalf = local?.meanWind(from: mid, to: end)
        let whole = local?.meanWind(from: request.departure, to: end)
        func windy(_ w: (speed: Double, fromDegrees: Double)?) -> Double? {
            guard let w, w.speed >= 2 else { return nil }
            return w.fromDegrees
        }

        let biases = Self.climbBiases(request.climbPreference)

        let golden = 137.507_764
        let base = Double.random(in: 0..<360, using: &rng)
        return (0..<count).map { i in
            let sides = [4, 3, 5, 6][i % 4]
            let random = Geo.normalize(base + Double(i) * golden + Double.random(in: -15...15, using: &rng))
            let jitter = Double.random(in: -25...25, using: &rng)
            var heading = random
            var elongation = 1.0

            switch strategy {
            case .ignore:
                break
            case .headwindFirst:
                if let upwind = windy(firstHalf), i % 3 != 2 {
                    heading = Geo.normalize(upwind + Double.random(in: -60...60, using: &rng))
                }
            case .minimizeHeadwind:
                switch i % 4 {
                case 0, 1:
                    // Long axis across the ride-mean wind: little of the loop faces it.
                    if let from = windy(whole) {
                        heading = Geo.normalize(from + (i % 4 == 0 ? 90 : -90) + jitter)
                        elongation = Self.crosswindElongation
                    }
                case 2:
                    // Wind turning: go out with the first-half wind behind you, or towards
                    // where the second-half wind comes from, so it pushes you home.
                    let options = [windy(firstHalf).map { $0 + 180 }, windy(secondHalf)].compactMap { $0 }
                    if !options.isEmpty {
                        heading = Geo.normalize(options[(i / 4) % options.count] + jitter)
                        elongation = Self.crosswindElongation
                    }
                default:
                    break
                }
            }

            // Leave town quickly: turn towards the countryside, less far when the wind
            // strategy already chose the direction.
            if let steering {
                let spread: Double = switch strategy {
                case .ignore: 90
                case .headwindFirst: 45
                case .minimizeHeadwind: 30
                }
                heading = steering.steer(heading, within: spread)
            }

            let radius = request.targetDistance / (Self.initialCircuity * Self.perimeterFactor(sides: sides, elongation: elongation))
                * Double.random(in: 0.9...1.1, using: &rng)
            return LoopShape(sides: sides, headingDegrees: heading,
                             clockwise: Bool.random(using: &rng),
                             climbBias: biases[i % biases.count], radius: radius, elongation: elongation)
        }
    }

    /// Climb biases to spread over the candidates for a climb preference.
    static func climbBiases(_ preference: ClimbPreference) -> [Double] {
        switch preference {
        case .avoid: [-1.0]
        case .neutral: [0.0]
        case .seek: [1.0, 0.6]
        case .targetAscent: [-0.6, 0.0, 0.5, 1.0]
        }
    }

    /// Perimeter ÷ radius of the corner polygon, scaled for elongation via the
    /// ellipse perimeter (Ramanujan) relative to a circle.
    static func perimeterFactor(sides: Int, elongation e: Double) -> Double {
        let polygon = 2 * Double(sides) * sin(.pi / Double(sides))
        let a = e, b = 1 / e
        let ellipse = Double.pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
        return polygon * ellipse / (2 * .pi)
    }

    /// Polygon corners (excluding the start) for a given shape.
    /// The polygon's centre lies ahead of the start in `heading`, so the far side of the
    /// loop – reached around half-way – is in the heading direction. With elongation e
    /// the corners sit on an ellipse with semi-axes r·e (along heading) and r/e (across).
    static func corners(start: Coordinate, shape: LoopShape, radius: Double) -> [Coordinate] {
        let e = shape.elongation
        let centre = Geo.destination(from: start, bearing: shape.headingDegrees, distance: radius * e)
        let startAngle = 180.0
        let step = 360 / Double(shape.sides) * (shape.clockwise ? 1 : -1)
        return (1..<shape.sides).map { k in
            let rel = Geo.rad(startAngle + Double(k) * step)
            let along = radius * e * cos(rel)
            let across = radius / e * sin(rel)
            let p = Geo.destination(from: centre, bearing: shape.headingDegrees, distance: along)
            return Geo.destination(from: p, bearing: shape.headingDegrees + 90, distance: across)
        }
    }

    // MARK: Area-first candidates

    /// Loop shapes (and the way out to each) for the best riding areas: 4 variants per area.
    /// With `routes` (`LongDistanceRoutes.follow`), areas with more long-distance km outside
    /// town score up to 1.5 times higher.
    func areaCandidates(startNode: Int, request: RideRequest,
                        routes: LongDistanceMap? = nil) -> (shapes: [LoopShape], stems: [[Int]]) {
        let start = graph.nodes[startNode].coordinate
        let target = request.targetDistance
        let options = areaOptions(from: start, distance: target, request: request)
        guard !options.isEmpty else { return ([], []) }
        let model = CostModel(request: request, weather: weather, traffic: traffic, climbBias: 0)
        let finder = Pathfinder(graph: graph)
        let tree = finder.tree(from: startNode, maxDistance: 0.4 * target) { e, d, c in
            model.cost(of: e, at: graph.nodes[e.from].coordinate, travelled: d, ascent: c)
        }
        let comp = graph.component[startNode]
        let junctions = graph.nodes.indices.filter { n in
            tree.cost[n].isFinite && graph.nodes[n].label != nil && graph.degree[n] >= 3 && graph.component[n] == comp
        }
        // Re-judge every option on its real way in: the cheapest junction inside the area,
        // how long and how open the way there really is, and what's left for the loop.
        var judged: [RidingArea] = []
        for var area in options {
            if Geo.distance(start, area.centre) > area.radius * 1.2 {
                let inside = junctions.filter { Geo.distance(graph.nodes[$0].coordinate, area.centre) <= area.radius * 0.9 }
                guard let g = inside.min(by: { (tree.cost[$0], $0) < (tree.cost[$1], $1) }),
                      let path = finder.path(to: g, via: tree.via, from: startNode) else { continue }
                area.stem = path
            }
            let stemLength = area.stem.reduce(0) { $0 + graph.edges[$1].length }
            let loop = target - 2 * stemLength
            guard loop >= 0.35 * target else { continue }
            let stemQuality = stemLength > 0
                ? area.stem.reduce(0) { $0 + (graph.edges[$1].cyclability ?? 0) * graph.edges[$1].length } / stemLength
                : 0
            area.score = (loop * area.areaQuality + 2 * stemLength * stemQuality) / target
                * area.networkFactor * area.windFactor
            if let routes {
                let share = min(1, routes.km(around: area.centre, radius: area.radius) * 1_000 / max(1, loop))
                area.score *= 1 + Self.followAreaBonus * share
            }
            judged.append(area)
        }
        let biases = Self.climbBiases(request.climbPreference)
        var shapes: [LoopShape] = [], stems: [[Int]] = []
        for area in Self.pickDiverse(judged, count: max(4, request.loopCount + 1)) {
            let stem = area.stem
            let stemLength = stem.reduce(0) { $0 + graph.edges[$1].length }
            let loopPart = target - 2 * stemLength
            let from = graph.nodes[stem.last.map { graph.edges[$0].to } ?? startNode].coordinate
            // Loop on towards the area's centre, so it stays in the area.
            let heading = Geo.distance(from, area.centre) > 500 ? Geo.bearing(from, area.centre) : area.bearing
            for v in 0..<4 {
                let sides = [4, 5, 3, 6][v]
                let radius = loopPart / (Self.initialCircuity * Self.perimeterFactor(sides: sides, elongation: 1))
                    * [1.0, 0.95, 1.05, 1.0][v]
                shapes.append(LoopShape(sides: sides, headingDegrees: Geo.normalize(heading + [0, -20, 20, 0][v]),
                                        clockwise: v % 2 == 0, climbBias: biases[v % biases.count], radius: radius))
                stems.append(stem)
            }
        }
        return (shapes, stems)
    }

    // MARK: Gateways out of town

    struct Gateways {
        let start: Coordinate
        let graph: RoadGraph
        /// Junctions with countryside around them, with the cheapest way there.
        let options: [(node: Int, cost: Double, stem: [Int])]

        /// The cheapest gateway within 60° of `heading` from the start.
        func best(towards heading: Double) -> (node: Int, stem: [Int])? {
            options.filter { o in
                abs(Geo.normalize(Geo.bearing(start, graph.nodes[o.node].coordinate) - heading + 180) - 180) <= 60
            }.min { ($0.cost, $0.node) < ($1.cost, $1.node) }.map { ($0.node, $0.stem) }
        }
    }

    /// Junctions outside town (with countryside around them) that the rider can reach from
    /// `startNode` within 30 % of the ride (at most 12 km), with the cheapest way there.
    func gateways(from startNode: Int, request: RideRequest, town: TownMap) -> Gateways {
        let model = CostModel(request: request, weather: weather, traffic: traffic, climbBias: 0)
        let finder = Pathfinder(graph: graph)
        let tree = finder.tree(from: startNode, maxDistance: min(12_000, 0.3 * request.targetDistance)) { e, d, c in
            model.cost(of: e, at: graph.nodes[e.from].coordinate, travelled: d, ascent: c)
        }
        let comp = graph.component[startNode]
        var options: [(node: Int, cost: Double, stem: [Int])] = []
        for n in graph.nodes.indices where n != startNode && tree.cost[n].isFinite {
            guard graph.nodes[n].label != nil, graph.degree[n] >= 3, graph.component[n] == comp,
                  tree.travelled[n] >= 500, town.nodeUrban[n] < 0.25,
                  town.isCountryside(around: graph.nodes[n].coordinate),
                  let stem = finder.path(to: n, via: tree.via, from: startNode) else { continue }
            options.append((n, tree.cost[n], stem))
        }
        return Gateways(start: graph.nodes[startNode].coordinate, graph: graph, options: options)
    }

    // MARK: Build one loop

    /// Builds one loop from `startNode`. With a `stem` (edges from `startNode` to a gateway
    /// out of town, or into a riding area) the route rides the stem out first, then the loop
    /// proper from the stem's end, and from its last corner routes home like any other leg.
    /// Re-riding segments costs extra in the country and nothing in town (with
    /// `leaveTownQuickly`), so it comes back the same way only where that's clearly best:
    /// a teardrop rather than a lollipop with a long stick.
    /// With `routes` (`LongDistanceRoutes.follow`), corners snap to a junction on a
    /// long-distance route outside town when there's one close by.
    func buildLoop(id: Int, shape: LoopShape, startNode: Int, request: RideRequest, town: TownMap? = nil,
                   stem: [Int] = [], routes: LongDistanceMap? = nil) -> LoopRoute? {
        let model = CostModel(request: request, weather: weather, traffic: traffic, climbBias: shape.climbBias)
        let analyzer = RouteAnalyzer(graph: graph, request: request, weather: weather, traffic: traffic)
        let finder = Pathfinder(graph: graph)
        let comp = graph.component[startNode]
        let loopStart = stem.last.map { graph.edges[$0].to } ?? startNode
        let startCoord = graph.nodes[loopStart].coordinate
        let stemLength = stem.reduce(0) { $0 + graph.edges[$1].length }
        let stemClimb = stem.reduce(0) { $0 + graph.edges[$1].ascent }
        // Distance that roughly doesn't change when the loop proper is rescaled: the way out,
        // and about as much again for the way home.
        let fixed = 2 * stemLength
        // Leave town quickly: riding the same way out and back through town is fine.
        let reusePenalty: (RoadEdge) -> Double = { e in
            Self.reusePenalty * (request.leaveTownQuickly ? 1 - e.profile.urban : 1)
        }

        var radius = shape.radius
        var best: (edges: [Int], metrics: RouteMetrics, radius: Double)?

        for _ in 0..<Self.maxRescaleIterations {
            let corners = Self.corners(start: startCoord, shape: shape, radius: radius)
            // Snap to junctions in the same connected component; prefer degree >= 3
            // so we never park a waypoint at the end of a dead-end spur.
            var waypoints = [loopStart]
            for c in corners {
                func usable(_ n: Int) -> Bool { graph.component[n] == comp && graph.degree[n] >= 3 }
                // Leave town quickly: a corner outside town if there's one nearby.
                let onRoute = routes.flatMap { routes in
                    graph.nearestNode(to: c, maxDistance: radius * 0.35) { usable($0) && routes.onRoute[$0] }
                }
                let rural = onRoute ?? town.flatMap { town in
                    graph.nearestNode(to: c, maxDistance: radius * 0.35) { usable($0) && town.nodeUrban[$0] < 0.5 }
                }
                let snap = rural ?? graph.nearestNode(to: c, maxDistance: radius * 0.6, where: usable)
                if let snap, snap != waypoints.last { waypoints.append(snap) }
            }
            // Home from the last corner: the way out again only where that's clearly best.
            waypoints.append(startNode)
            // A failed attempt ends the rescaling but keeps the best loop found so far.
            guard waypoints.count >= 3 else { break }

            var used = Set(stem.map { graph.edges[$0].segmentID })
            var edges: [Int] = []
            var ok = true
            // Distance and climbing ridden so far: each leg is priced at the time the
            // rider actually gets there, based on the legs already routed.
            var travelled = stemLength, climbed = stemClimb
            for k in 0..<(waypoints.count - 1) {
                let legStart = travelled, legClimb = climbed
                guard let leg = finder.path(from: waypoints[k], to: waypoints[k + 1],
                                            usedSegments: used, reusePenalty: reusePenalty,
                                            cost: { e, d, c in
                                                model.cost(of: e, at: graph.nodes[e.from].coordinate,
                                                           travelled: legStart + d, ascent: legClimb + c)
                                            })
                else { ok = false; break }
                edges += leg
                for ei in leg {
                    used.insert(graph.edges[ei].segmentID)
                    travelled += graph.edges[ei].length
                    climbed += graph.edges[ei].ascent
                }
            }
            guard ok else { break }
            edges = removeSpurs(stem + edges)
            guard !edges.isEmpty else { break }

            let m = analyzer.metrics(for: edges)
            let dev = abs(m.distance - request.targetDistance)
            if best == nil || dev < abs(best!.metrics.distance - request.targetDistance) {
                best = (edges, m, radius)
            }
            if dev / request.targetDistance <= request.distanceTolerance / 2 { break }
            // Rescale only the loop proper; the stem stays as it is.
            radius *= min(2, max(0.5, (request.targetDistance - fixed) / max(1, m.distance - fixed)))
        }

        guard let best else { return nil }
        var shape = shape
        shape.radius = best.radius
        let first = graph.nodes[graph.edges[best.edges[0]].from]
        var coords = [first.coordinate], elev = [first.elevation]
        var display = [first.coordinate], displayElev = [first.elevation]
        for ei in best.edges {
            let e = graph.edges[ei]
            let a = graph.nodes[e.from], b = graph.nodes[e.to]
            coords.append(b.coordinate)
            elev.append(b.elevation)
            // Display points along the edge, with heights spread by distance like the climb.
            let points = [a.coordinate] + e.shape + [b.coordinate]
            var along = [0.0]
            for (p, q) in zip(points, points.dropFirst()) { along.append(along.last! + Geo.distance(p, q)) }
            let total = max(along.last!, 1e-9)
            for k in 1..<points.count {
                display.append(points[k])
                displayElev.append(a.elevation + (b.elevation - a.elevation) * along[k] / total)
            }
        }
        return LoopRoute(id: id, edgeIndices: best.edges, coordinates: coords, elevations: elev,
                         displayCoordinates: display, displayElevations: displayElev,
                         metrics: best.metrics, score: analyzer.score(best.metrics), shape: shape,
                         segments: Set(best.edges.map { graph.edges[$0].segmentID }),
                         junctions: junctionSequence(best.edges))
    }

    /// Cancels out-and-back spurs: riding a segment and straight back along it
    /// (happens when a polygon corner snaps to a junction at the end of a branch).
    func removeSpurs(_ edges: [Int]) -> [Int] {
        var stack: [Int] = []
        for ei in edges {
            if let last = stack.last,
               graph.edges[last].segmentID == graph.edges[ei].segmentID,
               graph.edges[last].from == graph.edges[ei].to {
                stack.removeLast()
            } else {
                stack.append(ei)
            }
        }
        return stack
    }

    /// Knooppunten passed in order, with position and distance ridden; consecutive
    /// duplicates removed.
    func junctionSequence(_ edges: [Int]) -> [RouteJunction] {
        guard let first = edges.first else { return [] }
        var seq: [RouteJunction] = []
        func visit(_ node: RoadNode, at distance: Double) {
            guard let number = node.label, number != seq.last?.number else { return }
            seq.append(RouteJunction(number: number, junctionID: node.id, coordinate: node.coordinate,
                                     distanceFromStart: distance))
        }
        var distance = 0.0
        visit(graph.nodes[graph.edges[first].from], at: 0)
        for ei in edges {
            distance += graph.edges[ei].length
            visit(graph.nodes[graph.edges[ei].to], at: distance)
        }
        return seq
    }

    // MARK: Diversity

    /// Greedy pick of the best-scoring loops that share at most `maxOverlap` of their segments.
    /// Segments in `ignoring` don't count: with `leaveTownQuickly` all loops may share the
    /// one good way out of town and still be different rides.
    func selectDiverse(_ sorted: [LoopRoute], count: Int, ignoring: Set<Int> = []) -> [LoopRoute] {
        for maxOverlap in [0.4, 0.6, 0.8, 1.01] {
            var picked: [LoopRoute] = []
            for r in sorted where picked.count < count {
                let rs = r.segments.subtracting(ignoring)
                let distinct = picked.allSatisfy { p in
                    let ps = p.segments.subtracting(ignoring)
                    let inter = Double(ps.intersection(rs).count)
                    let union = Double(ps.union(rs).count)
                    return union == 0 || inter / union <= maxOverlap
                }
                if distinct { picked.append(r) }
            }
            if picked.count >= min(count, sorted.count) { return picked }
        }
        return Array(sorted.prefix(count))
    }
}
