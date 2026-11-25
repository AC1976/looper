import Foundation
import Testing
@testable import LoopRouter

@Suite struct GeoTests {
    @Test func destinationRoundTrip() {
        let a = Coordinate(latitude: 52.37, longitude: 4.89)
        let b = Geo.destination(from: a, bearing: 45, distance: 10_000)
        #expect(abs(Geo.distance(a, b) - 10_000) < 1)
        #expect(abs(Geo.bearing(a, b) - 45) < 0.5)
    }

    @Test func headwindSign() {
        let w = WeatherConditions(time: .now, windSpeed: 5, windFromDegrees: 90) // easterly
        #expect(w.headwind(forBearing: 90) > 4.9)    // riding east = into the wind
        #expect(w.headwind(forBearing: 270) < -4.9)  // riding west = tailwind
    }
}

@Suite struct WeatherParsingTests {
    @Test func openMeteoParsing() throws {
        let json = """
        {"hourly":{"time":[1795000000,1795003600],"temperature_2m":[8.1,9.0],"precipitation":[0.0,1.2],
         "wind_speed_10m":[4.2,5.0],"wind_direction_10m":[250,260],"wind_gusts_10m":[9.0,10.1]}}
        """
        let f = try OpenMeteoWeatherProvider.parse(Data(json.utf8))[0]
        let late = f.conditions(at: Date(timeIntervalSince1970: 1_795_003_600))!
        // Precipitation is the preceding hour's sum: 1.2 mm in the hour before the second
        // sample, so both samples sit next to a 1.2 mm/h interval → rate 0.6 then 1.2.
        #expect(abs(f.samples[0].precipitationMmPerHour - 0.6) < 1e-9)
        #expect(late.isWet)
        #expect(late.windFromDegrees == 260)
        #expect(f.samples.count == 2)
    }
}

/// Requests and plans are Codable so an app can save them or send them between iPhone and Watch.
@Suite struct CodableTests {
    @Test func requestRoundTrips() throws {
        var request = KnooppuntFixture.request(climb: .targetAscent(meters: 300))
        request.windStrategy = .minimizeHeadwind
        request.rainSensitivity = .high
        let back = try JSONDecoder().decode(RideRequest.self, from: JSONEncoder().encode(request))
        #expect(back.start == request.start)
        #expect(back.targetDistance == request.targetDistance)
        #expect(back.climbPreference == request.climbPreference)
        #expect(back.windStrategy == .minimizeHeadwind)
        #expect(back.rainSensitivity == .high)
        #expect(back.departure == request.departure)
        #expect(back.seed == request.seed)
    }

    @Test func planRoundTrips() async throws {
        let planner = LoopPlanner(network: try KnooppuntFixture.network(), weather: nil)
        let plan = try await planner.plan(KnooppuntFixture.request())
        let back = try JSONDecoder().decode(LoopPlan.self, from: JSONEncoder().encode(plan))
        #expect(back.routes.map(\.knooppunten) == plan.routes.map(\.knooppunten))
        #expect(back.routes.map(\.coordinates) == plan.routes.map(\.coordinates))
        #expect(back.routes.map(\.metrics.distance) == plan.routes.map(\.metrics.distance))
        #expect(back.warnings == plan.warnings)
    }
}
