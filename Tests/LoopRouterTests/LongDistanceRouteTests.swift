import Foundation
import Testing
@testable import LoopRouter

/// LF and EuroVelo shares from the extractor reach the router, survive network.bin, show in
/// the loop metrics and make those stretches a little cheaper to route on.
@Suite struct LongDistanceRouteTests {
    /// Two junctions, one segment that's 60 % on an LF route and 40 % on EuroVelo.
    static func network() throws -> KnooppuntNetwork {
        let junctions = Data("""
        {"type":"FeatureCollection","features":[
         {"type":"Feature","properties":{"junction_id":1,"number":"1"},"geometry":{"type":"Point","coordinates":[3.5,51.56]}},
         {"type":"Feature","properties":{"junction_id":2,"number":"2"},"geometry":{"type":"Point","coordinates":[3.52,51.56]}}]}
        """.utf8)
        let segments = Data("""
        {"type":"FeatureCollection","features":[
         {"type":"Feature","properties":{"segment_id":7,"from_junction":1,"to_junction":2,"length_m":1400,
          "share_separated":1.0,"share_lf":0.6,"share_eurovelo":0.4},
          "geometry":{"type":"LineString","coordinates":[[3.5,51.56],[3.51,51.56],[3.52,51.56]]}}]}
        """.utf8)
        return try KnooppuntNetwork.load(junctions: junctions, segments: segments)
    }

    @Test func sharesLoadAndSurviveNetworkBin() throws {
        let net = try Self.network()
        let p = try #require(net.segments.first?.profile)
        #expect(p.lf == 0.6 && p.euroVelo == 0.4 && p.longDistance == 0.6)
        #expect(try KnooppuntNetwork.load(binary: net.binaryData()).segments.map(\.profile) == net.segments.map(\.profile))
        #expect(try KnooppuntFixture.network().segments.allSatisfy { $0.profile.longDistance == 0 }, "absent = 0")
    }

    @Test func metricsAndCost() throws {
        let graph = try Self.network().graphBuilder(around: Coordinate(latitude: 51.56, longitude: 3.51), radius: 5_000).build()
        let request = RideRequest(start: Coordinate(latitude: 51.56, longitude: 3.5), distanceKm: 3, trafficAvoidance: 0,
                                  weatherAware: false)
        let forward = graph.edges.indices.filter { $0 % 2 == 0 }  // west to east
        let m = RouteAnalyzer(graph: graph, request: request, weather: nil, traffic: HeuristicTrafficModel()).metrics(for: forward)
        #expect(abs(m.lfShare - 0.6) < 1e-9 && abs(m.euroVeloShare - 0.4) < 1e-9 && abs(m.longDistanceShare - 0.6) < 1e-9)

        let e = graph.edges[0]
        let model = CostModel(request: request, weather: nil, traffic: HeuristicTrafficModel(), climbBias: 0)
        var plain = e.profile
        plain.lf = 0
        plain.euroVelo = 0
        let without = RoadEdge(index: 0, from: e.from, to: e.to, segmentID: e.segmentID, length: e.length, bearing: e.bearing,
                               profile: plain, ascent: e.ascent, descent: e.descent, shape: e.shape, cyclability: e.cyclability)
        let saved = model.cost(of: without, at: graph.nodes[e.from].coordinate, travelled: 0, ascent: 0)
            - model.cost(of: e, at: graph.nodes[e.from].coordinate, travelled: 0, ascent: 0)
        #expect(abs(saved - CostModel.longDistanceBonus * 0.6 * e.length) < 1e-6)
    }
}

extension LongDistanceRouteTests {
    @Test func onlyOutsideTownCounts() throws {
        var p = SegmentProfile(urban: 0.75)
        p.lf = 1
        let edge = RoadEdge(index: 0, from: 0, to: 1, segmentID: 0, length: 1_000, bearing: 90, profile: p,
                            ascent: 0, descent: 0, shape: [], cyclability: nil)
        var plain = p
        plain.lf = 0
        let without = RoadEdge(index: 0, from: 0, to: 1, segmentID: 0, length: 1_000, bearing: 90, profile: plain,
                               ascent: 0, descent: 0, shape: [], cyclability: nil)
        let request = RideRequest(start: Coordinate(latitude: 52, longitude: 5), distanceKm: 3, trafficAvoidance: 0,
                                  weatherAware: false)
        let model = CostModel(request: request, weather: nil, traffic: HeuristicTrafficModel(), climbBias: 0)
        let at = Coordinate(latitude: 52, longitude: 5)
        let saved = model.cost(of: without, at: at, travelled: 0, ascent: 0) - model.cost(of: edge, at: at, travelled: 0, ascent: 0)
        #expect(abs(saved - CostModel.longDistanceBonus * 0.25 * 1_000) < 1e-6, "a quarter of the bonus: 75 % in town")
    }

    @Test func scoreRewardsLongDistanceOutsideTown() throws {
        var m = RouteMetrics()
        m.distance = 50_000
        m.longDistanceOpenShare = 0.5
        let request = RideRequest(start: Coordinate(latitude: 52, longitude: 5), distanceKm: 50, weatherAware: false)
        let s = RouteAnalyzer(graph: RoadGraphBuilder().build(), request: request, weather: nil,
                              traffic: HeuristicTrafficModel()).score(m)
        #expect(s.longDistance == -0.5 * RouteAnalyzer.longDistanceReward)
    }
}

extension LongDistanceRouteTests {
    @Test(arguments: LongDistanceRoutes.allCases)
    func settingScalesBonusAndReward(_ level: LongDistanceRoutes) throws {
        var p = SegmentProfile(urban: 0)
        p.lf = 1
        let on = RoadEdge(index: 0, from: 0, to: 1, segmentID: 0, length: 1_000, bearing: 90, profile: p,
                          ascent: 0, descent: 0, shape: [], cyclability: nil)
        let off = RoadEdge(index: 0, from: 0, to: 1, segmentID: 0, length: 1_000, bearing: 90, profile: SegmentProfile(),
                           ascent: 0, descent: 0, shape: [], cyclability: nil)
        let request = RideRequest(start: Coordinate(latitude: 52, longitude: 5), distanceKm: 50, trafficAvoidance: 0,
                                  weatherAware: false, longDistanceRoutes: level)
        let model = CostModel(request: request, weather: nil, traffic: HeuristicTrafficModel(), climbBias: 0)
        let at = Coordinate(latitude: 52, longitude: 5)
        let saved = model.cost(of: off, at: at, travelled: 0, ascent: 0) - model.cost(of: on, at: at, travelled: 0, ascent: 0)
        #expect(abs(saved - CostModel.longDistanceBonus * level.factor * 1_000) < 1e-6)

        var m = RouteMetrics()
        m.distance = 50_000
        m.longDistanceOpenShare = 0.5
        let s = RouteAnalyzer(graph: RoadGraphBuilder().build(), request: request, weather: nil,
                              traffic: HeuristicTrafficModel()).score(m)
        #expect(s.longDistance == -0.5 * RouteAnalyzer.longDistanceReward * level.factor)
    }

    @Test func preferIsTheDefaultAndFollowIsTwiceAsStrong() {
        #expect(RideRequest(start: Coordinate(latitude: 52, longitude: 5), distanceKm: 50).longDistanceRoutes == .prefer)
        #expect(LongDistanceRoutes.ignore.factor == 0 && LongDistanceRoutes.follow.factor == 2 * LongDistanceRoutes.prefer.factor)
    }
}

extension LongDistanceRouteTests {
    @Test func followMapsRoutesOutsideTown() {
        // Three pieces in a row: on an LF route in the country, on one in town, off-route.
        var b = RoadGraphBuilder()
        let origin = Coordinate(latitude: 52, longitude: 5)
        let n = (0..<4).map { b.addNode(id: Int64($0 + 1), coordinate: Geo.destination(from: origin, bearing: 90, distance: Double($0) * 1_000)) }
        var country = SegmentProfile(), town = SegmentProfile(urban: 1)
        country.lf = 1
        town.lf = 1
        b.addPath(nodeIndices: [n[0], n[1]], profile: country)
        b.addPath(nodeIndices: [n[1], n[2]], profile: town)
        b.addPath(nodeIndices: [n[2], n[3]], profile: SegmentProfile())
        let map = LongDistanceMap(graph: b.build())
        #expect(map.onRoute == [true, true, false, false])
        #expect(abs(map.km(around: Geo.destination(from: origin, bearing: 90, distance: 1_500), radius: 5_000) - 1) < 0.01,
                "only the country kilometre counts")
    }
}
