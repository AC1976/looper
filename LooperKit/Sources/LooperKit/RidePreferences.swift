import Foundation
import LoopRouter

/// What the rider chooses in the app (or says to an App Intent), without the parts that
/// change per ride: start position, departure time and seed. Codable, so it can be stored
/// and sent between iPhone and Watch.
public struct RidePreferences: Sendable, Codable, Equatable {
    public static let distanceRangeKm: ClosedRange<Double> = 10...200
    public static let loopCountRange: ClosedRange<Int> = 1...5
    public static let cruisingSpeedRangeKmh: ClosedRange<Double> = 12...40

    public var distanceKm: Double { didSet { distanceKm = Self.clamp(distanceKm, Self.distanceRangeKm) } }
    public var loopCount: Int { didSet { loopCount = Self.clamp(loopCount, Self.loopCountRange) } }
    public var climb: ClimbPreference
    /// 0 = don't care about traffic, 1 = strongly prefer quiet roads and bike paths.
    public var trafficAvoidance: Double { didSet { trafficAvoidance = Self.clamp(trafficAvoidance, 0...1) } }
    /// False = ignore wind and rain altogether.
    public var useWeather: Bool
    public var wind: WindStrategy
    public var rain: RainSensitivity
    public var allowUnpaved: Bool
    /// Get out of town quickly and spend as little of the ride as possible in built-up areas.
    public var leaveTownQuickly: Bool
    /// How much to follow LF and EuroVelo routes outside town.
    public var longDistanceRoutes: LongDistanceRoutes
    public var cruisingSpeedKmh: Double {
        didSet { cruisingSpeedKmh = Self.clamp(cruisingSpeedKmh, Self.cruisingSpeedRangeKmh) }
    }

    /// The app's defaults: 40 km, headwind out and tailwind home, avoid rain, leave town quickly.
    public init(distanceKm: Double = 40, loopCount: Int = 3, climb: ClimbPreference = .neutral,
                trafficAvoidance: Double = 0.7, useWeather: Bool = true,
                wind: WindStrategy = .headwindFirst, rain: RainSensitivity = .normal,
                allowUnpaved: Bool = false, leaveTownQuickly: Bool = true,
                longDistanceRoutes: LongDistanceRoutes = .prefer, cruisingSpeedKmh: Double = 25) {
        self.distanceKm = Self.clamp(distanceKm, Self.distanceRangeKm)
        self.loopCount = Self.clamp(loopCount, Self.loopCountRange)
        self.climb = climb
        self.trafficAvoidance = Self.clamp(trafficAvoidance, 0...1)
        self.useWeather = useWeather
        self.wind = wind
        self.rain = rain
        self.allowUnpaved = allowUnpaved
        self.leaveTownQuickly = leaveTownQuickly
        self.longDistanceRoutes = longDistanceRoutes
        self.cruisingSpeedKmh = Self.clamp(cruisingSpeedKmh, Self.cruisingSpeedRangeKmh)
    }

    /// The router request for a ride from `start`. `seed` nil = different loops each time.
    public func request(start: Coordinate, departure: Date = .now, seed: UInt64? = nil) -> RideRequest {
        var request = RideRequest(start: start, distanceKm: distanceKm, loopCount: loopCount,
                                  climbPreference: climb, trafficAvoidance: trafficAvoidance,
                                  weatherAware: useWeather, windStrategy: wind, rainSensitivity: rain,
                                  allowUnpaved: allowUnpaved, leaveTownQuickly: leaveTownQuickly,
                                  longDistanceRoutes: longDistanceRoutes,
                                  departure: departure,
                                  cruisingSpeedKmh: cruisingSpeedKmh)
        if let seed { request.seed = seed }
        return request
    }

    static func clamp<T: Comparable>(_ v: T, _ range: ClosedRange<T>) -> T {
        min(max(v, range.lowerBound), range.upperBound)
    }
}

/// Where preferences are kept between launches.
public protocol PreferencesStore {
    func load() -> RidePreferences?
    func save(_ preferences: RidePreferences)
}

/// Keeps preferences as JSON in `UserDefaults`. iPhone and Watch each have their own;
/// sync them over WatchConnectivity if they should match.
public struct UserDefaultsPreferencesStore: PreferencesStore {
    public let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults = .standard, key: String = "looper.ridePreferences") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> RidePreferences? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(RidePreferences.self, from: $0) }
    }

    public func save(_ preferences: RidePreferences) {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: key) }
    }
}

/// Keeps preferences in memory only; for previews and tests.
public final class InMemoryPreferencesStore: PreferencesStore {
    public private(set) var stored: RidePreferences?

    public init(_ preferences: RidePreferences? = nil) { stored = preferences }

    public func load() -> RidePreferences? { stored }
    public func save(_ preferences: RidePreferences) { stored = preferences }
}
