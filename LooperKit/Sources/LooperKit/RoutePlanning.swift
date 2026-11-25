import Foundation
import LoopRouter

/// Something that turns a ride request into loops. The views and `PlannerModel` only see
/// this, so planning can run on this device (`LocalRoutePlanner`) or, later, be asked of the
/// paired iPhone over WatchConnectivity, without changing any view.
public protocol RoutePlanning: Sendable {
    func plan(_ request: RideRequest) async throws -> LoopPlan
}

/// Plans on this device. Loads `network.bin` the first time it's needed and keeps it.
public actor LocalRoutePlanner: RoutePlanning {
    public let networkFile: URL
    private let weather: (any WeatherProvider)?
    private let traffic: any TrafficModel
    private var planner: LoopPlanner?

    /// `networkFile` is usually `Bundle.main.url(forResource: "network", withExtension: "bin")`.
    public init(networkFile: URL,
                weather: (any WeatherProvider)? = OpenMeteoWeatherProvider(),
                traffic: any TrafficModel = HeuristicTrafficModel()) {
        self.networkFile = networkFile
        self.weather = weather
        self.traffic = traffic
    }

    /// Loads the network now, for example at app launch, so the first plan is quicker.
    public func preload() throws {
        _ = try loadedPlanner()
    }

    public func plan(_ request: RideRequest) async throws -> LoopPlan {
        let planner = try loadedPlanner()
        try Task.checkCancellation()
        return try await planner.plan(request)
    }

    private func loadedPlanner() throws -> LoopPlanner {
        if let planner { return planner }
        let network = try KnooppuntNetwork.load(binary: networkFile)
        let made = LoopPlanner(network: network, weather: weather, traffic: traffic)
        planner = made
        return made
    }
}
