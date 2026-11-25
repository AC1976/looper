import Foundation

/// Turns an edge into a routing cost in metres-equivalent:
///
///     length × multiplier  +  cruisingSpeed × (wind effort s + rain effort s + traffic-light s)
///
/// The multiplier covers traffic, surface, gradient, descents and (with
/// `leaveTownQuickly`) built-up areas. Wind and rain are
/// priced in effort seconds by `WeatherCost` (the same function the loop scoring
/// uses) and converted to metres at cruising speed. The total is clamped to
/// `minMultiplier × length` so the A* heuristic stays admissible.
///
/// Weather is looked up where and when the rider is expected to reach the edge,
/// so a wind that turns or a shower that arrives mid-ride is priced correctly.
public struct CostModel: Sendable {
    public static let minMultiplier = 0.35
    /// Extra multiplier on a fully built-up edge with `leaveTownQuickly`: 1 km through town
    /// costs as much as 2.5 km in the country, so the router takes the short way out.
    public static let townPenalty = 1.5
    /// Effort seconds per traffic light with `leaveTownQuickly`: waiting, stopping and
    /// starting again.
    public static let trafficLightSeconds = 40.0
    /// Extra multiplier on an edge in a cell of cyclability 0 with `leaveTownQuickly`, less
    /// in better cells: within reach of the same place, take the one in open space.
    public static let closedSpacePenalty = 0.8
    /// Multiplier taken off an edge that's fully on a long-distance route (LF or EuroVelo)
    /// outside town, at `LongDistanceRoutes.prefer` (twice at `.follow`, none at `.ignore`):
    /// curated, signposted and usually scenic, so worth a small detour. In town there's no
    /// bonus: many LF routes start in city centres, and town is to be left quickly.
    public static let longDistanceBonus = 0.2

    public let request: RideRequest
    public let weather: WeatherField?
    public let traffic: any TrafficModel
    /// -1 = strongly avoid climbs, 0 = neutral, +1 = strongly seek climbs.
    public let climbBias: Double
    public let weatherCost: WeatherCost

    public init(request: RideRequest, weather: WeatherField?, traffic: any TrafficModel, climbBias: Double) {
        self.request = request
        self.weather = weather
        self.traffic = traffic
        self.climbBias = climbBias
        self.weatherCost = WeatherCost(request: request)
    }

    /// Cost of `edge` (starting at `place`) when the rider reaches it after `travelled`
    /// metres and `ascent` metres of climbing.
    public func cost(of edge: RoadEdge, at place: Coordinate, travelled: Double, ascent: Double) -> Double {
        let time = request.time(afterRiding: travelled, ascent: ascent)
        let progress = min(1, travelled / max(1, request.targetDistance))
        let wx = request.weatherAware ? weather?.conditions(at: time, near: place) : nil
        return cost(of: edge, time: time, progress: progress, weather: wx)
    }

    func cost(of edge: RoadEdge, time: Date, progress: Double, weather wx: WeatherConditions?) -> Double {
        var m = 1.0
        let wet = wx?.isWet ?? false

        // Traffic
        let congestion = traffic.congestion(on: edge, at: time)
        m += request.trafficAvoidance * 3.0 * congestion
        // Segment mix: bonus for separated paths, penalties for loose surfaces and ferries.
        let p = edge.profile
        m -= 0.25 * request.trafficAvoidance * p.separated
        m += p.surfaceUnknown * (request.allowUnpaved ? 0.05 : 0.6)
        m += p.semiPaved * ((request.allowUnpaved ? 0.15 : 1.5) + (wet ? 0.8 : 0))
        m += p.unpaved * ((request.allowUnpaved ? 0.4 : 4.0) + (wet ? 1.5 : 0))
        m += 0.8 * p.ferry // waiting for the pont
        m -= Self.longDistanceBonus * request.longDistanceRoutes.factor * p.longDistance * (1 - p.urban)
        if request.leaveTownQuickly {
            m += Self.townPenalty * p.urban
            if let c = edge.cyclability { m += Self.closedSpacePenalty * (1 - c) }
        }

        // Climbs (grade in percent)
        let up = edge.upGrade * 100
        m += 0.06 * up // baseline effort
        if climbBias < 0 {
            m += -climbBias * 0.05 * up * up            // steep climbs hurt quadratically
        } else if climbBias > 0 {
            m -= climbBias * min(0.55, 0.07 * up)       // reward climbing metres
        }

        // Descents: penalise beyond comfort; tighter in the wet.
        let down = edge.downGrade * 100
        let comfort = request.maxComfortableDescentGrade * 100 * (wet ? 0.7 : 1.0)
        if down > comfort { m += 0.3 * (down - comfort) }

        var cost = edge.length * max(Self.minMultiplier, m)
        if request.leaveTownQuickly {
            cost += Self.trafficLightSeconds * p.trafficSignalsPerKm * edge.length / 1_000 * request.cruisingSpeed
        }

        // Wind and rain, in effort seconds → metres at cruising speed.
        if let wx {
            let effort = weatherCost.windEffort(length: edge.length, headwind: wx.headwind(forBearing: edge.bearing),
                                                progress: progress)
                + weatherCost.rainEffort(length: edge.length, conditions: wx)
            cost += effort * request.cruisingSpeed
        }
        return max(Self.minMultiplier * edge.length, cost)
    }
}
