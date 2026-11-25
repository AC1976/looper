import Foundation
import Testing
@testable import LoopRouter

@Suite struct NetworkBinaryTests {
    @Test func roundTripGivesTheSameNetwork() throws {
        let net = try KnooppuntFixture.network()
        let back = try KnooppuntNetwork.load(binary: net.binaryData())
        #expect(back.junctions == net.junctions)
        #expect(back.segments == net.segments)
        #expect(back.hasElevation)
    }

    @Test func roundTripGivesTheSameLoops() async throws {
        let net = try KnooppuntFixture.network()
        let back = try KnooppuntNetwork.load(binary: net.binaryData())
        func loops(_ n: KnooppuntNetwork) async throws -> [[String]] {
            let graph = n.graphBuilder(around: KnooppuntFixture.center, radius: 20_000).build()
            return try await LoopGenerator(graph: graph).generate(KnooppuntFixture.request(seed: 5)).map(\.knooppunten)
        }
        #expect(try await loops(back) == loops(net))
    }

    @Test func missingElevationSurvives() throws {
        let j = KnooppuntNetwork.Junction(id: 1, number: "07", coordinate: Coordinate(latitude: 52, longitude: 5),
                                          elevation: nil)
        let back = try KnooppuntNetwork.load(binary: KnooppuntNetwork(junctions: [1: j], segments: []).binaryData())
        #expect(back.junctions[1] == j)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: KnooppuntNetwork.BinaryFormatError.self) {
            try KnooppuntNetwork.load(binary: Data("{\"type\":\"FeatureCollection\"}".utf8))
        }
    }

    @Test func rejectsTruncatedFiles() throws {
        let data = try KnooppuntFixture.network().binaryData()
        #expect(throws: KnooppuntNetwork.BinaryFormatError.self) {
            try KnooppuntNetwork.load(binary: data.prefix(data.count - 3))
        }
    }
}
