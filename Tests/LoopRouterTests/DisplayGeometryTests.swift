import Foundation
import Testing
@testable import LoopRouter

/// Distance (m) from `p` to the polyline `line`, in a local flat projection.
private func offset(_ p: Coordinate, from line: [Coordinate]) -> Double {
    let k = Geo.metersPerDegreeLatitude, cosLat = cos(p.latitude * .pi / 180)
    func xy(_ c: Coordinate) -> (Double, Double) { ((c.longitude - p.longitude) * cosLat * k, (c.latitude - p.latitude) * k) }
    var best = Double.infinity
    for (a, b) in zip(line, line.dropFirst()) {
        let (ax, ay) = xy(a), (bx, by) = xy(b)
        let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
        let t = len2 > 0 ? min(1, max(0, -(ax * dx + ay * dy) / len2)) : 0
        let ex = ax + t * dx, ey = ay + t * dy
        best = min(best, (ex * ex + ey * ey).squareRoot())
    }
    return best
}

@Suite struct DisplayGeometryTests {
    /// A 3 km wiggly road: a point every 10 m, swinging ±40 m sideways.
    static let from = Coordinate(latitude: 52.0, longitude: 5.0)
    static let wiggly: [Coordinate] = (0...300).map { i in
        let along = Geo.destination(from: from, bearing: 90, distance: Double(i) * 10)
        return Geo.destination(from: along, bearing: 0, distance: 40 * sin(Double(i) / 8))
    }
    static var to: Coordinate { wiggly.last! }

    @Test func displayShapeFollowsTheRoadAndKeepsRoutingPoints() {
        let (display, indices) = KnooppuntNetwork.orientedPaths(lines: [Self.wiggly], from: Self.from, to: Self.to)
        let path = KnooppuntNetwork.orientedPath(lines: [Self.wiggly], from: Self.from, to: Self.to)
        #expect(indices.map { display[$0] } == path)
        #expect(display.first == Self.from && display.last == Self.to)
        #expect(path.count < 30, "routing points stay ~150 m apart")
        #expect(display.count > path.count * 2, "display keeps the bends")
        #expect(display.count < Self.wiggly.count, "display drops redundant points")
        for p in Self.wiggly {
            #expect(offset(p, from: display) <= KnooppuntNetwork.displayTolerance + 0.01)
        }
    }

    @Test func straightRoadNeedsNoExtraDisplayPoints() {
        let straight = (0...300).map { Geo.destination(from: Self.from, bearing: 90, distance: Double($0) * 10) }
        let (display, indices) = KnooppuntNetwork.orientedPaths(lines: [straight], from: Self.from, to: straight.last!)
        #expect(display.count == indices.count)
    }

    @Test func reversedInputIsOriented() {
        let (display, _) = KnooppuntNetwork.orientedPaths(lines: [Self.wiggly.reversed()], from: Self.from, to: Self.to)
        #expect(display.first == Self.from && display.last == Self.to)
        #expect(Geo.distance(display[1], Self.from) < Geo.distance(display[1], Self.to))
    }

    @Test func loopsCarryDisplayShapeAndKnooppunten() async throws {
        let net = try KnooppuntFixture.network()
        let graph = net.graphBuilder(around: KnooppuntFixture.center, radius: 20_000).build()
        let routes = try await LoopGenerator(graph: graph).generate(KnooppuntFixture.request(seed: 3))
        #expect(!routes.isEmpty)
        let byNumber = Dictionary(uniqueKeysWithValues: net.junctions.values.map { ($0.number, $0) })
        for r in routes {
            // Display shape: closed, same heights count, passes through every routing point in order.
            #expect(r.displayCoordinates.first == r.coordinates.first)
            #expect(r.displayCoordinates.last == r.coordinates.last)
            #expect(r.displayElevations.count == r.displayCoordinates.count)
            var i = r.displayCoordinates.startIndex
            for c in r.coordinates {
                while i < r.displayCoordinates.endIndex && r.displayCoordinates[i] != c { i += 1 }
                #expect(i < r.displayCoordinates.endIndex, "routing point \(c) missing from display shape")
            }
            // Knooppunten: real positions, distances rising from 0 to the loop length.
            #expect(r.junctions.map(\.number) == r.knooppunten)
            #expect(r.junctions.first?.distanceFromStart == 0)
            #expect(abs((r.junctions.last?.distanceFromStart ?? 0) - r.metrics.distance) < 1)
            #expect(zip(r.junctions, r.junctions.dropFirst()).allSatisfy { $0.distanceFromStart < $1.distanceFromStart })
            for j in r.junctions {
                #expect(byNumber[j.number]?.coordinate == j.coordinate)
                #expect(byNumber[j.number]?.id == j.junctionID)
            }
        }
    }

    @Test func gpxHasOneWaypointPerKnooppunt() async throws {
        let graph = try KnooppuntFixture.graph()
        let route = try #require(try await LoopGenerator(graph: graph).generate(KnooppuntFixture.request(seed: 3)).first)
        let gpx = route.gpx()
        let waypoints = gpx.components(separatedBy: "<wpt ").count - 1
        #expect(waypoints == Set(route.junctions.map(\.junctionID)).count)
        #expect(gpx.components(separatedBy: "<trkpt ").count - 1 == route.displayCoordinates.count)
    }
}
