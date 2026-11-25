import Foundation

/// "Leave later and stay dry": a departure time with clearly less rain on the best loop.
public struct RainAdvice: Sendable, Codable {
    public var expectedRainMmAtDeparture: Double
    public var suggestedDeparture: Date
    public var expectedRainMmThen: Double

    public init(expectedRainMmAtDeparture: Double, suggestedDeparture: Date, expectedRainMmThen: Double) {
        self.expectedRainMmAtDeparture = expectedRainMmAtDeparture
        self.suggestedDeparture = suggestedDeparture
        self.expectedRainMmThen = expectedRainMmThen
    }
}

public struct LoopPlan: Sendable, Codable {
    public var request: RideRequest
    public var routes: [LoopRoute]
    public var weatherAtDeparture: WeatherConditions?
    /// Forecast samples at the start spanning the longest planned ride (for display).
    public var weatherDuringRide: [WeatherConditions]
    /// Set when rain sensitivity isn't `.ignore` and leaving later would be clearly drier.
    public var rainAdvice: RainAdvice?
    public var graphNodeCount: Int
    public var graphEdgeCount: Int
    public var warnings: [String]

    /// Public so apps can build sample plans (SwiftUI previews, tests).
    public init(request: RideRequest, routes: [LoopRoute],
                weatherAtDeparture: WeatherConditions? = nil, weatherDuringRide: [WeatherConditions] = [],
                rainAdvice: RainAdvice? = nil, graphNodeCount: Int = 0, graphEdgeCount: Int = 0,
                warnings: [String] = []) {
        self.request = request
        self.routes = routes
        self.weatherAtDeparture = weatherAtDeparture
        self.weatherDuringRide = weatherDuringRide
        self.rainAdvice = rainAdvice
        self.graphNodeCount = graphNodeCount
        self.graphEdgeCount = graphEdgeCount
        self.warnings = warnings
    }
}

/// High-level entry point: cut the knooppunt network around point X, fetch the
/// weather over the ride area, and generate loops.
public struct LoopPlanner: Sendable {
    public var network: KnooppuntNetwork
    public var weather: (any WeatherProvider)?
    public var traffic: any TrafficModel

    /// How far ahead to look for a drier departure.
    public static let rainAdviceHorizon: TimeInterval = 6 * 3_600
    public static let rainAdviceStep: TimeInterval = 15 * 60

    public init(network: KnooppuntNetwork,
                weather: (any WeatherProvider)? = OpenMeteoWeatherProvider(),
                traffic: any TrafficModel = HeuristicTrafficModel()) {
        self.network = network
        self.weather = weather
        self.traffic = traffic
    }

    /// Radius of network needed for a loop of the given length.
    /// The far side of a loop is at most ~D/π from the start; add margin for detours.
    public static func searchRadius(forDistance d: Double) -> Double {
        max(3_000, d / .pi * 1.15)
    }

    public func plan(_ request: RideRequest) async throws -> LoopPlan {
        var warnings: [String] = []
        let radius = Self.searchRadius(forDistance: request.targetDistance)

        var field: WeatherField?
        if request.weatherAware, let weather {
            let points = WeatherField.stationLayout(center: request.start, radius: radius)
            if let forecasts = try? await weather.forecasts(at: points), forecasts.count == points.count {
                field = WeatherField(stations: zip(points, forecasts).map { .init(coordinate: $0, forecast: $1) })
            } else {
                warnings.append("Weather unavailable; wind/rain ignored.")
            }
        }
        let expectedEnd = request.time(afterRiding: request.targetDistance * 1.15, ascent: 0)
        if let field, !field.covers(from: request.departure, to: expectedEnd) {
            warnings.append("Forecast doesn't cover the whole ride; the last known conditions are assumed.")
        }

        let graph = network.graphBuilder(around: request.start, radius: radius).build()
        let routes = try await LoopGenerator(graph: graph, traffic: traffic, weather: field).generate(request)
        if routes.count < request.loopCount {
            warnings.append("Only \(routes.count) distinct loop(s) found.")
        }

        let local = field?.forecast(near: request.start)
        let rideEnd = request.departure.addingTimeInterval(routes.map(\.metrics.estimatedDuration).max() ?? 0)
        let during = local.map { f in f.samples.filter { $0.time > request.departure && $0.time < rideEnd } } ?? []

        var advice: RainAdvice?
        if request.effectiveRainSensitivity != .ignore, let field, let best = routes.first {
            advice = Self.rainAdvice(for: best, graph: graph, request: request, field: field, traffic: traffic)
        }

        return LoopPlan(request: request, routes: routes,
                        weatherAtDeparture: local?.conditions(at: request.departure),
                        weatherDuringRide: during,
                        rainAdvice: advice,
                        graphNodeCount: graph.nodes.count, graphEdgeCount: graph.edges.count,
                        warnings: warnings)
    }

    /// Re-rides `route` at later departures (every 15 min, up to 6 h, within the
    /// forecast) and suggests the earliest one with at most a third of the rain.
    /// Only suggests when the planned departure would get at least 0.3 mm.
    static func rainAdvice(for route: LoopRoute, graph: RoadGraph, request: RideRequest,
                           field: WeatherField, traffic: any TrafficModel) -> RainAdvice? {
        func rain(departing t: Date) -> Double {
            var r = request
            r.departure = t
            return RouteAnalyzer(graph: graph, request: r, weather: field, traffic: traffic)
                .metrics(for: route.edgeIndices).expectedRainMm
        }
        let now = rain(departing: request.departure)
        guard now >= 0.3 else { return nil }
        let duration = route.metrics.estimatedDuration
        var offset = rainAdviceStep
        while offset <= rainAdviceHorizon {
            let t = request.departure.addingTimeInterval(offset)
            guard field.covers(from: t, to: t.addingTimeInterval(duration)) else { break }
            let later = rain(departing: t)
            if later <= now / 3 {
                return RainAdvice(expectedRainMmAtDeparture: now, suggestedDeparture: t, expectedRainMmThen: later)
            }
            offset += rainAdviceStep
        }
        return nil
    }
}
