import Foundation

public struct RouteMetrics: Sendable, Codable {
    public var distance: Double = 0            // m
    public var ascent: Double = 0              // m
    public var descent: Double = 0             // m
    public var maxGrade: Double = 0            // fraction
    public var maxDescentGrade: Double = 0     // fraction, positive
    public var estimatedDuration: TimeInterval = 0
    /// Length-weighted mean congestion, 0...1.
    public var trafficExposure: Double = 0
    /// Share of distance on shared roads without a bike facility (extractor label `shared_road`).
    public var busyRoadShare: Double = 0
    /// Share of distance on separated cycleways and cycle tracks.
    public var cyclewayShare: Double = 0
    /// Share of distance in built-up areas (towns and villages).
    public var urbanShare: Double = 0
    /// Expected number of traffic-light intersections on the loop.
    public var trafficSignals: Double = 0
    /// Distance ridden from the start knooppunt until the loop first leaves town: the start
    /// of the first stretch of at least 1 km mostly outside built-up areas. 0 when the start
    /// is already outside town; the whole distance when the loop never leaves.
    public var townExitDistance: Double = 0
    /// The same, counted backwards from the finish: how far before the end the loop is back
    /// in town.
    public var townReturnDistance: Double = 0
    /// Length-weighted cyclability (0…100) of the cells ridden through; nil without a grid.
    public var meanCyclability: Double?
    /// Share of distance on a long-distance route: LF, EuroVelo, and either.
    public var lfShare: Double = 0
    public var euroVeloShare: Double = 0
    public var longDistanceShare: Double = 0
    /// Share of distance on a long-distance route outside town (what the score rewards).
    public var longDistanceOpenShare: Double = 0
    public var unpavedShare: Double = 0
    public var steepDescentShare: Double = 0
    /// Mean headwind (m/s) in the first and second half; negative = tailwind.
    public var headwindFirstHalf: Double = 0
    public var headwindSecondHalf: Double = 0
    /// Length-weighted mean of headwind only (tailwind counts as 0), m/s.
    public var headwindExposure: Double = 0
    /// Share of distance with a headwind component above 3 m/s.
    public var strongHeadwindShare: Double = 0
    /// Share of distance ridden while the forecast says it rains (≥ 0.3 mm/h).
    public var wetShare: Double = 0
    /// Rain you'd ride through: Σ forecast rate (mm/h) × time on each edge (h), in mm.
    public var expectedRainMm: Double = 0
    /// Physical time lost (+) or gained (−) to wind vs. still air, seconds (constant power).
    public var windTimeLoss: TimeInterval = 0
    /// Wind effort as weighted by the wind strategy, effort seconds.
    public var windEffort: TimeInterval = 0
    /// Rain effort as weighted by the rain sensitivity, effort seconds.
    public var rainEffort: TimeInterval = 0
    /// Share of distance ridden on a segment more than once (out-and-back).
    public var reusedShare: Double = 0

    public init() {}
}

/// Lower is better. Each term is roughly "1.0 = notably bad".
public struct ScoreBreakdown: Sendable, Codable {
    public var distance = 0.0
    public var traffic = 0.0
    public var climb = 0.0
    public var wind = 0.0
    public var surface = 0.0
    public var descents = 0.0
    public var overlap = 0.0
    public var rain = 0.0
    /// Time in town and at traffic lights, with `leaveTownQuickly`.
    public var town = 0.0
    /// A reward (≤ 0) for riding on long-distance routes (LF, EuroVelo).
    public var longDistance = 0.0
    public var total: Double {
        distance + traffic + climb + wind + surface + descents + overlap + rain + town + longDistance
    }

    public init() {}
}

/// How a candidate was constructed; useful for debugging and tuning.
public struct LoopShape: Sendable, Codable {
    public var sides: Int
    public var headingDegrees: Double
    public var clockwise: Bool
    public var climbBias: Double
    public var radius: Double
    /// Stretch along the heading axis (1 = regular polygon, 2 = twice as long as wide).
    public var elongation: Double = 1

    public init(sides: Int, headingDegrees: Double, clockwise: Bool, climbBias: Double, radius: Double,
                elongation: Double = 1) {
        self.sides = sides
        self.headingDegrees = headingDegrees
        self.clockwise = clockwise
        self.climbBias = climbBias
        self.radius = radius
        self.elongation = elongation
    }
}

/// A knooppunt passed on a loop, for map badges and "next knooppunt" displays.
public struct RouteJunction: Sendable, Hashable, Codable {
    /// The number on the signs. Numbers repeat between regions; use `junctionID` or
    /// `coordinate` to tell them apart.
    public var number: String
    /// `junction_id` from the dataset; stable across devices and app runs.
    public var junctionID: Int64
    public var coordinate: Coordinate
    /// Distance ridden from the start knooppunt to here, in metres (same measure as
    /// `RouteMetrics.distance`).
    public var distanceFromStart: Double

    public init(number: String, junctionID: Int64, coordinate: Coordinate, distanceFromStart: Double) {
        self.number = number
        self.junctionID = junctionID
        self.coordinate = coordinate
        self.distanceFromStart = distanceFromStart
    }
}

/// A planned loop. Codable so it can be saved or sent to another device; there, use
/// `displayCoordinates`, `junctions` and `metrics`. `edgeIndices` and `segments` refer to
/// the `RoadGraph` the loop was planned on and mean nothing outside it.
public struct LoopRoute: Sendable, Identifiable, Codable {
    public var id: Int
    public var edgeIndices: [Int]
    /// Routing points, about 150 m apart: enough for analysis, too coarse to draw at street level.
    public var coordinates: [Coordinate]
    public var elevations: [Double]
    /// The loop's full shape, accurate to a few metres, for maps, GPX and GeoJSON. Starts and
    /// ends at the start knooppunt and passes through every point of `coordinates`.
    public var displayCoordinates: [Coordinate]
    /// Heights for `displayCoordinates`, interpolated between the routing points.
    public var displayElevations: [Double]
    public var metrics: RouteMetrics
    public var score: ScoreBreakdown
    public var shape: LoopShape
    /// Undirected segments used; for diversity checks.
    public var segments: Set<Int>
    /// Knooppunten in riding order with their positions, start knooppunt repeated at the end.
    public var junctions: [RouteJunction]
    /// Straight-line distance from the rider to the start junction (not in `metrics.distance`).
    public var accessDistance: Double = 0

    /// Signposted junction numbers in riding order, start junction repeated at the end.
    public var knooppunten: [String] { junctions.map(\.number) }

    /// Public so apps can build sample routes (SwiftUI previews, tests). The graph-specific
    /// fields default to empty, and the display shape to the routing points.
    public init(id: Int, edgeIndices: [Int] = [], coordinates: [Coordinate], elevations: [Double] = [],
                displayCoordinates: [Coordinate]? = nil, displayElevations: [Double]? = nil,
                metrics: RouteMetrics = RouteMetrics(), score: ScoreBreakdown = ScoreBreakdown(),
                shape: LoopShape = LoopShape(sides: 0, headingDegrees: 0, clockwise: true, climbBias: 0, radius: 0),
                segments: Set<Int> = [], junctions: [RouteJunction] = [], accessDistance: Double = 0) {
        self.id = id
        self.edgeIndices = edgeIndices
        self.coordinates = coordinates
        self.elevations = elevations
        self.displayCoordinates = displayCoordinates ?? coordinates
        self.displayElevations = displayElevations ?? (displayCoordinates == nil ? elevations : [])
        self.metrics = metrics
        self.score = score
        self.shape = shape
        self.segments = segments
        self.junctions = junctions
        self.accessDistance = accessDistance
    }
}

/// Computes metrics and score for a finished loop.
struct RouteAnalyzer {
    let graph: RoadGraph
    let request: RideRequest
    let weather: WeatherField?
    let traffic: any TrafficModel
    let weatherCost: WeatherCost

    init(graph: RoadGraph, request: RideRequest, weather: WeatherField?, traffic: any TrafficModel) {
        self.graph = graph
        self.request = request
        self.weather = weather
        self.traffic = traffic
        self.weatherCost = WeatherCost(request: request)
    }

    func metrics(for edges: [Int]) -> RouteMetrics {
        var m = RouteMetrics()
        let total = edges.reduce(0.0) { $0 + graph.edges[$1].length }
        guard total > 0 else { return m }
        m.distance = total
        var cum = 0.0, climbed = 0.0
        var seen = Set<Int>()
        var headFirst = 0.0, headSecond = 0.0, lenFirst = 0.0, lenSecond = 0.0
        var cyclable = 0.0, cyclableLength = 0.0
        for ei in edges {
            let e = graph.edges[ei]
            let mid = (cum + e.length / 2) / total
            // Same clock as the cost model: time at which the rider reaches this edge.
            let t = request.time(afterRiding: cum + e.length / 2, ascent: climbed)
            climbed += e.ascent
            m.ascent += e.ascent
            m.descent += e.descent
            m.maxGrade = max(m.maxGrade, e.upGrade)
            m.maxDescentGrade = max(m.maxDescentGrade, e.downGrade)
            let c = traffic.congestion(on: e, at: t)
            m.trafficExposure += c * e.length
            m.busyRoadShare += e.profile.sharedRoad * e.length
            m.cyclewayShare += e.profile.separated * e.length
            m.urbanShare += e.profile.urban * e.length
            m.lfShare += e.profile.lf * e.length
            m.euroVeloShare += e.profile.euroVelo * e.length
            m.longDistanceShare += e.profile.longDistance * e.length
            m.longDistanceOpenShare += e.profile.longDistance * (1 - e.profile.urban) * e.length
            m.trafficSignals += e.profile.trafficSignalsPerKm * e.length / 1_000
            if let c = e.cyclability { cyclable += c * e.length; cyclableLength += e.length }
            m.unpavedShare += (e.profile.semiPaved + e.profile.unpaved) * e.length
            let wx = request.weatherAware ? weather?.conditions(at: t, near: graph.nodes[e.from].coordinate) : nil
            let comfort = request.maxComfortableDescentGrade * ((wx?.isWet ?? false) ? 0.7 : 1)
            if e.downGrade > comfort { m.steepDescentShare += e.length }
            // With leaveTownQuickly, the same way out and back through town isn't overlap.
            if !seen.insert(e.segmentID).inserted {
                m.reusedShare += e.length * (request.leaveTownQuickly ? 1 - e.profile.urban : 1)
            }
            if let wx {
                let head = wx.headwind(forBearing: e.bearing)
                let h = head * e.length
                if mid < 0.5 { headFirst += h; lenFirst += e.length } else { headSecond += h; lenSecond += e.length }
                m.headwindExposure += max(0, head) * e.length
                if head > 3 { m.strongHeadwindShare += e.length }
                if wx.isWet { m.wetShare += e.length }
                m.expectedRainMm += wx.precipitationMmPerHour * e.length / (request.cruisingSpeedKmh * 1_000)
                m.windTimeLoss += weatherCost.windSecondsPerMeter(headwind: head) * e.length
                m.windEffort += weatherCost.windEffort(length: e.length, headwind: head,
                                                       progress: min(1, cum / max(1, request.targetDistance)))
                m.rainEffort += weatherCost.rainEffort(length: e.length, conditions: wx)
            }
            cum += e.length
        }
        m.trafficExposure /= total
        m.busyRoadShare /= total
        m.cyclewayShare /= total
        m.urbanShare /= total
        m.lfShare /= total
        m.euroVeloShare /= total
        m.longDistanceShare /= total
        m.longDistanceOpenShare /= total
        m.unpavedShare /= total
        m.steepDescentShare /= total
        m.reusedShare /= total
        m.headwindExposure /= total
        m.strongHeadwindShare /= total
        m.wetShare /= total
        m.estimatedDuration = request.estimatedDuration(distance: total, ascent: m.ascent)
        m.meanCyclability = cyclableLength > 0 ? 100 * cyclable / cyclableLength : nil
        m.townExitDistance = townExit(edges)
        m.townReturnDistance = townExit(edges.reversed())
        m.headwindFirstHalf = lenFirst > 0 ? headFirst / lenFirst : 0
        m.headwindSecondHalf = lenSecond > 0 ? headSecond / lenSecond : 0
        return m
    }

    /// Score points for a loop fully on long-distance routes (LF, EuroVelo) outside town, at
    /// `LongDistanceRoutes.prefer` (twice at `.follow`, none at `.ignore`).
    static let longDistanceReward = 1.0

    /// Distance until the first stretch of at least `ruralStretch` metres mostly outside town.
    static let ruralStretch = 1_000.0
    func townExit(_ edges: [Int]) -> Double {
        var distance = 0.0, run = 0.0
        var runStart: Double?
        for ei in edges {
            let e = graph.edges[ei]
            if e.profile.urban < 0.5 {
                if runStart == nil { runStart = distance; run = 0 }
                run += e.length
                if run >= Self.ruralStretch, let runStart { return runStart }
            } else {
                runStart = nil
            }
            distance += e.length
        }
        return distance
    }

    func score(_ m: RouteMetrics) -> ScoreBreakdown {
        var s = ScoreBreakdown()
        let target = request.targetDistance
        let dev = abs(m.distance - target) / target
        s.distance = 3 * dev + (dev > request.distanceTolerance ? 4 * (dev - request.distanceTolerance) : 0)
        s.traffic = 2.5 * request.trafficAvoidance * m.trafficExposure

        let perKm = m.ascent / max(1, m.distance / 1_000) // m of climbing per km
        switch request.climbPreference {
        case .avoid: s.climb = perKm / 10
        case .neutral: s.climb = 0
        case .seek: s.climb = -min(perKm, 40) / 12
        case .targetAscent(let goal): s.climb = 2 * abs(m.ascent - goal) / max(goal, 100)
        }

        // Wind and rain share one unit: effort seconds, relative to the still-air ride
        // time. 10 % extra effort ≈ 0.3 points, the same as a 10 % distance miss.
        let baseDuration = max(1, m.distance / request.cruisingSpeed)
        s.wind = 3 * m.windEffort / baseDuration
        s.rain = 3 * m.rainEffort / baseDuration
        // Loose surfaces are worse in the wet; wetShare is 0 when weather is off.
        s.surface = m.unpavedShare * (request.allowUnpaved ? 0.3 : 3) * (1 + m.wetShare)
        s.descents = 2 * m.steepDescentShare
        s.overlap = 4 * m.reusedShare
        // Curated long-distance routes outside town: a loop fully on them ≈ 1 point better,
        // about as much as a 33 % distance miss or 33 % more headwind effort.
        s.longDistance = -RouteAnalyzer.longDistanceReward * request.longDistanceRoutes.factor * m.longDistanceOpenShare
        // Leave town quickly: traffic lights as effort seconds, like wind and rain, plus time in
        // town. With a cyclability grid, being out in open space leads (riding through cells
        // of cyclability 50 on average ≈ 1.5 points) and the town share counts half: it also
        // counts every village street, which the grid weighs by how built-up the area really is.
        // Without a grid, half the ride in town ≈ 1.5 points.
        if request.leaveTownQuickly {
            let lights = 3 * m.trafficSignals * CostModel.trafficLightSeconds / baseDuration
            if let c = m.meanCyclability {
                s.town = 1.5 * m.urbanShare + 3 * (1 - c / 100) + lights
            } else {
                s.town = 3 * m.urbanShare + lights
            }
        }
        return s
    }
}
