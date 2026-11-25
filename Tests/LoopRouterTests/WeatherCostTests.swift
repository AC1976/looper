import Foundation
import Testing
@testable import LoopRouter

@Suite struct RiderPhysicsTests {
    let rider = RiderModel()
    let v0 = 25 / 3.6

    @Test func stillAirKeepsCruisingSpeed() {
        #expect(abs(rider.speed(cruising: v0, headwind: 0) - v0) < 1e-6)
    }

    @Test func headwindSlowsMoreThanTailwindHelps() {
        let into = rider.speed(cruising: v0, headwind: 5) * 3.6
        let with = rider.speed(cruising: v0, headwind: -5) * 3.6
        #expect(abs(into - 15.6) < 0.5, "5 m/s headwind at constant power: \(into) km/h")
        #expect(with > 25)
        let cost = WeatherCost(request: RideRequest(start: KnooppuntFixture.center, distanceKm: 70))
        #expect(cost.windSecondsPerMeter(headwind: 5) > -cost.windSecondsPerMeter(headwind: -5))
    }
}

@Suite struct WindRainTradeOffTests {
    func cost(_ rain: RainSensitivity) -> WeatherCost {
        WeatherCost(request: RideRequest(start: KnooppuntFixture.center, distanceKm: 70,
                                         windStrategy: .minimizeHeadwind, rainSensitivity: rain))
    }
    let t = KnooppuntFixture.departure

    /// Loop A: 70 km, dry, but 2 m/s more headwind all the way.
    func windyDry(_ c: WeatherCost) -> Double {
        c.windEffort(length: 70_000, headwind: 2, progress: 0.5)
    }
    /// Loop B: 70 km in still air, but 30 minutes in 1 mm/h rain (0.5 mm).
    func calmWet(_ c: WeatherCost) -> Double {
        c.rainEffort(length: 12_500, conditions: .init(time: t, precipitationMmPerHour: 1))
    }

    @Test func normalPrefersWindOverHalfAMillimetre() {
        let c = cost(.normal)
        #expect(calmWet(c) > windyDry(c), "rain \(calmWet(c) / 60) min vs wind \(windyDry(c) / 60) min")
    }

    @Test func lowPrefersAFewDropsOverTheWind() {
        let c = cost(.low)
        #expect(calmWet(c) < windyDry(c), "rain \(calmWet(c) / 60) min vs wind \(windyDry(c) / 60) min")
    }

    @Test func highMakesRainDominate() {
        let c = cost(.high)
        #expect(calmWet(c) > 2 * windyDry(c))
    }

    @Test func ignoreCostsNothing() {
        #expect(calmWet(cost(.ignore)) == 0)
    }

    @Test func rainCurveIsSmoothAndSaturating() {
        let f = WeatherCost.rainDiscomfort
        #expect(f(0) == 0)
        #expect(f(0.05) > 0 && f(0.05) < 0.15, "no step at a threshold")
        #expect(f(0.3) < f(1) && f(1) < f(4))
        #expect(f(8) - f(4) < f(1) - f(0.3) + 0.5, "flattens for heavy rain")
    }

    @Test func probabilityScalesRain() {
        let c = cost(.normal)
        let certain = c.rainEffort(length: 10_000, conditions: .init(time: t, precipitationMmPerHour: 1, precipitationProbability: 100))
        let unlikely = c.rainEffort(length: 10_000, conditions: .init(time: t, precipitationMmPerHour: 1, precipitationProbability: 20))
        let unknown = c.rainEffort(length: 10_000, conditions: .init(time: t, precipitationMmPerHour: 1))
        #expect(unlikely < certain)
        #expect(unknown == certain)
    }

    /// Same mixed weather on the fixture: higher rain sensitivity never rides through more rain.
    @Test func sensitivityOrdersRoutes() async throws {
        let graph = try KnooppuntFixture.graph()
        func s(_ r: Int, _ c: Int, _ rain: Double) -> WeatherField.Station {
            .init(coordinate: KnooppuntFixture.coord(r, c),
                  forecast: .constant(.init(time: t, precipitationMmPerHour: rain, windSpeed: 7, windFromDegrees: 90)))
        }
        let field = WeatherField(stations: [s(0, 0, 1.5), s(3, 0, 1.5), s(6, 0, 1.5), s(0, 6, 0), s(3, 6, 0), s(6, 6, 0)])
        func ride(_ rain: RainSensitivity) async throws -> RouteMetrics {
            var r = KnooppuntFixture.request(km: 20, loops: 1, seed: 13)
            r.weatherAware = true
            r.windStrategy = .minimizeHeadwind
            r.rainSensitivity = rain
            return try await LoopGenerator(graph: graph, weather: field).generate(r)[0].metrics
        }
        let low = try await ride(.low), normal = try await ride(.normal), high = try await ride(.high)
        #expect(high.expectedRainMm <= normal.expectedRainMm + 1e-9)
        #expect(normal.expectedRainMm <= low.expectedRainMm + 1e-9)
    }
}
