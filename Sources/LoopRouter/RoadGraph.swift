import Foundation

// MARK: - Graph primitives

public struct RoadNode: Sendable {
    public let index: Int
    /// Junction id from the extractor, or a negative synthetic id for points along a segment.
    public let id: Int64
    public let coordinate: Coordinate
    public var elevation: Double
    /// Signposted junction number (knooppunt), if this node is one.
    public var label: String?
}

/// A directed edge. Each piece of a segment yields two edges (one per direction) that
/// share a `segmentID`, which is what we use to detect re-use / out-and-back riding.
public struct RoadEdge: Sendable {
    public let index: Int
    public let from: Int
    public let to: Int
    public let segmentID: Int
    public let length: Double
    public let bearing: Double
    /// Road-type and surface mix of the knooppunt segment this edge belongs to.
    public let profile: SegmentProfile
    public var ascent: Double
    public var descent: Double
    /// Display points strictly between `from` and `to`, in riding order (empty = straight line).
    public let shape: [Coordinate]
    /// Cyclability (0…1) of the grid cell the edge is in; nil without a cyclability grid.
    public let cyclability: Double?

    /// Uphill grade as a fraction (0.05 = 5 %).
    public var upGrade: Double { length > 0 ? ascent / length : 0 }
    /// Downhill grade as a fraction, positive number.
    public var downGrade: Double { length > 0 ? descent / length : 0 }
}

// MARK: - Builder

/// Mutable builder; `KnooppuntNetwork` fills it, then `build()` freezes an immutable `RoadGraph`.
public struct RoadGraphBuilder: Sendable {
    public private(set) var nodes: [RoadNode] = []
    private var idToIndex: [Int64: Int] = [:]
    private var edgeSpecs: [(from: Int, to: Int, segment: Int, profile: SegmentProfile, shape: [Coordinate])] = []
    private var segmentCounter = 0
    /// Where it's good to ride; gives each edge its `cyclability`.
    public var cells: CyclabilityGrid = .empty

    public init() {}

    /// Adds a node (idempotent on `id`) and returns its index.
    @discardableResult
    public mutating func addNode(id: Int64, coordinate: Coordinate, elevation: Double = 0,
                                 label: String? = nil) -> Int {
        if let existing = idToIndex[id] { return existing }
        let idx = nodes.count
        nodes.append(RoadNode(index: idx, id: id, coordinate: coordinate, elevation: elevation, label: label))
        idToIndex[id] = idx
        return idx
    }

    /// Adds a polyline as consecutive two-way pieces. `shapes[k]`, if given, holds the display
    /// points strictly between `nodeIndices[k]` and `nodeIndices[k + 1]`.
    public mutating func addPath(nodeIndices: [Int], profile: SegmentProfile, shapes: [[Coordinate]] = []) {
        for k in 0..<max(0, nodeIndices.count - 1) {
            let a = nodeIndices[k], b = nodeIndices[k + 1]
            guard a != b else { continue }
            let shape = k < shapes.count ? shapes[k] : []
            let seg = segmentCounter
            segmentCounter += 1
            edgeSpecs.append((a, b, seg, profile, shape))
            edgeSpecs.append((b, a, seg, profile, shape.reversed()))
        }
    }

    public func build() -> RoadGraph {
        var edges: [RoadEdge] = []
        edges.reserveCapacity(edgeSpecs.count)
        var outgoing = Array(repeating: [Int](), count: nodes.count)
        for spec in edgeSpecs {
            let a = nodes[spec.from], b = nodes[spec.to]
            let length = max(0.5, Geo.distance(a.coordinate, b.coordinate) * spec.profile.lengthScale)
            let dz = b.elevation - a.elevation
            let edge = RoadEdge(index: edges.count, from: spec.from, to: spec.to,
                                segmentID: spec.segment, length: length,
                                bearing: Geo.bearing(a.coordinate, b.coordinate),
                                profile: spec.profile,
                                ascent: max(0, dz), descent: max(0, -dz), shape: spec.shape,
                                cyclability: cells.isEmpty ? nil : Double(cells.cyclability(at: Coordinate(
                                    latitude: (a.coordinate.latitude + b.coordinate.latitude) / 2,
                                    longitude: (a.coordinate.longitude + b.coordinate.longitude) / 2))) / 100)
            outgoing[spec.from].append(edge.index)
            edges.append(edge)
        }
        return RoadGraph(nodes: nodes, edges: edges, outgoing: outgoing, cells: cells)
    }
}

// MARK: - Immutable graph

public struct RoadGraph: Sendable {
    public let nodes: [RoadNode]
    public let edges: [RoadEdge]
    public let outgoing: [[Int]]
    /// Number of distinct neighbouring nodes (undirected). Degree >= 3 means a junction.
    public let degree: [Int]
    /// Undirected connected-component label per node.
    public let component: [Int]
    private let index: SpatialIndex
    /// Where it's good to ride (empty without a cyclability grid).
    public let cells: CyclabilityGrid

    init(nodes: [RoadNode], edges: [RoadEdge], outgoing: [[Int]], cells: CyclabilityGrid = .empty) {
        self.nodes = nodes
        self.edges = edges
        self.outgoing = outgoing
        self.cells = cells

        var neighbours = Array(repeating: Set<Int>(), count: nodes.count)
        for e in edges {
            neighbours[e.from].insert(e.to)
            neighbours[e.to].insert(e.from)
        }
        degree = neighbours.map(\.count)

        var label = Array(repeating: -1, count: nodes.count)
        var current = 0
        for seed in nodes.indices where label[seed] == -1 {
            var stack = [seed]
            label[seed] = current
            while let n = stack.popLast() {
                for m in neighbours[n] where label[m] == -1 {
                    label[m] = current
                    stack.append(m)
                }
            }
            current += 1
        }
        component = label
        index = SpatialIndex(nodes: nodes)
    }

    /// The same piece ridden the other way. `RoadGraphBuilder.addPath` adds each piece as
    /// two consecutive edges, so they differ only in the lowest bit of their index.
    public func reverse(of edge: Int) -> Int { edge ^ 1 }

    /// Nearest node within `maxDistance` metres that satisfies `filter`.
    public func nearestNode(to c: Coordinate, maxDistance: Double,
                            where filter: (Int) -> Bool = { _ in true }) -> Int? {
        index.nearest(to: c, maxDistance: maxDistance, nodes: nodes, filter: filter)
    }
}

/// Uniform lat/lon bucket grid for nearest-node lookups.
struct SpatialIndex: Sendable {
    static let cellDegrees = 0.0025 // ~280 m north-south
    private var cells: [Int64: [Int]] = [:]

    init(nodes: [RoadNode]) {
        for n in nodes { cells[Self.key(n.coordinate), default: []].append(n.index) }
    }

    private static func cell(_ c: Coordinate) -> (Int, Int) {
        (Int((c.latitude / cellDegrees).rounded(.down)), Int((c.longitude / cellDegrees).rounded(.down)))
    }
    private static func pack(_ i: Int, _ j: Int) -> Int64 {
        (Int64(i) << 32) | Int64(UInt32(truncatingIfNeeded: j))
    }
    private static func key(_ c: Coordinate) -> Int64 {
        let (i, j) = cell(c)
        return pack(i, j)
    }

    func nearest(to c: Coordinate, maxDistance: Double, nodes: [RoadNode], filter: (Int) -> Bool) -> Int? {
        let (ci, cj) = Self.cell(c)
        // Lon cells are narrower in metres; size rings by the narrow side.
        let cellMeters = Self.cellDegrees * Geo.metersPerDegreeLatitude * max(0.1, cos(Geo.rad(c.latitude)))
        let maxRing = Int((maxDistance / cellMeters).rounded(.up)) + 1
        var best: (index: Int, distance: Double)?
        for ring in 0...maxRing {
            for di in -ring...ring {
                for dj in -ring...ring where max(abs(di), abs(dj)) == ring {
                    guard let bucket = cells[Self.pack(ci + di, cj + dj)] else { continue }
                    for idx in bucket where filter(idx) {
                        let d = Geo.distance(c, nodes[idx].coordinate)
                        if d < (best?.distance ?? .infinity) { best = (idx, d) }
                    }
                }
            }
            if let b = best, b.distance < Double(ring) * cellMeters { break }
        }
        guard let b = best, b.distance <= maxDistance else { return nil }
        return b.index
    }
}
