import Foundation
import LoopRouter

// Converts the extractor's GeoJSON (junctions.geojson + segments.geojson) into the compact
// network.bin the router loads. Run it after every extractor run: swift run -c release pack-network
let networkDirectory = URL(fileURLWithPath: "data/nl")
let output = networkDirectory.appendingPathComponent(KnooppuntNetwork.binaryFileName)

let clock = ContinuousClock()
do {
    var started = clock.now
    let network = try KnooppuntNetwork.load(directory: networkDirectory)
    let geoJSONTime = clock.now - started
    print("Read \(network.junctions.count) knooppunten, \(network.segments.count) segments,"
          + " \(network.cells.cells.count) cyclability cells from GeoJSON in \(geoJSONTime)")

    try network.writeBinary(to: output)

    started = clock.now
    let check = try KnooppuntNetwork.load(binary: output)
    let binaryTime = clock.now - started
    guard check.junctions == network.junctions, check.segments == network.segments, check.cells == network.cells else {
        print("Error: \(output.lastPathComponent) doesn't read back as the same network.")
        exit(1)
    }

    func megabytes(_ url: URL) -> Double {
        Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_000_000
    }
    let geoJSONSize = ["junctions.geojson", "segments.geojson"]
        .map { megabytes(networkDirectory.appendingPathComponent($0)) }.reduce(0, +)
    print(String(format: "Wrote %@: %.1f MB (GeoJSON %.1f MB)", output.path, megabytes(output), geoJSONSize))
    print("Read back identical in \(binaryTime)")
} catch {
    print("Error: \(error)")
    exit(1)
}
