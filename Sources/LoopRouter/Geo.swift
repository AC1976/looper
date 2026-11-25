import Foundation

/// A WGS-84 coordinate in decimal degrees.
public struct Coordinate: Sendable, Hashable, Codable, CustomStringConvertible {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var description: String {
        String(format: "%.5f,%.5f", latitude, longitude)
    }
}

/// Spherical-earth geodesy helpers. Accurate to well under 0.5 % at cycling scales.
public enum Geo {
    public static let earthRadius = 6_371_008.8
    public static let metersPerDegreeLatitude = 111_320.0

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let phi1 = rad(a.latitude), phi2 = rad(b.latitude)
        let dPhi = phi2 - phi1
        let dLambda = rad(b.longitude - a.longitude)
        let h = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north in [0, 360).
    public static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let phi1 = rad(a.latitude), phi2 = rad(b.latitude)
        let dLambda = rad(b.longitude - a.longitude)
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        return normalize(deg(atan2(y, x)))
    }

    /// Point reached by travelling `distance` metres from `origin` on `bearing`.
    public static func destination(from origin: Coordinate, bearing: Double, distance: Double) -> Coordinate {
        let delta = distance / earthRadius
        let theta = rad(bearing)
        let phi1 = rad(origin.latitude), lambda1 = rad(origin.longitude)
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1),
                                      cos(delta) - sin(phi1) * sin(phi2))
        let lon = (deg(lambda2) + 540).truncatingRemainder(dividingBy: 360) - 180
        return Coordinate(latitude: deg(phi2), longitude: lon)
    }

    /// Normalises an angle to [0, 360).
    public static func normalize(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

/// Small, fast, seedable RNG so loop generation is reproducible.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
