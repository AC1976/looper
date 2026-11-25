import Foundation
import Testing
@testable import LoopRouter

@Suite struct ForecastInterpolationTests {
    let t0 = KnooppuntFixture.departure

    @Test func directionTurnsTheShortWay() {
        let f = WeatherForecast(samples: [
            .init(time: t0, windSpeed: 4, windFromDegrees: 350),
            .init(time: t0.addingTimeInterval(3_600), windSpeed: 8, windFromDegrees: 10),
        ])
        let mid = f.conditions(at: t0.addingTimeInterval(1_800))!
        #expect(abs(mid.windSpeed - 6) < 1e-9)
        #expect(mid.windFromDegrees < 5 || mid.windFromDegrees > 355, "\(mid.windFromDegrees)") // via north
    }

    @Test func clampsOutsideRangeAndReportsCoverage() {
        let f = WeatherForecast(samples: [
            .init(time: t0, windSpeed: 3, windFromDegrees: 90),
            .init(time: t0.addingTimeInterval(3_600), windSpeed: 5, windFromDegrees: 90),
        ])
        #expect(f.conditions(at: t0.addingTimeInterval(-600))!.windSpeed == 3)
        #expect(f.conditions(at: t0.addingTimeInterval(9_000))!.windSpeed == 5)
        #expect(f.covers(from: t0, to: t0.addingTimeInterval(3_000)))
        #expect(!f.covers(from: t0, to: t0.addingTimeInterval(7_200)))
    }

    @Test func opposingWindsAverageOut() {
        let f = WeatherForecast(samples: [
            .init(time: t0, windSpeed: 6, windFromDegrees: 270),
            .init(time: t0.addingTimeInterval(1_800), windSpeed: 6, windFromDegrees: 270),
            .init(time: t0.addingTimeInterval(1_801), windSpeed: 6, windFromDegrees: 90),
            .init(time: t0.addingTimeInterval(3_600), windSpeed: 6, windFromDegrees: 90),
        ])
        #expect(f.meanWind(from: t0, to: t0.addingTimeInterval(1_800))!.fromDegrees == 270)
        #expect(f.meanWind(from: t0, to: t0.addingTimeInterval(3_600))!.speed < 1)
    }
}

@Suite struct WindStrategyTests {
    func request(_ strategy: WindStrategy, seed: UInt64 = 21) -> RideRequest {
        var r = KnooppuntFixture.request(km: 20, loops: 1, seed: seed)
        r.weatherAware = true
        r.windStrategy = strategy
        return r
    }

    @Test func minimizeHeadwindBeatsOtherStrategies() async throws {
        let graph = try KnooppuntFixture.graph()
        let wind = WeatherForecast.constant(.init(time: KnooppuntFixture.departure, windSpeed: 8, windFromDegrees: 270))
        let gen = LoopGenerator(graph: graph, weather: wind)
        // Judge every loop by the same yardstick: headwind exposure under this wind.
        let judge = RouteAnalyzer(graph: graph, request: request(.minimizeHeadwind), weather: .uniform(wind),
                                  traffic: HeuristicTrafficModel())
        func exposure(_ s: WindStrategy) async throws -> Double {
            let r = try await gen.generate(request(s))[0]
            return judge.metrics(for: r.edgeIndices).headwindExposure
        }
        let minimize = try await exposure(.minimizeHeadwind)
        let first = try await exposure(.headwindFirst)
        let ignore = try await exposure(.ignore)
        #expect(minimize < first, "minimize \(minimize) vs headwindFirst \(first)")
        #expect(minimize <= ignore, "minimize \(minimize) vs ignore \(ignore)")
    }

    /// Wind from the west for the first ~half of a 48-minute ride, then from the east.
    /// Planning with the full forecast should beat planning with the departure wind only.
    @Test func plansForWindThatTurnsMidRide() async throws {
        let graph = try KnooppuntFixture.graph()
        let t0 = KnooppuntFixture.departure
        let turning = WeatherForecast(samples: [
            .init(time: t0, windSpeed: 8, windFromDegrees: 270),
            .init(time: t0.addingTimeInterval(22 * 60), windSpeed: 8, windFromDegrees: 270),
            .init(time: t0.addingTimeInterval(26 * 60), windSpeed: 8, windFromDegrees: 90),
            .init(time: t0.addingTimeInterval(3 * 3_600), windSpeed: 8, windFromDegrees: 90),
        ])
        let departureOnly = WeatherForecast.constant(turning.samples[0])
        let req = request(.minimizeHeadwind)

        let aware = try await LoopGenerator(graph: graph, weather: turning).generate(req)[0]
        let naive = try await LoopGenerator(graph: graph, weather: departureOnly).generate(req)[0]
        let judge = RouteAnalyzer(graph: graph, request: req, weather: .uniform(turning), traffic: HeuristicTrafficModel())
        let awareM = judge.metrics(for: aware.edgeIndices)
        let naiveM = judge.metrics(for: naive.edgeIndices)

        #expect(awareM.headwindExposure < naiveM.headwindExposure,
                "aware \(awareM.headwindExposure) \(aware.knooppunten) vs naive \(naiveM.headwindExposure) \(naive.knooppunten)")
        // Out east with the westerly behind, home west with the easterly behind.
        #expect(awareM.headwindFirstHalf < 0 && awareM.headwindSecondHalf < 0,
                "first \(awareM.headwindFirstHalf) second \(awareM.headwindSecondHalf) \(aware.knooppunten)")
    }

    @Test func ignoreStrategyDropsWindFromScore() async throws {
        let graph = try KnooppuntFixture.graph()
        let wind = WeatherForecast.constant(.init(time: KnooppuntFixture.departure, windSpeed: 8, windFromDegrees: 270))
        let r = try await LoopGenerator(graph: graph, weather: wind).generate(request(.ignore))[0]
        #expect(r.score.wind == 0)
        #expect(r.metrics.headwindExposure > 0, "metrics still report the wind")
    }
}
