import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Weather source (swap for your own provider)

public protocol WeatherProvider: Sendable {
    /// One forecast per location, same order.
    func forecasts(at locations: [Coordinate]) async throws -> [WeatherForecast]
}

// MARK: - HTTP

enum HTTP {
    static let userAgent = "LoopRouter/0.1 (Swift; cycling loop planner)"

    static let retryableStatus: Set<Int> = [429, 502, 503, 504]

    /// GET/POST with exponential backoff on 429/5xx "server busy" responses.
    static func data(for request: URLRequest, retries: Int = 3, initialDelay: Duration = .seconds(2)) async throws -> Data {
        var req = request
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var delay = initialDelay
        for attempt in 0...retries {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else {
                return data
            }
            if retryableStatus.contains(http.statusCode) && attempt < retries {
                try await Task.sleep(for: delay)
                delay *= 2
                continue
            }
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            throw LoopRouterError.provider("HTTP \(http.statusCode) from \(req.url?.host ?? "?"): \(body)")
        }
        throw LoopRouterError.provider("unreachable")
    }
}

// MARK: - Open-Meteo

/// Open-Meteo forecast. Free, no key.
///
/// Uses the 15-minute series for the next `minutely15Hours` hours (in NL backed by
/// the high-resolution KNMI/DWD models, good for timing showers) and hourly beyond.
/// Several locations are fetched in one request.
public struct OpenMeteoWeatherProvider: WeatherProvider {
    public var endpoint = URL(string: "https://api.open-meteo.com/v1/forecast")!
    public var forecastDays = 3
    public var minutely15Hours = 8

    public init() {}

    static let variables = "temperature_2m,precipitation,wind_speed_10m,wind_direction_10m,wind_gusts_10m"

    struct Series: Decodable {
        let time: [Double]
        let temperature_2m: [Double?]
        let precipitation: [Double?]
        let wind_speed_10m: [Double?]
        let wind_direction_10m: [Double?]
        let wind_gusts_10m: [Double?]
        let precipitation_probability: [Double?]?
    }
    struct Location: Decodable {
        let hourly: Series
        let minutely_15: Series?
    }

    public func forecasts(at locations: [Coordinate]) async throws -> [WeatherForecast] {
        guard !locations.isEmpty else { return [] }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: locations.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: locations.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: Self.variables + ",precipitation_probability"),
            URLQueryItem(name: "minutely_15", value: Self.variables),
            URLQueryItem(name: "forecast_minutely_15", value: String(minutely15Hours * 4)),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
        ]
        let data = try await HTTP.data(for: URLRequest(url: comps.url!))
        let result = try Self.parse(data)
        guard result.count == locations.count else {
            throw LoopRouterError.provider("expected \(locations.count) forecasts, got \(result.count)")
        }
        return result
    }

    /// Parses a single-location object or a multi-location array.
    static func parse(_ data: Data) throws -> [WeatherForecast] {
        let decoder = JSONDecoder()
        if let many = try? decoder.decode([Location].self, from: data) { return many.map(forecast) }
        let locations = [try decoder.decode(Location.self, from: data)]
        return locations.map(forecast)
    }

    static func forecast(_ l: Location) -> WeatherForecast {
        let fine = l.minutely_15.map { samples($0, interval: 900) } ?? []
        let coarse = samples(l.hourly, interval: 3_600)
        // Probability is only hourly; attach the nearest hourly value to the fine samples.
        let hourlyProbability = WeatherForecast(samples: coarse)
        let fineWithProbability = fine.map { s -> WeatherConditions in
            var s = s
            s.precipitationProbability = hourlyProbability.conditions(at: s.time)?.precipitationProbability
            return s
        }
        let fineEnd = fine.last?.time ?? .distantPast
        return WeatherForecast(samples: fineWithProbability + coarse.filter { $0.time > fineEnd })
    }

    /// Open-Meteo precipitation is the sum over the *preceding* interval; wind and
    /// temperature are instantaneous. Convert precipitation to an mm/h rate centred on
    /// each timestamp (mean of the intervals before and after it).
    static func samples(_ s: Series, interval: TimeInterval) -> [WeatherConditions] {
        let perHour = 3_600 / interval
        let precip = s.precipitation.map { ($0 ?? 0) * perHour }
        return s.time.indices.map { i in
            let before = precip[i]
            let after = i + 1 < precip.count ? precip[i + 1] : before
            return WeatherConditions(time: Date(timeIntervalSince1970: s.time[i]),
                                     temperatureC: s.temperature_2m[safe: i] ?? 15,
                                     precipitationMmPerHour: (before + after) / 2,
                                     windSpeed: s.wind_speed_10m[safe: i] ?? 0,
                                     windGust: s.wind_gusts_10m[safe: i] ?? 0,
                                     windFromDegrees: s.wind_direction_10m[safe: i] ?? 0,
                                     precipitationProbability: s.precipitation_probability?[safe: i])
        }
    }
}

extension Array {
    subscript<T>(safe i: Int) -> T? where Element == T? {
        indices.contains(i) ? self[i] : nil
    }
}
