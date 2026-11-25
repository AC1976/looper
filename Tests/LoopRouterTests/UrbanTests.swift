import Foundation
import Testing
@testable import LoopRouter

/// The extractor's `share_urban` and `traffic_signals` reach the router and the loop metrics.
/// (They don't change routing yet.)
@Suite struct UrbanTests {
    @Test func segmentsCarryUrbanShareAndTrafficLights() throws {
        let net = try KnooppuntFixture.network()
        let urban = net.segments.filter { $0.profile.urban > 0 }
        #expect(urban.count == KnooppuntFixture.n - 1, "the middle row's segments")
        for s in urban {
            #expect(s.profile.urban == 1)
            // 2 lights on a 2.2 km segment.
            #expect(abs(s.profile.trafficSignalsPerKm - 2 / 2.2) < 1e-9)
        }
        #expect(net.segments.filter { $0.profile.urban == 0 }.allSatisfy { $0.profile.trafficSignalsPerKm == 0 })
    }

    @Test func survivesNetworkBin() throws {
        let net = try KnooppuntFixture.network()
        let back = try KnooppuntNetwork.load(binary: net.binaryData())
        #expect(back.segments.map(\.profile) == net.segments.map(\.profile))
    }

    @Test func loopMetricsCountTownAndLights() throws {
        let net = try KnooppuntFixture.network()
        let graph = net.graphBuilder(around: KnooppuntFixture.center, radius: 20_000).build()
        let analyzer = RouteAnalyzer(graph: graph, request: KnooppuntFixture.request(),
                                     weather: nil, traffic: HeuristicTrafficModel())
        // Ride the whole middle row west to east: all in town, 2 lights per segment.
        let row = KnooppuntFixture.n / 2
        var edges: [Int] = []
        for c in 0..<(KnooppuntFixture.n - 1) {
            let from = KnooppuntFixture.id(row, c), to = KnooppuntFixture.id(row, c + 1)
            let a = try #require(graph.nodes.firstIndex { $0.id == from })
            var node = a
            // Follow the segment's pieces until its far junction.
            while graph.nodes[node].id != to {
                let next = try #require(graph.outgoing[node].first { ei in
                    let e = graph.edges[ei]
                    return e.profile.urban == 1 && !edges.contains(ei) && graph.nodes[e.to].id != from
                        && (edges.last.map { graph.edges[$0].from != e.to } ?? true)
                })
                edges.append(next)
                node = graph.edges[next].to
            }
        }
        let m = analyzer.metrics(for: edges)
        #expect(abs(m.urbanShare - 1) < 1e-9)
        #expect(abs(m.trafficSignals - Double(2 * (KnooppuntFixture.n - 1))) < 0.01)
    }

    @Test func oldGeoJSONWithoutTheFieldsStillLoads() throws {
        let junctions = Data("""
        {"type":"FeatureCollection","features":[
         {"type":"Feature","properties":{"junction_id":1,"number":"1"},"geometry":{"type":"Point","coordinates":[5.0,52.0]}},
         {"type":"Feature","properties":{"junction_id":2,"number":"2"},"geometry":{"type":"Point","coordinates":[5.01,52.0]}}]}
        """.utf8)
        let segments = Data("""
        {"type":"FeatureCollection","features":[
         {"type":"Feature","properties":{"segment_id":7,"from_junction":1,"to_junction":2,"length_m":700},
          "geometry":{"type":"LineString","coordinates":[[5.0,52.0],[5.01,52.0]]}}]}
        """.utf8)
        let net = try KnooppuntNetwork.load(junctions: junctions, segments: segments)
        #expect(net.segments.first?.profile.urban == 0)
        #expect(net.segments.first?.profile.trafficSignalsPerKm == 0)
    }
}
