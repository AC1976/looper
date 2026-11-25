import Foundation

/// Weather over an area and time: point forecasts ("stations") on a grid around the
/// start, blended by inverse-distance weighting. Lets the router see that it rains in
/// the west while the east stays dry, and that a wind differs across a 70 km loop.
public struct WeatherField: Sendable {
    public struct Station: Sendable {
        public let coordinate: Coordinate
        public let forecast: WeatherForecast
        public init(coordinate: Coordinate, forecast: WeatherForecast) {
            self.coordinate = coordinate
            self.forecast = forecast
        }
    }

    public let stations: [Station]
    /// Stations blended per lookup (nearest first).
    static let neighbours = 4

    public init(stations: [Station]) {
        precondition(!stations.isEmpty, "WeatherField needs at least one station")
        self.stations = stations
    }

    /// The same forecast everywhere.
    public static func uniform(_ forecast: WeatherForecast) -> WeatherField {
        WeatherField(stations: [Station(coordinate: Coordinate(latitude: 0, longitude: 0), forecast: forecast)])
    }

    /// Station layout for a ride: the centre, a ring at half the radius and one at the
    /// full radius. 15 points ≈ 10 km apart for a 70 km loop; one Open-Meteo request.
    public static func stationLayout(center: Coordinate, radius: Double) -> [Coordinate] {
        var points = [center]
        for (ring, count) in [(0.5, 6), (1.0, 8)] {
            for k in 0..<count {
                let bearing = Double(k) * 360 / Double(count) + (ring == 1.0 ? 22.5 : 0)
                points.append(Geo.destination(from: center, bearing: bearing, distance: radius * ring))
            }
        }
        return points
    }

    /// Forecast of the station nearest to `c` (used for loop shapes and display).
    public func forecast(near c: Coordinate) -> WeatherForecast {
        stations.min { Geo.distance($0.coordinate, c) < Geo.distance($1.coordinate, c) }!.forecast
    }

    /// Conditions at `time` and place `c`: inverse-distance-squared blend of the nearest
    /// stations. Wind direction is blended as a vector.
    public func conditions(at time: Date, near c: Coordinate) -> WeatherConditions? {
        if stations.count == 1 { return stations[0].forecast.conditions(at: time) }
        let nearest = stations
            .map { (station: $0, distance: Geo.distance($0.coordinate, c)) }
            .sorted { $0.distance < $1.distance }
            .prefix(Self.neighbours)
        if let first = nearest.first, first.distance < 50 { return first.station.forecast.conditions(at: time) }

        var w = 0.0, temp = 0.0, rain = 0.0, speed = 0.0, gust = 0.0, x = 0.0, y = 0.0
        var prob = 0.0, probWeight = 0.0
        for n in nearest {
            guard let s = n.station.forecast.conditions(at: time) else { continue }
            let wi = 1 / (n.distance * n.distance)
            w += wi
            temp += wi * s.temperatureC
            rain += wi * s.precipitationMmPerHour
            speed += wi * s.windSpeed
            gust += wi * s.windGust
            x += wi * s.windSpeed * sin(Geo.rad(s.windFromDegrees))
            y += wi * s.windSpeed * cos(Geo.rad(s.windFromDegrees))
            if let p = s.precipitationProbability { prob += wi * p; probWeight += wi }
        }
        guard w > 0 else { return nil }
        return WeatherConditions(time: time, temperatureC: temp / w, precipitationMmPerHour: rain / w,
                                 windSpeed: speed / w, windGust: gust / w,
                                 windFromDegrees: Geo.normalize(Geo.deg(atan2(x, y))),
                                 precipitationProbability: probWeight > 0 ? prob / probWeight : nil)
    }

    /// True when every station's forecast covers `[start, end]`.
    public func covers(from start: Date, to end: Date) -> Bool {
        stations.allSatisfy { $0.forecast.covers(from: start, to: end) }
    }
}
