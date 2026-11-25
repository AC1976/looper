import Foundation
import Testing
@testable import LoopRouter

@Suite struct CyclabilityGridTests {
    /// Two cells as the extractor writes them in cells.geojson: Amsterdam centre (built-up)
    /// and a polder cell north of it.
    static let geoJSON = Data("""
    {"type":"FeatureCollection","features":[
     {"type":"Feature","properties":{"i":2909,"j":163,"built_up":0.912,"built_up_around":0.874,
      "network_km":6.35,"quality":0.873,"traffic_signals":9,"cyclability":0},
      "geometry":{"type":"Polygon","coordinates":[[[4.89,52.362],[4.92,52.362],[4.92,52.38],[4.89,52.38],[4.89,52.362]]]}},
     {"type":"Feature","properties":{"i":2913,"j":164,"built_up":0.031,"built_up_around":0.052,
      "network_km":4.12,"quality":0.955,"traffic_signals":0,"scenic":0.412,"cyclability":88},
      "geometry":{"type":"Polygon","coordinates":[[[4.92,52.434],[4.95,52.434],[4.95,52.452],[4.92,52.452],[4.92,52.434]]]}}]}
    """.utf8)

    @Test func findsTheCellOfACoordinate() throws {
        let grid = try CyclabilityGrid.load(geoJSON: Self.geoJSON)
        #expect(grid.cells.count == 2)
        let dam = Coordinate(latitude: 52.3731, longitude: 4.8926)
        #expect(CyclabilityGrid.index(of: dam) == (2909, 163))
        #expect(grid.cell(at: dam)?.builtUp == 0.912)
        #expect(grid.cyclability(at: dam) == 0)
        #expect(grid.cyclability(at: Coordinate(latitude: 52.44, longitude: 4.93)) == 88)
        #expect(grid.cell(at: Coordinate(latitude: 52.44, longitude: 4.93))?.scenic == 0.412)
        #expect(grid.cell(at: dam)?.scenic == 0, "absent in older data = 0")
        #expect(grid.cyclability(at: Coordinate(latitude: 51.0, longitude: 3.0)) == 0, "no routes there")
        let (i, j) = CyclabilityGrid.unpack(CyclabilityGrid.key(2913, 164))
        #expect(i == 2913 && j == 164)
        let c = CyclabilityGrid.centre(2913, 164)
        #expect(CyclabilityGrid.index(of: c) == (2913, 164))
    }

    @Test func survivesNetworkBinExactly() throws {
        let grid = try CyclabilityGrid.load(geoJSON: Self.geoJSON)
        let base = try KnooppuntFixture.network()
        let net = KnooppuntNetwork(junctions: base.junctions, segments: base.segments, cells: grid)
        let back = try KnooppuntNetwork.load(binary: net.binaryData())
        #expect(back.cells == grid)
    }

    @Test func networkWithoutCellsHasAnEmptyGrid() throws {
        let net = try KnooppuntFixture.network()
        #expect(net.cells.isEmpty)
        #expect(try KnooppuntNetwork.load(binary: net.binaryData()).cells.isEmpty)
    }
}
