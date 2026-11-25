import Foundation
import Testing
@testable import LoopRouter

@Suite struct WeatherFieldTests {
    let t0 = KnooppuntFixture.departure

    func station(_ c: Coordinate, rain: Double) -> WeatherField.Station {
        .init(coordinate: c, forecast: .constant(.init(time: t0, precipitationMmPerHour: rain, windSpeed: 4, windFromDegrees: 270)))
    }

    @Test func blendsByDistance() {
        let west = Coordinate(latitude: 52.0, longitude: 5.0)
        let east = Geo.destination(from: west, bearing: 90, distance: 10_000)
        let field = WeatherField(stations: [station(west, rain: 4), station(east, rain: 0)])
        let nearWest = Geo.destination(from: west, bearing: 90, distance: 1_000)
        let middle = Geo.destination(from: west, bearing: 90, distance: 5_000)
        #expect(field.conditions(at: t0, near: west)!.precipitationMmPerHour == 4)
        #expect(field.conditions(at: t0, near: nearWest)!.precipitationMmPerHour > 3.9)
        #expect(abs(field.conditions(at: t0, near: middle)!.precipitationMmPerHour - 2) < 1e-6)
        #expect(abs(field.conditions(at: t0, near: middle)!.windFromDegrees - 270) < 1e-6)
    }

    @Test func layoutCoversTheRideArea() {
        let c = KnooppuntFixture.center
        let points = WeatherField.stationLayout(center: c, radius: 20_000)
        #expect(points.count == 15)
        #expect(points.dropFirst().allSatisfy { abs(Geo.distance($0, c) - 10_000) < 5 || abs(Geo.distance($0, c) - 20_000) < 5 })
    }
}

@Suite struct RainRoutingTests {
    let t0 = KnooppuntFixture.departure

    func request(_ rain: RainSensitivity) -> RideRequest {
        var r = KnooppuntFixture.request(km: 20, loops: 1, seed: 13)
        r.weatherAware = true
        r.windStrategy = .ignore
        r.rainSensitivity = rain
        return r
    }

    /// Raining on the western side of the grid, dry in the east.
    @Test func avoidSteersToTheDrySide() async throws {
        let graph = try KnooppuntFixture.graph()
        func s(_ r: Int, _ c: Int, _ rain: Double) -> WeatherField.Station {
            .init(coordinate: KnooppuntFixture.coord(r, c),
                  forecast: .constant(.init(time: t0, precipitationMmPerHour: rain)))
        }
        let field = WeatherField(stations: [s(0, 0, 3), s(3, 0, 3), s(6, 0, 3), s(0, 6, 0), s(3, 6, 0), s(6, 6, 0)])
        let gen = LoopGenerator(graph: graph, weather: field)
        let dry = try await gen.generate(request(.normal))[0]
        let wet = try await gen.generate(request(.ignore))[0]
        #expect(dry.metrics.expectedRainMm < wet.metrics.expectedRainMm,
                "avoid \(dry.metrics.expectedRainMm) mm \(dry.knooppunten) vs ignore \(wet.metrics.expectedRainMm) mm")
        #expect(dry.score.rain > 0 && wet.score.rain == 0)
    }

    /// A shower over the whole area for the first hour, then dry: suggest leaving after it.
    @Test func suggestsLeavingAfterTheShower() async throws {
        let graph = try KnooppuntFixture.graph()
        let forecast = WeatherForecast(samples: [
            .init(time: t0, precipitationMmPerHour: 3),
            .init(time: t0.addingTimeInterval(55 * 60), precipitationMmPerHour: 3),
            .init(time: t0.addingTimeInterval(65 * 60), precipitationMmPerHour: 0),
            .init(time: t0.addingTimeInterval(10 * 3_600), precipitationMmPerHour: 0),
        ])
        let field = WeatherField.uniform(forecast)
        let req = request(.normal)
        let route = try await LoopGenerator(graph: graph, weather: field).generate(req)[0]
        let advice = try #require(LoopPlanner.rainAdvice(for: route, graph: graph, request: req,
                                                         field: field, traffic: HeuristicTrafficModel()))
        let wait = advice.suggestedDeparture.timeIntervalSince(t0)
        #expect(wait >= 30 * 60 && wait <= 75 * 60, "wait \(wait / 60) min")
        #expect(advice.expectedRainMmAtDeparture > 1.5)
        #expect(advice.expectedRainMmThen < advice.expectedRainMmAtDeparture / 3)
    }

    @Test func noAdviceWhenDry() async throws {
        let graph = try KnooppuntFixture.graph()
        let field = WeatherField.uniform(.constant(.init(time: t0)))
        let req = request(.normal)
        let route = try await LoopGenerator(graph: graph, weather: field).generate(req)[0]
        #expect(LoopPlanner.rainAdvice(for: route, graph: graph, request: req, field: field,
                                       traffic: HeuristicTrafficModel()) == nil)
    }
}

@Suite struct OpenMeteoMultiLocationTests {
    @Test func mergesFifteenMinuteAndHourly() throws {
        // Two locations; 15-minute data for the first half hour, hourly after.
        let loc = """
        {"minutely_15":{"time":[1795000000,1795000900,1795001800],"temperature_2m":[5,5,5],
           "precipitation":[0.0,0.5,0.25],"wind_speed_10m":[4,4,4],"wind_direction_10m":[90,90,90],
           "wind_gusts_10m":[8,8,8]},
         "hourly":{"time":[1795000000,1795003600,1795007200],"temperature_2m":[5,6,7],
           "precipitation":[0,1,0],"wind_speed_10m":[4,5,6],"wind_direction_10m":[90,90,90],
           "wind_gusts_10m":[8,9,10],"precipitation_probability":[10,70,20]}}
        """
        let forecasts = try OpenMeteoWeatherProvider.parse(Data("[\(loc),\(loc)]".utf8))
        #expect(forecasts.count == 2)
        let f = forecasts[0]
        // 3 fine samples, then the hourly samples after 1795001800.
        #expect(f.samples.map(\.time.timeIntervalSince1970) == [1795000000, 1795000900, 1795001800, 1795003600, 1795007200])
        // 0.5 mm in the 15 min before the 2nd sample = 2 mm/h; centred with the next interval (1 mm/h).
        #expect(abs(f.samples[1].precipitationMmPerHour - 1.5) < 1e-9)
        #expect(f.samples[1].precipitationProbability != nil)
    }
}
