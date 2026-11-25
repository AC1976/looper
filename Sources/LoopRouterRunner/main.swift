import Foundation
import LoopRouter

// Ride parameters. Edit these to try a request; later they will come from App Intents.
let request = RideRequest(
    start: Coordinate(latitude: 52.3731, longitude: 4.8926),   // Amsterdam centre
    distanceKm: 130,
    loopCount: 3,
    climbPreference: .neutral,          // .avoid | .neutral | .seek | .targetAscent(meters:)
    trafficAvoidance: 0.7,              // 0...1
    weatherAware: true,                 // false = ignore wind and rain entirely
    windStrategy: .headwindFirst,       // .headwindFirst | .minimizeHeadwind | .ignore
    rainSensitivity: .normal,           // .ignore | .low | .normal | .high
    allowUnpaved: false,
    leaveTownQuickly: true,             // short way out of town; the same way back through town is fine
    longDistanceRoutes: .follow,        // LF and EuroVelo routes: .ignore | .prefer | .follow
    departure: .now,
    cruisingSpeedKmh: 25,
    seed: 42                            // fixed for reproducible results
)

// Where the dataset is read from and the results are written to.
// network.bin is made from the extractor's GeoJSON by `swift run -c release pack-network`.
let networkFile = URL(fileURLWithPath: "data/nl/network.bin")
let geoJSONOutput = URL(fileURLWithPath: "loops.geojson")
let writeGPX = true

let clock = ContinuousClock()
let started = clock.now
do {
    print("Loading knooppunt network from \(networkFile.path)…")
    let network = try KnooppuntNetwork.load(binary: networkFile)
    print("  \(network.junctions.count) knooppunten, \(network.segments.count) segments"
          + (network.hasElevation ? ", AHN junction heights" : "") + " — \(clock.now - started)")
    let planner = LoopPlanner(network: network)
    print("Planning around \(request.start)…")
    let plan = try await planner.plan(request)
    print("Graph: \(plan.graphNodeCount) nodes, \(plan.graphEdgeCount) edges — \(clock.now - started)")
    let hhmm = DateFormatter()
    hhmm.dateFormat = "HH:mm"
    if let w = plan.weatherAtDeparture {
        print("Weather at the start during the ride (wind: \(request.windStrategy.rawValue), rain: \(request.rainSensitivity.rawValue)):")
        for c in [w] + plan.weatherDuringRide {
            let chance = c.precipitationProbability.map { String(format: " (%3.0f%%)", $0) } ?? ""
            print(String(format: "  %@  wind %4.1f m/s from %3.0f°  gusts %4.1f  rain %.1f mm/h%@  %3.0f°C",
                         hhmm.string(from: c.time), c.windSpeed, c.windFromDegrees, c.windGust,
                         c.precipitationMmPerHour, chance, c.temperatureC))
        }
    }
    for w in plan.warnings { print("⚠️  \(w)") }
    print("")
    print(" #   km     ↑m    ↓m   max%   min   traffic  busy  cycle  unpaved  town  lights  open  LF/EV  out/back km  headX  >3m/s  windΔ  rain mm  effort wind/rain  score")
    for (n, r) in plan.routes.enumerated() {
        let m = r.metrics
        print(String(format: "%2d %5.1f %6.0f %5.0f %6.1f %5.0f %8.2f %5.0f%% %5.0f%% %7.0f%% %4.0f%% %7.0f %5.0f %3.0f/%2.0f%% %6.1f/%4.1f %6.1f %5.0f%% %+5.0fm %8.1f %8.0fm /%4.0fm %6.2f",
                     n + 1, m.distance / 1000, m.ascent, m.descent, m.maxGrade * 100, m.estimatedDuration / 60,
                     m.trafficExposure, m.busyRoadShare * 100, m.cyclewayShare * 100, m.unpavedShare * 100,
                     m.urbanShare * 100, m.trafficSignals, m.meanCyclability ?? 0, m.lfShare * 100, m.euroVeloShare * 100, m.townExitDistance / 1000, m.townReturnDistance / 1000,
                     m.headwindExposure, m.strongHeadwindShare * 100, m.windTimeLoss / 60,
                     m.expectedRainMm, m.windEffort / 60, m.rainEffort / 60, r.score.total))
    }
    print("  open = mean cyclability (0-100) of the ground ridden through: high = out in open space;")
    print("  LF/EV = share of the loop on a Dutch long-distance (LF) route / on a EuroVelo route;")
    print("  out/back = km ridden before leaving town / km before the end that the loop is back in town;")
    print("  headX = mean headwind (m/s); windΔ = minutes lost(+)/gained(−) to wind at constant power;")
    print("  effort = wind and rain in the same unit (effort-minutes), as weighed by windStrategy and rainSensitivity")
    if let a = plan.rainAdvice {
        print(String(format: "\n☔ Leaving at %@ instead: about %.1f mm of rain on loop 1 instead of %.1f mm.",
                     hhmm.string(from: a.suggestedDeparture), a.expectedRainMmThen, a.expectedRainMmAtDeparture))
    }
    for (n, r) in plan.routes.enumerated() where !r.knooppunten.isEmpty {
        print(String(format: "\nLoop %d  (start knooppunt %.1f km away)", n + 1, r.accessDistance / 1000))
        print("  " + r.knooppunten.joined(separator: " → "))
    }
    try plan.geoJSON().write(to: geoJSONOutput)
    print("\nWrote \(geoJSONOutput.lastPathComponent)")
    if writeGPX {
        for (n, r) in plan.routes.enumerated() {
            let f = "loop-\(n + 1).gpx"
            try r.gpx(name: "Loop \(n + 1)").write(toFile: f, atomically: true, encoding: .utf8)
            print("Wrote \(f)")
        }
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
