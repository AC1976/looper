import Foundation
import Testing
@testable import LoopRouter

/// Area-first planning on the synthetic grid, with a cyclability grid that's open (90) east
/// of the start and built-up (10) west of it.
@Suite struct RidingAreaTests {
    static func network() throws -> KnooppuntNetwork {
        let base = try KnooppuntFixture.network()
        let centre = KnooppuntFixture.center
        var cells: [Int64: CyclabilityGrid.Cell] = [:]
        let (i0, j0) = CyclabilityGrid.index(of: Coordinate(latitude: 51.9, longitude: 4.8))
        let (i1, j1) = CyclabilityGrid.index(of: Coordinate(latitude: 52.25, longitude: 5.4))
        for i in i0...i1 {
            for j in j0...j1 {
                let open = CyclabilityGrid.centre(i, j).longitude > centre.longitude
                cells[CyclabilityGrid.key(i, j)] = .init(builtUp: open ? 0.02 : 0.8, builtUpAround: open ? 0.02 : 0.8,
                                                         networkKm: 4, quality: 0.9, trafficSignals: 0,
                                                         cyclability: open ? 90 : 10)
            }
        }
        return KnooppuntNetwork(junctions: base.junctions, segments: base.segments, cells: CyclabilityGrid(cells: cells))
    }

    static func graph() throws -> RoadGraph {
        try network().graphBuilder(around: KnooppuntFixture.center, radius: 20_000).build()
    }

    static func request(leave: Bool, seed: UInt64 = 7) -> RideRequest {
        var r = KnooppuntFixture.request(km: 24, traffic: 0, seed: seed)
        r.leaveTownQuickly = leave
        return r
    }

    @Test func edgesCarryTheirCellsCyclability() throws {
        let graph = try Self.graph()
        let centre = KnooppuntFixture.center.longitude
        for e in graph.edges {
            let lon = (graph.nodes[e.from].coordinate.longitude + graph.nodes[e.to].coordinate.longitude) / 2
            let expected = CyclabilityGrid.centre(0, Int((lon / CyclabilityGrid.cellLongitude).rounded(.down))).longitude > centre ? 0.9 : 0.1
            #expect(e.cyclability == expected)
        }
        #expect(try KnooppuntFixture.graph().edges.allSatisfy { $0.cyclability == nil }, "no grid, no value")
    }

    @Test func picksTheOpenSideInDifferentDirections() throws {
        let gen = LoopGenerator(graph: try Self.graph())
        let areas = gen.ridingAreas(from: KnooppuntFixture.center, distance: 24_000, request: Self.request(leave: true), count: 4)
        let best = try #require(areas.first)
        #expect(LoopGenerator.angle(best.bearing, 90) <= 45, "best area at \(best.bearing)°")
        for (k, a) in areas.enumerated() {
            for b in areas[(k + 1)...] { #expect(LoopGenerator.angle(a.bearing, b.bearing) >= LoopGenerator.areaSeparation) }
        }
        #expect(LoopGenerator(graph: try KnooppuntFixture.graph())
            .ridingAreas(from: KnooppuntFixture.center, distance: 24_000, request: Self.request(leave: true), count: 4).isEmpty)
    }

    @Test func closedSpaceCostsExtraOnlyWhenAsked() throws {
        let graph = try Self.graph()
        let e = try #require(graph.edges.first { $0.profile.urban == 0 && $0.cyclability == 0.1 })
        func cost(leave: Bool) -> Double {
            CostModel(request: Self.request(leave: leave), weather: nil, traffic: HeuristicTrafficModel(), climbBias: 0)
                .cost(of: e, at: graph.nodes[e.from].coordinate, travelled: 0, ascent: 0)
        }
        #expect(abs(cost(leave: true) - cost(leave: false) - CostModel.closedSpacePenalty * 0.9 * e.length) < 1e-6)
    }

    @Test func loopsRideInOpenSpace() async throws {
        let gen = LoopGenerator(graph: try Self.graph())
        var with = 0.0, without = 0.0
        for seed: UInt64 in 1...3 {
            with += try await gen.generate(Self.request(leave: true, seed: seed)).first!.metrics.meanCyclability!
            without += try await gen.generate(Self.request(leave: false, seed: seed)).first!.metrics.meanCyclability!
        }
        #expect(with > without, "open \(with / 3) vs \(without / 3)")
        #expect(with / 3 > 60)
    }

    @Test func wayHomeDoesNotRideTheCountrysideTwice() throws {
        let graph = try Self.graph()
        let gen = LoopGenerator(graph: graph)
        let request = Self.request(leave: true)
        let startNode = try #require(graph.nodes.firstIndex { $0.id == KnooppuntFixture.id(3, 3) })
        // A long way out: three segments south along column 3, to the grid's edge. Columns 2
        // and 4 run parallel to it, so there's another way home.
        let edgeNode = try #require(graph.nodes.firstIndex { $0.id == KnooppuntFixture.id(0, 3) })
        let stem = try #require(Pathfinder(graph: graph).path(from: startNode, to: edgeNode, usedSegments: [],
                                                              reusePenalty: { _ in 0 }, cost: { e, _, _ in e.length }))
        var shape = try #require(gen.candidateShapes(for: request).first)
        shape.headingDegrees = 0
        shape.radius = 2_000
        let route = try #require(gen.buildLoop(id: 0, shape: shape, startNode: startNode, request: request,
                                               town: TownMap(graph: graph), stem: stem))
        #expect(Array(route.edgeIndices.prefix(stem.count)) == stem)
        // The grid has parallel routes everywhere, so the way home shouldn't repeat the way
        // out's countryside (town may be repeated; that's free).
        var times: [Int: Int] = [:]
        for ei in route.edgeIndices { times[graph.edges[ei].segmentID, default: 0] += 1 }
        let twiceInCountry = route.edgeIndices.filter { times[graph.edges[$0].segmentID]! > 1 }
            .reduce(0.0) { $0 + graph.edges[$1].length * (1 - graph.edges[$1].profile.urban) } / 2
        let stemCountry = stem.reduce(0.0) { $0 + graph.edges[$1].length * (1 - graph.edges[$1].profile.urban) }
        #expect(stemCountry > 0)
        #expect(twiceInCountry < stemCountry, "\(twiceInCountry) m of country ridden twice, way out has \(stemCountry) m")
    }
}
