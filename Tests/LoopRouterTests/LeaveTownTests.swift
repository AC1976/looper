import Foundation
import Testing
@testable import LoopRouter

/// `leaveTownQuickly` on the synthetic grid, whose middle row (where the start is) is town
/// with 2 traffic lights per segment.
@Suite struct LeaveTownTests {
    static func request(leave: Bool, seed: UInt64 = 7) -> RideRequest {
        var r = KnooppuntFixture.request(km: 24, traffic: 0, seed: seed)  // no traffic preference: town only
        r.leaveTownQuickly = leave
        return r
    }

    @Test func townAndLightsCostExtraOnlyWhenAsked() throws {
        let graph = try KnooppuntFixture.graph()
        let urban = try #require(graph.edges.first { $0.profile.urban == 1 })
        let rural = try #require(graph.edges.first { $0.profile.urban == 0 })
        func cost(_ e: RoadEdge, leave: Bool) -> Double {
            CostModel(request: Self.request(leave: leave), weather: nil, traffic: HeuristicTrafficModel(), climbBias: 0)
                .cost(of: e, at: graph.nodes[e.from].coordinate, travelled: 0, ascent: 0)
        }
        let extra = cost(urban, leave: true) - cost(urban, leave: false)
        let lights = CostModel.trafficLightSeconds * urban.profile.trafficSignalsPerKm * urban.length / 1_000
            * Self.request(leave: true).cruisingSpeed
        #expect(abs(extra - (CostModel.townPenalty * urban.length + lights)) < 1e-6)
        #expect(cost(rural, leave: true) == cost(rural, leave: false))
    }

    @Test func loopsSpendLessTimeInTown() async throws {
        let gen = LoopGenerator(graph: try KnooppuntFixture.graph())
        var with = 0.0, without = 0.0
        for seed: UInt64 in 1...4 {
            with += try await gen.generate(Self.request(leave: true, seed: seed)).first!.metrics.urbanShare
            without += try await gen.generate(Self.request(leave: false, seed: seed)).first!.metrics.urbanShare
        }
        #expect(with < without, "town share with \(with / 4), without \(without / 4)")
    }

    @Test func lollipopStartsWithTheWayOutAndEndsAtTheStart() throws {
        let graph = try KnooppuntFixture.graph()
        let gen = LoopGenerator(graph: graph)
        let request = Self.request(leave: true)
        let startNode = try #require(graph.nodes.firstIndex { $0.id == KnooppuntFixture.id(3, 3) })
        let town = TownMap(graph: graph)
        let gateways = gen.gateways(from: startNode, request: request, town: town)
        #expect(!gateways.options.isEmpty)
        for o in gateways.options {
            #expect(town.nodeUrban[o.node] < 0.25, "gateways are outside town")
        }
        let g = try #require(stride(from: 0.0, to: 360, by: 45).lazy.compactMap { gateways.best(towards: $0) }.first)
        let shape = try #require(gen.candidateShapes(for: request).first)
        let route = try #require(gen.buildLoop(id: 0, shape: shape, startNode: startNode, request: request,
                                               town: town, stem: g.stem))
        #expect(Array(route.edgeIndices.prefix(g.stem.count)) == g.stem)
        #expect(graph.edges[route.edgeIndices.last!].to == startNode, "home to the start junction")
        #expect(route.knooppunten.first == route.knooppunten.last)
    }

    @Test func reverseEdgeIsTheSamePieceTheOtherWay() throws {
        let graph = try KnooppuntFixture.graph()
        for e in graph.edges {
            let r = graph.edges[graph.reverse(of: e.index)]
            #expect(r.from == e.to && r.to == e.from && r.segmentID == e.segmentID)
        }
    }

    @Test func townExitAndReturnDistances() {
        // 2 km of town, then 1.5 km of country, in a straight line.
        var b = RoadGraphBuilder()
        let origin = Coordinate(latitude: 52, longitude: 5)
        let n = [0.0, 2_000, 2_750, 3_500].enumerated().map { i, d in
            b.addNode(id: Int64(i + 1), coordinate: Geo.destination(from: origin, bearing: 90, distance: d))
        }
        b.addPath(nodeIndices: [n[0], n[1]], profile: SegmentProfile(urban: 1))
        b.addPath(nodeIndices: [n[1], n[2], n[3]], profile: SegmentProfile(urban: 0))
        let graph = b.build()
        let analyzer = RouteAnalyzer(graph: graph, request: Self.request(leave: true), weather: nil,
                                     traffic: HeuristicTrafficModel())
        let m = analyzer.metrics(for: [0, 2, 4])  // west to east
        #expect(abs(m.townExitDistance - 2_000) < 5)
        #expect(m.townReturnDistance == 0, "ends in the country")
        #expect(abs(m.urbanShare - 2_000 / 3_500) < 0.01)
    }

    @Test func sharedWayOutOfTownDoesNotCountAgainstVariety() {
        func route(_ id: Int, _ segments: Set<Int>) -> LoopRoute {
            LoopRoute(id: id, coordinates: [], segments: segments)
        }
        let way = Set(1...6)                                 // built-up way out of town
        let a = route(0, way.union([10, 11])), b = route(1, way.union([20, 21])), c = route(2, [30, 31])
        let gen = LoopGenerator(graph: RoadGraphBuilder().build())
        #expect(gen.selectDiverse([a, b, c], count: 2).map(\.id) == [0, 2])
        #expect(gen.selectDiverse([a, b, c], count: 2, ignoring: way).map(\.id) == [0, 1])
    }
}
