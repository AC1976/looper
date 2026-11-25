import Foundation

/// Physics of a rider on the flat, used to turn wind into extra riding time.
///
/// Power needed at ground speed v with headwind component w (m/s, negative = tailwind):
///   P = Crr·m·g·v + ½·ρ·CdA·(v + w)·|v + w|·v
/// The rider is assumed to hold the power that gives `cruisingSpeed` in still air.
public struct RiderModel: Sendable {
    public var massKg = 85.0          // rider + bike
    public var cdA = 0.40             // m², upright touring position
    public var crr = 0.005            // decent road tyres on asphalt
    public var airDensity = 1.225     // kg/m³

    public init() {}

    func power(speed v: Double, headwind w: Double) -> Double {
        let air = v + w
        return crr * massKg * 9.81 * v + 0.5 * airDensity * cdA * air * abs(air) * v
    }

    /// Ground speed at the still-air cruising power with headwind `w`.
    public func speed(cruising v0: Double, headwind w: Double) -> Double {
        let target = power(speed: v0, headwind: 0)
        var lo = 0.3, hi = 30.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if power(speed: mid, headwind: w) > target { hi = mid } else { lo = mid }
        }
        return (lo + hi) / 2
    }
}

/// Prices wind and rain in one unit: **effort seconds**, i.e. "this feels like riding
/// that many extra seconds". Shared by the router (per edge) and the scoring (per loop),
/// so both always agree on the trade-off.
public struct WeatherCost: Sendable {
    public let request: RideRequest
    public let rider: RiderModel
    /// Extra seconds per metre vs. still air, for headwind −15…+15 m/s in 0.25 steps.
    private let table: [Double]
    static let tableMin = -15.0, tableStep = 0.25, tableCount = 121

    public init(request: RideRequest, rider: RiderModel = RiderModel()) {
        self.request = request
        self.rider = rider
        let v0 = request.cruisingSpeed
        table = (0..<Self.tableCount).map { i in
            let w = Self.tableMin + Double(i) * Self.tableStep
            return 1 / rider.speed(cruising: v0, headwind: w) - 1 / v0
        }
    }

    /// Physical extra time per metre (s/m) caused by headwind `w`; negative for tailwind.
    public func windSecondsPerMeter(headwind w: Double) -> Double {
        let x = (min(max(w, Self.tableMin), -Self.tableMin) - Self.tableMin) / Self.tableStep
        let i = min(Int(x), Self.tableCount - 2)
        let t = x - Double(i)
        return table[i] * (1 - t) + table[i + 1] * t
    }

    /// Wind effort (s) for riding `length` metres with headwind `w` at ride progress 0…1,
    /// weighted by the wind strategy.
    public func windEffort(length: Double, headwind w: Double, progress: Double) -> Double {
        let seconds = windSecondsPerMeter(headwind: w) * length
        switch request.effectiveWindStrategy {
        case .ignore:
            return 0
        case .minimizeHeadwind:
            // Every second lost to headwind counts in full; time gained from a tailwind
            // only a little, so it never pays to seek headwind to "earn" tailwind.
            return seconds > 0 ? seconds : 0.2 * seconds
        case .headwindFirst:
            // Headwind is easy to bear while fresh and hard late; a tailwind is worth
            // most on the way home.
            return seconds > 0 ? seconds * (0.4 + 1.2 * progress) : seconds * (0.2 + 0.8 * progress)
        }
    }

    /// Discomfort seconds per second ridden in rain of `rate` mm/h at normal sensitivity.
    /// Smooth and saturating: 0.1 mm/h ≈ 0.2, 0.3 ≈ 0.53, 1 ≈ 1.27, 4 ≈ 2.1.
    public static func rainDiscomfort(rate: Double) -> Double {
        let r = min(max(rate, 0), 8)
        return 1.5 * (1 - exp(-r / 0.7)) + 0.15 * r
    }

    /// Rain effort (s) for riding `length` metres in conditions `wx`.
    /// When the provider gives a precipitation probability, the effort is scaled by it
    /// (with a floor, because the forecast amount itself already signals rain).
    public func rainEffort(length: Double, conditions wx: WeatherConditions) -> Double {
        let sensitivity = request.effectiveRainSensitivity.factor
        guard sensitivity > 0, wx.precipitationMmPerHour > 0 else { return 0 }
        let likelihood = wx.precipitationProbability.map { 0.3 + 0.7 * min(max($0, 0), 100) / 100 } ?? 1
        let seconds = length / request.cruisingSpeed
        return seconds * Self.rainDiscomfort(rate: wx.precipitationMmPerHour) * likelihood * sensitivity
    }
}
