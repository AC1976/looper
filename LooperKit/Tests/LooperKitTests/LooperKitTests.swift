import Foundation
import Testing
import LoopRouter
@testable import LooperKit

/// Planner whose behaviour each test chooses.
struct ClosurePlanner: RoutePlanning {
    let body: @Sendable (RideRequest) async throws -> LoopPlan
    func plan(_ request: RideRequest) async throws -> LoopPlan { try await body(request) }
}

@Suite struct RidePreferencesTests {
    @Test func valuesAreClampedToTheirRanges() {
        var p = RidePreferences(distanceKm: 1_000, loopCount: 0, trafficAvoidance: 2, cruisingSpeedKmh: 5)
        #expect(p.distanceKm == 200)
        #expect(p.loopCount == 1)
        #expect(p.trafficAvoidance == 1)
        #expect(p.cruisingSpeedKmh == 12)
        p.distanceKm = 3
        #expect(p.distanceKm == 10)
    }

    @Test func requestCarriesEveryChoice() {
        let p = RidePreferences(distanceKm: 70, loopCount: 2, climb: .seek, trafficAvoidance: 0.4,
                                useWeather: true, wind: .minimizeHeadwind, rain: .high,
                                allowUnpaved: true, leaveTownQuickly: false, longDistanceRoutes: .follow,
                                cruisingSpeedKmh: 28)
        let r = p.request(start: PreviewData.amsterdam, departure: PreviewData.departure, seed: 9)
        #expect(r.targetDistance == 70_000)
        #expect(r.loopCount == 2)
        #expect(r.climbPreference == .seek)
        #expect(r.trafficAvoidance == 0.4)
        #expect(r.windStrategy == .minimizeHeadwind)
        #expect(r.rainSensitivity == .high)
        #expect(r.allowUnpaved)
        #expect(!r.leaveTownQuickly)
        #expect(r.longDistanceRoutes == .follow)
        #expect(RidePreferences().longDistanceRoutes == .prefer, "prefer by default")
        #expect(RidePreferences().request(start: PreviewData.amsterdam).leaveTownQuickly, "on by default")
        #expect(r.cruisingSpeedKmh == 28)
        #expect(r.departure == PreviewData.departure)
        #expect(r.seed == 9)
    }

    @Test func userDefaultsStoreRoundTrips() throws {
        let suite = "looperkit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(store.load() == nil)
        let p = RidePreferences(distanceKm: 55, wind: .ignore, rain: .low)
        store.save(p)
        #expect(store.load() == p)
    }
}

@MainActor
@Suite struct PlannerModelTests {
    func model(_ planner: any RoutePlanning = PreviewRoutePlanner(),
               store: InMemoryPreferencesStore = InMemoryPreferencesStore()) -> PlannerModel {
        let m = PlannerModel(planner: planner, store: store)
        m.start = PreviewData.amsterdam
        return m
    }

    @Test func planningSelectsTheBestLoop() async {
        let m = model()
        await m.plan()
        #expect(m.routes.count == 3)
        #expect(m.selectedRoute?.id == m.routes.first?.id)
        #expect(m.errorMessage == nil)
        #expect(!m.isPlanning)
    }

    @Test func planUsesThePreferences() async {
        let m = model()
        m.preferences.distanceKm = 65
        m.preferences.wind = .minimizeHeadwind
        await m.plan()
        #expect(m.plan?.request.targetDistance == 65_000)
        #expect(m.plan?.request.windStrategy == .minimizeHeadwind)
    }

    @Test func needsALocation() async {
        let m = model()
        m.start = nil
        await m.plan()
        #expect(m.errorMessage == "Your location isn't known yet.")
    }

    @Test func routerErrorsBecomeMessages() async {
        let m = model(PreviewRoutePlanner(result: .failure(.noLoopsFound)))
        await m.plan()
        #expect(m.errorMessage == LoopRouterError.noLoopsFound.description)
    }

    @Test func preferencesAreLoadedAndSaved() {
        let store = InMemoryPreferencesStore(RidePreferences(distanceKm: 80))
        let m = model(store: store)
        #expect(m.preferences.distanceKm == 80)
        m.preferences.rain = .high
        #expect(store.stored?.rain == .high)
    }

    @Test func theLatestRequestWins() async {
        // The first (40 km) request is slow, the second (60 km) quick: the 60 km plan must stay.
        let planner = ClosurePlanner { request in
            if request.targetDistance == 40_000 { try await Task.sleep(for: .milliseconds(300)) }
            return LoopPlan(request: request, routes: PreviewData.plan.routes)
        }
        let m = model(planner)
        m.preferences.distanceKm = 40
        async let slow: Void = m.plan()
        try? await Task.sleep(for: .milliseconds(50))
        m.preferences.distanceKm = 60
        await m.plan()
        await slow
        #expect(m.plan?.request.targetDistance == 60_000)
    }

    @Test func cancellingReturnsToIdle() async throws {
        let m = model(PreviewRoutePlanner(delay: .seconds(5)))
        m.startPlanning()
        try await Task.sleep(for: .milliseconds(50))
        #expect(m.isPlanning)
        m.cancelPlanning()
        #expect(!m.isPlanning)
        #expect(m.plan == nil)
    }
}

/// Plans on the real `data/nl/network.bin` when it's there (run `pack-network` first).
@Suite struct LocalRoutePlannerTests {
    static let networkFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("data/nl/network.bin")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: networkFile.path)))
    func plansLoopsAroundAmsterdam() async throws {
        let planner = LocalRoutePlanner(networkFile: Self.networkFile, weather: nil)
        let request = RidePreferences(distanceKm: 40).request(start: PreviewData.amsterdam,
                                                              departure: PreviewData.departure, seed: 42)
        let plan = try await planner.plan(request)
        #expect(!plan.routes.isEmpty)
        for route in plan.routes {
            #expect(route.knooppunten.first == route.knooppunten.last)
            #expect(abs(route.metrics.distance - 40_000) < 8_000)
        }
    }

    @Test func missingNetworkFileIsAnError() async {
        let planner = LocalRoutePlanner(networkFile: URL(fileURLWithPath: "does-not-exist.bin"), weather: nil)
        await #expect(throws: (any Error).self) {
            try await planner.plan(RidePreferences().request(start: PreviewData.amsterdam))
        }
    }
}
