import Foundation

/// How the rider feels about climbing.
public enum ClimbPreference: Sendable, Hashable, Codable {
    case avoid
    case neutral
    case seek
    /// Aim for roughly this total ascent in metres.
    case targetAscent(meters: Double)
}

/// How the wind should shape the loop.
public enum WindStrategy: String, Sendable, Hashable, Codable, CaseIterable {
    /// Don't consider wind.
    case ignore
    /// Ride into the wind while fresh, come home with a tailwind.
    case headwindFirst
    /// Keep headwind to a minimum over the whole ride, early or late.
    case minimizeHeadwind
}

/// How much the rider minds getting wet, relative to fighting the wind.
///
/// Wind is priced in physical extra riding time (see `RiderModel`); rain is priced as
/// "discomfort seconds" per second ridden in it, scaled by this factor. So the factor
/// says how many seconds of headwind slog you'd accept to avoid a second of rain.
public enum RainSensitivity: String, Sendable, Hashable, Codable, CaseIterable {
    /// Rain only makes loose surfaces and steep descents less attractive.
    case ignore
    /// "A bit of rain is fine": wind usually wins.
    case low
    /// "Prefer to avoid rain": half a millimetre outweighs ~2 m/s of extra headwind.
    case normal
    /// "Must stay dry": rain dominates.
    case high

    public var factor: Double {
        switch self {
        case .ignore: 0
        case .low: 0.4
        case .normal: 1
        case .high: 2.5
        }
    }
}

/// How much to follow the curated long-distance cycle routes (Dutch LF routes, EuroVelo):
/// signposted, usually scenic and well surfaced. Only stretches outside town count.
public enum LongDistanceRoutes: String, Sendable, Hashable, Codable, CaseIterable {
    /// Treat them like any other route.
    case ignore
    /// Worth a small detour (the default).
    case prefer
    /// Follow them where it reasonably can: twice the pull of `prefer`.
    case follow

    /// Scales `CostModel.longDistanceBonus` and `RouteAnalyzer.longDistanceReward`.
    public var factor: Double {
        switch self {
        case .ignore: 0
        case .prefer: 1
        case .follow: 2
        }
    }
}

/// Everything the user asks for when requesting loops around their current position.
public struct RideRequest: Sendable, Codable {
    /// Point X: where the rider is now. Every loop starts and ends here.
    public var start: Coordinate
    /// Desired loop length in metres.
    public var targetDistance: Double
    /// Number of distinct loops to return.
    public var loopCount: Int
    public var climbPreference: ClimbPreference
    /// 0 = don't care about traffic, 1 = strongly prefer quiet roads / cycleways.
    public var trafficAvoidance: Double
    /// Use the forecast at all (wind strategy, rain sensitivity, wet surfaces and descents).
    public var weatherAware: Bool
    /// Only used when `weatherAware` is true.
    public var windStrategy: WindStrategy
    /// Only used when `weatherAware` is true.
    public var rainSensitivity: RainSensitivity
    public var allowUnpaved: Bool
    /// Get out of town quickly: built-up stretches and traffic lights cost extra, loops head
    /// for the countryside, and riding the same way out and back through town is fine.
    public var leaveTownQuickly: Bool
    /// How much to follow LF and EuroVelo routes outside town.
    public var longDistanceRoutes: LongDistanceRoutes
    /// Descents steeper than this (fraction, 0.12 = 12 %) are penalised; tightened when wet.
    public var maxComfortableDescentGrade: Double
    public var departure: Date
    /// Flat-road cruising speed used for timing weather and traffic along the route.
    public var cruisingSpeedKmh: Double
    /// Acceptable relative deviation from `targetDistance`.
    public var distanceTolerance: Double
    /// Seed for reproducible results.
    public var seed: UInt64

    public init(start: Coordinate,
                distanceKm: Double,
                loopCount: Int = 3,
                climbPreference: ClimbPreference = .neutral,
                trafficAvoidance: Double = 0.7,
                weatherAware: Bool = true,
                windStrategy: WindStrategy = .headwindFirst,
                rainSensitivity: RainSensitivity = .ignore,
                allowUnpaved: Bool = false,
                leaveTownQuickly: Bool = false,
                longDistanceRoutes: LongDistanceRoutes = .prefer,
                maxComfortableDescentGrade: Double = 0.12,
                departure: Date = .now,
                cruisingSpeedKmh: Double = 25,
                distanceTolerance: Double = 0.10,
                seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.start = start
        self.targetDistance = distanceKm * 1_000
        self.loopCount = max(1, loopCount)
        self.climbPreference = climbPreference
        self.trafficAvoidance = min(1, max(0, trafficAvoidance))
        self.weatherAware = weatherAware
        self.windStrategy = windStrategy
        self.rainSensitivity = rainSensitivity
        self.allowUnpaved = allowUnpaved
        self.leaveTownQuickly = leaveTownQuickly
        self.longDistanceRoutes = longDistanceRoutes
        self.maxComfortableDescentGrade = maxComfortableDescentGrade
        self.departure = departure
        self.cruisingSpeedKmh = cruisingSpeedKmh
        self.distanceTolerance = distanceTolerance
        self.seed = seed
    }

    /// Effective wind strategy (ignore when weather is off).
    public var effectiveWindStrategy: WindStrategy { weatherAware ? windStrategy : .ignore }
    /// Effective rain sensitivity (ignore when weather is off).
    public var effectiveRainSensitivity: RainSensitivity { weatherAware ? rainSensitivity : .ignore }

    /// Flat-road cruising speed in m/s.
    public var cruisingSpeed: Double { cruisingSpeedKmh / 3.6 }

    /// Clock time after riding `distance` metres with `ascent` metres of climbing.
    public func time(afterRiding distance: Double, ascent: Double) -> Date {
        departure.addingTimeInterval(estimatedDuration(distance: distance, ascent: ascent))
    }

    /// Rough ride duration in seconds: flat time plus ~2.7 s per metre climbed.
    public func estimatedDuration(distance: Double, ascent: Double) -> TimeInterval {
        distance / (cruisingSpeedKmh / 3.6) + ascent * 2.7
    }
}
