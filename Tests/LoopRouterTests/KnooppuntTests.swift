import Foundation
import Testing
@testable import LoopRouter

/// Synthetic knooppunt network in the extractor's GeoJSON format:
/// 7 × 7 junctions, 2 km apart, numbered 1…49. The middle row is a busy
/// shared road; every other segment is a separated cycleway. A 60 m hill
/// rises around junction 41 (row 5, column 5).
enum KnooppuntFixture {
    static let n = 7
    static let spacing = 2_000.0
    static let origin = Coordinate(latitude: 52.0, longitude: 5.0)

    static func coord(_ r: Int, _ c: Int) -> Coordinate {
        Geo.destination(from: Geo.destination(from: origin, bearing: 0, distance: Double(r) * spacing),
                        bearing: 90, distance: Double(c) * spacing)
    }
    static func id(_ r: Int, _ c: Int) -> Int64 { Int64(1_000 + r * n + c) }
    static func number(_ r: Int, _ c: Int) -> String { String(r * n + c + 1) }
    static var center: Coordinate { coord(n / 2, n / 2) }
    static func elevation(_ r: Int, _ c: Int) -> Double {
        60 * exp(-Double((r - 5) * (r - 5) + (c - 5) * (c - 5)) / 3)
    }
    static func elevation(number: String) -> Double {
        let i = Int(number)! - 1
        return elevation(i / n, i % n)
    }
    // Midday Wednesday, so the traffic model uses its normal factor.
    static let departure = Date(timeIntervalSince1970: 1_795_000_000)

    static func graph() throws -> RoadGraph {
        try network().graphBuilder(around: center, radius: 20_000).build()
    }

    static func request(km: Double = 20, loops: Int = 3, climb: ClimbPreference = .neutral,
                        traffic: Double = 0.7, seed: UInt64 = 7) -> RideRequest {
        RideRequest(start: center, distanceKm: km, loopCount: loops, climbPreference: climb,
                    trafficAvoidance: traffic, weatherAware: false, departure: departure, seed: seed)
    }

    static func geoJSON() throws -> (junctions: Data, segments: Data) {
        var junctions: [[String: Any]] = []
        var segments: [[String: Any]] = []
        for r in 0..<n {
            for c in 0..<n {
                let p = coord(r, c)
                junctions.append(["type": "Feature",
                                  "properties": ["junction_id": id(r, c), "number": number(r, c), "degree": 4,
                                                 "elevation_m": elevation(r, c)],
                                  "geometry": ["type": "Point", "coordinates": [p.longitude, p.latitude]]])
            }
        }
        var sid: Int64 = 1
        func addSegment(_ a: (Int, Int), _ b: (Int, Int), busy: Bool) {
            let pa = coord(a.0, a.1), pb = coord(b.0, b.1)
            // Wiggle through a midpoint so geometry has intermediate points; store it reversed
            // on odd ids to check that orientation is fixed on load.
            let mid = Geo.destination(from: pa, bearing: Geo.bearing(pa, pb), distance: spacing / 2)
            var line = [[pa.longitude, pa.latitude], [mid.longitude, mid.latitude], [pb.longitude, pb.latitude]]
            if sid % 2 == 1 { line.reverse() }
            segments.append(["type": "Feature",
                             "properties": [
                                "segment_id": sid, "ref": "\(number(a.0, a.1))-\(number(b.0, b.1))",
                                "from_junction": id(a.0, a.1), "to_junction": id(b.0, b.1),
                                "length_m": spacing * 1.1, "safety_score": busy ? 25 : 100,
                                "intra_junction_connector": false,
                                "share_separated": busy ? 0.0 : 1.0, "share_shared_road": busy ? 1.0 : 0.0,
                                // The busy middle row runs through town, with 2 traffic lights per segment.
                                "share_urban": busy ? 1.0 : 0.0, "traffic_signals": busy ? 2 : 0,
                             ] as [String: Any],
                             "geometry": ["type": "LineString", "coordinates": line]])
            sid += 1
        }
        for r in 0..<n {
            for c in 0..<n {
                if c + 1 < n { addSegment((r, c), (r, c + 1), busy: r == n / 2) }
                if r + 1 < n { addSegment((r, c), (r + 1, c), busy: false) }
            }
        }
        func fc(_ f: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": f])
        }
        return (try fc(junctions), try fc(segments))
    }

    static func network() throws -> KnooppuntNetwork {
        let (j, s) = try geoJSON()
        return try KnooppuntNetwork.load(junctions: j, segments: s)
    }
}

@Suite struct KnooppuntTests {
    @Test func loadsAndOrientsSegments() throws {
        let net = try KnooppuntFixture.network()
        #expect(net.junctions.count == 49)
        #expect(net.segments.count == 2 * 7 * 6)
        for s in net.segments {
            #expect(s.path.first == net.junctions[s.from]!.coordinate)
            #expect(s.path.last == net.junctions[s.to]!.coordinate)
            #expect(s.path.count >= 3, "intermediate points kept")
            #expect(abs(s.profile.lengthScale - 1.1) < 0.01)
        }
    }

    @Test func loopsAreJunctionSequences() async throws {
        let net = try KnooppuntFixture.network()
        let start = Geo.destination(from: KnooppuntFixture.center, bearing: 45, distance: 300) // just off junction 25
        let graph = net.graphBuilder(around: start, radius: 20_000).build()
        var req = RideRequest(start: start, distanceKm: 20, loopCount: 3, trafficAvoidance: 1,
                              weatherAware: false, departure: KnooppuntFixture.departure, seed: 3)
        req.distanceTolerance = 0.15
        let routes = try await LoopGenerator(graph: graph).generate(req)
        #expect(!routes.isEmpty)

        let byNumber = Dictionary(uniqueKeysWithValues: (0..<49).map { (String($0 + 1), (r: $0 / 7, c: $0 % 7)) })
        for r in routes {
            let seq = r.knooppunten
            #expect(seq.first == "25" && seq.last == "25", "\(seq)")
            #expect(seq.count >= 5)
            // Consecutive knooppunten are grid neighbours, i.e. real signed segments.
            for (a, b) in zip(seq, seq.dropFirst()) {
                let pa = byNumber[a]!, pb = byNumber[b]!
                #expect(abs(pa.r - pb.r) + abs(pa.c - pb.c) == 1, "\(a)→\(b)")
            }
            #expect(abs(r.accessDistance - 300) < 1)
            // Distance uses the signed length (×1.1), and the access legs are taken off the target.
            #expect(abs(r.metrics.distance - 20_000) / 20_000 < 0.25, "distance \(r.metrics.distance)")
            #expect(r.metrics.busyRoadShare < 0.15, "busy \(r.metrics.busyRoadShare)")
            #expect(r.metrics.cyclewayShare > 0.85)
        }
    }

    @Test func windShapesJunctionLoops() async throws {
        let net = try KnooppuntFixture.network()
        let graph = net.graphBuilder(around: KnooppuntFixture.center, radius: 20_000).build()
        let wind = WeatherForecast.constant(.init(time: KnooppuntFixture.departure, windSpeed: 9, windFromDegrees: 270))
        let req = RideRequest(start: KnooppuntFixture.center, distanceKm: 16, loopCount: 1,
                              weatherAware: true, departure: KnooppuntFixture.departure, seed: 5)
        let r = try await LoopGenerator(graph: graph, weather: wind).generate(req)[0]
        #expect(r.metrics.headwindFirstHalf > r.metrics.headwindSecondHalf,
                "\(r.knooppunten) first \(r.metrics.headwindFirstHalf) second \(r.metrics.headwindSecondHalf)")
    }
}

@Suite struct LoopPreferenceTests {
    @Test func closedDistinctLoops() async throws {
        let routes = try await LoopGenerator(graph: KnooppuntFixture.graph()).generate(KnooppuntFixture.request())
        #expect(routes.count == 3)
        for r in routes {
            #expect(r.coordinates.first == r.coordinates.last)
            #expect(r.metrics.reusedShare < 0.25, "reuse \(r.metrics.reusedShare)")
        }
        let a = routes[0].segments, b = routes[1].segments
        #expect(Double(a.intersection(b).count) / Double(a.union(b).count) < 0.8)
    }

    @Test func climbPreferenceChangesAscent() async throws {
        let gen = LoopGenerator(graph: try KnooppuntFixture.graph())
        let flat = try await gen.generate(KnooppuntFixture.request(climb: .avoid))
        let hilly = try await gen.generate(KnooppuntFixture.request(climb: .seek))
        #expect(hilly[0].metrics.ascent > flat[0].metrics.ascent + 20,
                "seek \(hilly[0].metrics.ascent) vs avoid \(flat[0].metrics.ascent)")
    }

    @Test func trafficAvoidanceReducesBusyRoads() async throws {
        let gen = LoopGenerator(graph: try KnooppuntFixture.graph())
        let careless = try await gen.generate(KnooppuntFixture.request(traffic: 0))
        let careful = try await gen.generate(KnooppuntFixture.request(traffic: 1))
        #expect(careful[0].metrics.busyRoadShare <= careless[0].metrics.busyRoadShare)
        #expect(careful[0].metrics.busyRoadShare < 0.15, "busy \(careful[0].metrics.busyRoadShare)")
    }

    @Test func reproducibleWithSeed() async throws {
        let gen = LoopGenerator(graph: try KnooppuntFixture.graph())
        let a = try await gen.generate(KnooppuntFixture.request(seed: 99))
        let b = try await gen.generate(KnooppuntFixture.request(seed: 99))
        #expect(a.map(\.edgeIndices) == b.map(\.edgeIndices))
    }
}

@Suite struct JunctionElevationTests {
    @Test func climbComesFromJunctionHeights() async throws {
        let net = try KnooppuntFixture.network()
        #expect(net.hasElevation)
        let graph = net.graphBuilder(around: KnooppuntFixture.center, radius: 20_000).build()
        let req = RideRequest(start: KnooppuntFixture.center, distanceKm: 20, loopCount: 3,
                              weatherAware: false, departure: KnooppuntFixture.departure, seed: 11)
        for r in try await LoopGenerator(graph: graph).generate(req) {
            // Expected ascent: sum of positive height steps between consecutive knooppunten.
            let z = KnooppuntFixture.elevation(number:)
            let expected = zip(r.knooppunten, r.knooppunten.dropFirst()).reduce(0.0) { $0 + max(0, z($1.1) - z($1.0)) }
            #expect(abs(r.metrics.ascent - expected) < 0.01, "\(r.knooppunten) ascent \(r.metrics.ascent) vs \(expected)")
            #expect(abs(r.metrics.ascent - r.metrics.descent) < 0.01, "a loop climbs what it descends")
            // Steepest neighbour step on the hill: ~28 m over a 2.2 km segment ≈ 1.3 %
            #expect(r.metrics.maxGrade < 0.014)
        }
    }
}

@Suite struct SpurTests {
    @Test func outAndBackIsRemoved() {
        // a – b – c with a dead-end spur b – d
        var builder = RoadGraphBuilder()
        let c0 = Coordinate(latitude: 52, longitude: 5)
        let a = builder.addNode(id: 1, coordinate: c0)
        let b = builder.addNode(id: 2, coordinate: Geo.destination(from: c0, bearing: 90, distance: 500))
        let c = builder.addNode(id: 3, coordinate: Geo.destination(from: c0, bearing: 90, distance: 1_000))
        let d = builder.addNode(id: 4, coordinate: Geo.destination(from: c0, bearing: 80, distance: 600))
        builder.addPath(nodeIndices: [a, b, c], profile: SegmentProfile(separated: 1))
        builder.addPath(nodeIndices: [b, d], profile: SegmentProfile(separated: 1))
        let g = builder.build()
        func edge(_ x: Int, _ y: Int) -> Int { g.edges.first { $0.from == x && $0.to == y }!.index }
        let route = [edge(a, b), edge(b, d), edge(d, b), edge(b, c)]
        let cleaned = LoopGenerator(graph: g).removeSpurs(route)
        #expect(cleaned == [edge(a, b), edge(b, c)])
    }
}
