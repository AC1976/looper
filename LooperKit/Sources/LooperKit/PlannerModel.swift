import Foundation
import Observation
import LoopRouter

/// The app's planning state, shared by the iPhone, iPad and Watch views.
///
/// Views read `phase`, `preferences` and `selectedRoute`, and call `startPlanning()` (from a
/// button) or `plan()` (from async code such as an App Intent). The app sets `start` from
/// Core Location; this model has no location code, so it builds and tests anywhere.
@MainActor
@Observable
public final class PlannerModel {
    public enum Phase: Sendable {
        case idle
        case planning
        case planned(LoopPlan)
        case failed(String)
    }

    /// Saved to the store whenever it changes.
    public var preferences: RidePreferences {
        didSet { if preferences != oldValue { store.save(preferences) } }
    }
    /// The rider's position. Must be set before planning.
    public var start: Coordinate?
    /// Departure time; nil = now.
    public var departure: Date?
    /// Fixed seed for repeatable loops (tests, demos); nil = different loops each time.
    public var seed: UInt64?
    public private(set) var phase: Phase = .idle
    /// The loop the rider picked; set to the best loop after every plan.
    public var selectedRouteID: LoopRoute.ID?

    private let planner: any RoutePlanning
    private let store: any PreferencesStore
    private var currentTask: Task<Void, Never>?
    private var generation = 0

    public init(planner: any RoutePlanning, store: any PreferencesStore = UserDefaultsPreferencesStore()) {
        self.planner = planner
        self.store = store
        self.preferences = store.load() ?? RidePreferences()
    }

    // MARK: Reading the state

    public var plan: LoopPlan? {
        if case .planned(let plan) = phase { plan } else { nil }
    }

    public var routes: [LoopRoute] { plan?.routes ?? [] }

    public var selectedRoute: LoopRoute? {
        routes.first { $0.id == selectedRouteID } ?? routes.first
    }

    public var isPlanning: Bool {
        if case .planning = phase { true } else { false }
    }

    public var errorMessage: String? {
        if case .failed(let message) = phase { message } else { nil }
    }

    // MARK: Planning

    /// Starts planning in the background; for buttons. A new call replaces one still running.
    public func startPlanning() {
        currentTask?.cancel()
        currentTask = Task { await self.plan() }
    }

    /// Plans and waits for the result. If another plan starts meanwhile, this one's result
    /// is dropped, so the state always matches the latest request.
    public func plan() async {
        guard let start else {
            phase = .failed("Your location isn't known yet.")
            return
        }
        generation += 1
        let mine = generation
        let request = preferences.request(start: start, departure: departure ?? .now, seed: seed)
        phase = .planning
        do {
            let result = try await planner.plan(request)
            guard mine == generation, !Task.isCancelled else { return }
            phase = .planned(result)
            selectedRouteID = result.routes.first?.id
        } catch is CancellationError {
            if mine == generation { phase = .idle }
        } catch {
            guard mine == generation else { return }
            phase = .failed(String(describing: error))
        }
    }

    /// Stops a plan in progress.
    public func cancelPlanning() {
        currentTask?.cancel()
        currentTask = nil
        generation += 1
        if isPlanning { phase = .idle }
    }

    /// Back to the start screen, keeping the preferences.
    public func reset() {
        cancelPlanning()
        phase = .idle
        selectedRouteID = nil
    }
}
