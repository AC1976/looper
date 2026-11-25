import Foundation
import LoopRouter

/// Sample data for SwiftUI previews and tests: no network file, no internet.
public enum PreviewData {
    public static let amsterdam = Coordinate(latitude: 52.3731, longitude: 4.8926)
    public static let departure = Date(timeIntervalSince1970: 1_795_000_000)

    /// Three made-up loops around Amsterdam with plausible numbers.
    public static let plan: LoopPlan = {
        let request = RidePreferences(distanceKm: 40).request(start: amsterdam, departure: departure, seed: 1)
        func route(_ id: Int, km: Double, headwind: Double, rainMm: Double, cycleway: Double,
                   knooppunten: [String], bearing: Double) -> LoopRoute {
            var m = RouteMetrics()
            m.distance = km * 1_000
            m.ascent = 20
            m.descent = 20
            m.estimatedDuration = km / 25 * 3_600
            m.headwindExposure = headwind
            m.expectedRainMm = rainMm
            m.cyclewayShare = cycleway
            // A rough circle out in `bearing` and back, so maps have something to draw, with
            // the knooppunten spread evenly along it.
            let radius = km * 1_000 / (2 * .pi)
            let centre = Geo.destination(from: amsterdam, bearing: bearing, distance: radius)
            let points = (0...36).map { k in
                Geo.destination(from: centre, bearing: bearing + 180 + Double(k) * 10, distance: radius)
            }
            let junctions = knooppunten.enumerated().map { i, number in
                let k = i * 36 / (knooppunten.count - 1)
                return RouteJunction(number: number, junctionID: Int64(id * 100 + (i == knooppunten.count - 1 ? 0 : i)),
                                     coordinate: points[k], distanceFromStart: m.distance * Double(k) / 36)
            }
            return LoopRoute(id: id, coordinates: points, metrics: m, junctions: junctions, accessDistance: 900)
        }
        return LoopPlan(
            request: request,
            routes: [
                route(0, km: 41.2, headwind: 2.1, rainMm: 0, cycleway: 0.74,
                      knooppunten: ["5", "61", "46", "45", "43", "16", "81", "5"], bearing: 90),
                route(1, km: 38.6, headwind: 2.6, rainMm: 0.2, cycleway: 0.56,
                      knooppunten: ["5", "61", "60", "36", "37", "21", "56", "5"], bearing: 200),
                route(2, km: 43.9, headwind: 2.9, rainMm: 0.4, cycleway: 0.79,
                      knooppunten: ["5", "61", "60", "36", "4", "20", "52", "5"], bearing: 320),
            ],
            weatherAtDeparture: WeatherConditions(time: departure, temperatureC: 9, precipitationMmPerHour: 0,
                                                  windSpeed: 6.5, windGust: 11, windFromDegrees: 85,
                                                  precipitationProbability: 10))
    }()
}

/// A planner that returns a fixed plan (or error) after an optional delay; for previews
/// and tests.
public struct PreviewRoutePlanner: RoutePlanning {
    public var result: Result<LoopPlan, LoopRouterError>
    public var delay: Duration

    public init(result: Result<LoopPlan, LoopRouterError> = .success(PreviewData.plan), delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    public func plan(_ request: RideRequest) async throws -> LoopPlan {
        if delay > .zero { try await Task.sleep(for: delay) }
        var plan = try result.get()
        plan.request = request
        return plan
    }
}
