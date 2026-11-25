import Foundation

/// The extractor's cyclability grid: for every ~2 km × 2 km cell with knooppunt routes, how
/// good it is to ride there, dominated by being out in open space, away from town, with a
/// bonus for scenery (water, woods, dunes, heath, nature reserves, the coast).
///
/// Cell (i, j) covers latitudes [i·0.018°, (i+1)·0.018°) and longitudes [j·0.03°, (j+1)·0.03°):
/// a plain lat/lon grid, the same one the extractor uses (`CELL_DLAT`, `CELL_DLON`).
public struct CyclabilityGrid: Sendable, Equatable {
    public static let cellLatitude = 0.018
    public static let cellLongitude = 0.03

    public struct Cell: Sendable, Equatable {
        /// Share (0…1) of the cell's land in built-up areas (towns, villages, industry).
        public var builtUp: Double
        /// The same for the 8 cells around it, averaged: high at the edge of a town.
        public var builtUpAround: Double
        /// Kilometres of knooppunt routes in the cell.
        public var networkKm: Double
        /// Route quality (0…1): safety label and surface, weighted by length.
        public var quality: Double
        /// Traffic-light intersections on the routes in the cell.
        public var trafficSignals: Int
        /// Share (0…1) of the cell that's water, woods, dunes, beach, heath, wetland, nature
        /// reserve, or within 500 m of the coast.
        public var scenic: Double
        /// The extractor's combined score, 0…100 (see `cyclability` in the extractor).
        public var cyclability: Int

        public init(builtUp: Double, builtUpAround: Double, networkKm: Double, quality: Double,
                    trafficSignals: Int, scenic: Double = 0, cyclability: Int) {
            self.builtUp = builtUp
            self.builtUpAround = builtUpAround
            self.networkKm = networkKm
            self.quality = quality
            self.trafficSignals = trafficSignals
            self.scenic = scenic
            self.cyclability = cyclability
        }
    }

    /// Cells by packed (i, j); see `key(_:_:)`.
    public let cells: [Int64: Cell]

    public static let empty = CyclabilityGrid(cells: [:])

    public init(cells: [Int64: Cell]) {
        self.cells = cells
    }

    public var isEmpty: Bool { cells.isEmpty }

    public static func key(_ i: Int, _ j: Int) -> Int64 {
        (Int64(i) << 32) | Int64(UInt32(truncatingIfNeeded: j))
    }

    public static func index(of c: Coordinate) -> (i: Int, j: Int) {
        (Int((c.latitude / cellLatitude).rounded(.down)), Int((c.longitude / cellLongitude).rounded(.down)))
    }

    /// The (i, j) of a packed key.
    public static func unpack(_ key: Int64) -> (i: Int, j: Int) {
        (Int(key >> 32), Int(Int32(truncatingIfNeeded: key)))
    }

    /// Centre of cell (i, j).
    public static func centre(_ i: Int, _ j: Int) -> Coordinate {
        Coordinate(latitude: (Double(i) + 0.5) * cellLatitude, longitude: (Double(j) + 0.5) * cellLongitude)
    }

    public func cell(at c: Coordinate) -> Cell? {
        let (i, j) = Self.index(of: c)
        return cells[Self.key(i, j)]
    }

    /// 0…100; 0 where there are no knooppunt routes.
    public func cyclability(at c: Coordinate) -> Int {
        cell(at: c)?.cyclability ?? 0
    }
}

// MARK: - Loading from the extractor's cells.geojson

struct CellProperties: Decodable {
    let i: Int
    let j: Int
    let built_up: Double
    let built_up_around: Double
    let network_km: Double
    let quality: Double
    let traffic_signals: Int
    let scenic: Double?
    let cyclability: Int
}

extension CyclabilityGrid {
    /// Reads `cells.geojson` as written by the extractor (only the properties are used).
    static func load(geoJSON data: Data) throws -> CyclabilityGrid {
        var cells: [Int64: Cell] = [:]
        for f in try JSONDecoder().decode(FeatureCollection<CellProperties>.self, from: data).features {
            let p = f.properties
            cells[key(p.i, p.j)] = Cell(builtUp: p.built_up, builtUpAround: p.built_up_around,
                                        networkKm: p.network_km, quality: p.quality,
                                        trafficSignals: p.traffic_signals, scenic: p.scenic ?? 0,
                                        cyclability: p.cyclability)
        }
        return CyclabilityGrid(cells: cells)
    }
}
