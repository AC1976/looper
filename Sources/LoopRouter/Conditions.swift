import Foundation

// MARK: - Weather

public struct WeatherConditions: Sendable, Codable {
    public var time: Date
    public var temperatureC: Double
    public var precipitationMmPerHour: Double
    /// Mean wind speed at 10 m, metres per second.
    public var windSpeed: Double
    public var windGust: Double
    /// Meteorological convention: the direction the wind blows FROM (270 = westerly).
    public var windFromDegrees: Double
    /// Chance of precipitation (0...100 %), when the provider has it.
    public var precipitationProbability: Double?

    public init(time: Date, temperatureC: Double = 15, precipitationMmPerHour: Double = 0,
                windSpeed: Double = 0, windGust: Double = 0, windFromDegrees: Double = 0,
                precipitationProbability: Double? = nil) {
        self.precipitationProbability = precipitationProbability
        self.time = time
        self.temperatureC = temperatureC
        self.precipitationMmPerHour = precipitationMmPerHour
        self.windSpeed = windSpeed
        self.windGust = windGust
        self.windFromDegrees = windFromDegrees
    }

    public var isWet: Bool { precipitationMmPerHour >= 0.3 }
    /// Below ~2 m/s wind is irrelevant for routing.
    public var isWindy: Bool { windSpeed >= 2 }

    /// Headwind component (m/s) for a rider heading on `bearing`. Negative = tailwind.
    public func headwind(forBearing bearing: Double) -> Double {
        windSpeed * cos(Geo.rad(bearing - windFromDegrees))
    }
}

public struct WeatherForecast: Sendable, Codable {
    /// Samples sorted by time (15-minute and/or hourly).
    public var samples: [WeatherConditions]

    public init(samples: [WeatherConditions]) {
        self.samples = samples.sorted { $0.time < $1.time }
    }

    /// Same conditions all day; handy for tests and offline use.
    public static func constant(_ c: WeatherConditions) -> WeatherForecast {
        WeatherForecast(samples: [c])
    }

    /// Conditions at `date`, interpolated between the surrounding samples
    /// (clamped to the first/last sample outside the forecast range).
    ///
    /// Wind speed is interpolated linearly; wind direction via the wind vector, so a
    /// shift from 350° to 10° passes through north rather than south.
    public func conditions(at date: Date) -> WeatherConditions? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if samples.count == 1 || date <= first.time { return first }
        if date >= last.time { return last }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].time <= date { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let span = b.time.timeIntervalSince(a.time)
        let t = span > 0 ? date.timeIntervalSince(a.time) / span : 0
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }

        let ra = Geo.rad(a.windFromDegrees), rb = Geo.rad(b.windFromDegrees)
        let x = lerp(a.windSpeed * sin(ra), b.windSpeed * sin(rb))
        let y = lerp(a.windSpeed * cos(ra), b.windSpeed * cos(rb))
        let direction = (x == 0 && y == 0) ? lerp(a.windFromDegrees, b.windFromDegrees)
                                           : Geo.normalize(Geo.deg(atan2(x, y)))
        return WeatherConditions(time: date,
                                 temperatureC: lerp(a.temperatureC, b.temperatureC),
                                 precipitationMmPerHour: lerp(a.precipitationMmPerHour, b.precipitationMmPerHour),
                                 windSpeed: lerp(a.windSpeed, b.windSpeed),
                                 windGust: lerp(a.windGust, b.windGust),
                                 windFromDegrees: direction,
                                 precipitationProbability: b.precipitationProbability.map { pb in
                                     a.precipitationProbability.map { lerp($0, pb) } ?? pb })
    }

    /// Mean wind over `[start, end]` as (speed m/s, from-direction °), sampled every 10 minutes.
    /// Opposing winds cancel, so a wind that turns 180° mid-ride averages to (near) zero.
    public func meanWind(from start: Date, to end: Date) -> (speed: Double, fromDegrees: Double)? {
        guard !samples.isEmpty, end >= start else { return nil }
        var x = 0.0, y = 0.0, n = 0.0
        var t = start
        while t <= end {
            if let c = conditions(at: t) {
                x += c.windSpeed * sin(Geo.rad(c.windFromDegrees))
                y += c.windSpeed * cos(Geo.rad(c.windFromDegrees))
                n += 1
            }
            t = t.addingTimeInterval(600)
        }
        guard n > 0 else { return nil }
        x /= n; y /= n
        return (sqrt(x * x + y * y), Geo.normalize(Geo.deg(atan2(x, y))))
    }

    /// True when the forecast has samples covering `[start, end]`.
    public func covers(from start: Date, to end: Date) -> Bool {
        guard let first = samples.first, let last = samples.last else { return false }
        return samples.count == 1 || (first.time <= start.addingTimeInterval(3_600) && last.time >= end)
    }
}

// MARK: - Traffic

/// Expected motor-traffic level on an edge at a given time, 0 (none) to 1 (very busy).
/// Swap in a live provider (TomTom, HERE, Google) by conforming to this protocol;
/// prefetch data before routing because this is called synchronously in the hot loop.
public protocol TrafficModel: Sendable {
    func congestion(on edge: RoadEdge, at date: Date) -> Double
}

/// Estimates traffic from the segment's road-type mix and the time of day.
public struct HeuristicTrafficModel: TrafficModel {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func congestion(on edge: RoadEdge, at date: Date) -> Double {
        min(1, max(0, edge.profile.baseCongestion * timeOfDayFactor(date)))
    }

    func timeOfDayFactor(_ date: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: date)
        let weekday = cal.component(.weekday, from: date) // 1 = Sunday
        let isWeekend = weekday == 1 || weekday == 7
        switch hour {
        case 0..<6: return 0.4
        case 7..<9, 16..<19: return isWeekend ? 0.9 : 1.3
        case 22..<24: return 0.6
        default: return isWeekend ? 0.85 : 1.0
        }
    }
}
