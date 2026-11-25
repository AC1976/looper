import Foundation

/// Compact binary form of a `KnooppuntNetwork` (`network.bin`).
///
/// It holds exactly what the router uses, after the GeoJSON clean-up in
/// `KnooppuntNetwork.load(junctions:segments:)`: connectors dropped, paths oriented and
/// thinned, display geometry simplified, `lengthScale` computed. Loading it gives the same network as loading the
/// GeoJSON it was made from, so routes come out identical.
///
/// Layout, all little-endian, no padding:
///
///     header    magic "LRNB" · version UInt32 · junctionCount UInt32 · segmentCount UInt32
///     junction  id Int64 · latitude Float64 · longitude Float64 · elevation Float64 (NaN = none)
///               · numberLength UInt8 · number UTF-8 bytes
///     segment   id Int64 · from Int64 · to Int64 · length Float64
///               · profile 15 × Float64 (separated, bikePriority, quietShared, ruralLane,
///                 paintedLane, sharedRoad, ferry, semiPaved, unpaved, surfaceUnknown, lengthScale,
///                 urban, trafficSignalsPerKm, lf, euroVelo)
///               · displayCount UInt32 · display points (latitude Float64 · longitude Float64) × displayCount
///               · pathCount UInt32 · path indices into the display points (UInt32) × pathCount
///
/// The routing points (`Segment.path`) are the display points at the path indices, so
/// they aren't stored twice. After the segments comes the cyclability grid:
///
///     cells     cellCount UInt32
///     cell      i Int32 · j Int32 · builtUp, builtUpAround UInt16 (× 1000) · networkKm UInt16 (× 100)
///               · quality UInt16 (× 1000) · trafficSignals UInt16 · scenic UInt16 (× 1000)
///               · cyclability UInt8
///
/// The extractor rounds those fields to the same precision, so they read back exactly.
/// Version 1 stored only the routing points; version 2 had no `urban` and
/// `trafficSignalsPerKm`; version 3 had no cyclability grid; version 4 had no `lf` and
/// `euroVelo`; version 5 had no scenic share per cell.
///
/// Junctions are written sorted by id; segments keep their order, because the graph
/// builder's node numbering (and so tie-breaking in routing) follows it.
/// Make it again whenever the extractor output changes.
extension KnooppuntNetwork {
    public static let binaryFileName = "network.bin"
    static let binaryMagic: [UInt8] = Array("LRNB".utf8)
    static let binaryVersion: UInt32 = 6

    public enum BinaryFormatError: Error, CustomStringConvertible {
        case notANetworkFile
        case unsupportedVersion(UInt32)
        case truncated
        case invalidJunctionNumber
        case junctionNumberTooLong(String)
        case inconsistentSegment(Int64)

        public var description: String {
            switch self {
            case .notANetworkFile: "Not a LoopRouter network file."
            case .unsupportedVersion(let v): "Network file version \(v) isn't supported (expected \(KnooppuntNetwork.binaryVersion))."
            case .truncated: "Network file is truncated."
            case .invalidJunctionNumber: "Network file has a junction number that isn't valid UTF-8."
            case .junctionNumberTooLong(let n): "Junction number \"\(n)\" is longer than 255 bytes."
            case .inconsistentSegment(let id): "Network file has an inconsistent segment \(id)."
            }
        }
    }

    /// The network in the `network.bin` format.
    public func binaryData() throws -> Data {
        var w = BinaryWriter()
        w.bytes(Self.binaryMagic)
        w.uint32(Self.binaryVersion)
        w.uint32(UInt32(junctions.count))
        w.uint32(UInt32(segments.count))
        for j in junctions.values.sorted(by: { $0.id < $1.id }) {
            let number = Array(j.number.utf8)
            guard number.count <= 255 else { throw BinaryFormatError.junctionNumberTooLong(j.number) }
            w.int64(j.id)
            w.coordinate(j.coordinate)
            w.double(j.elevation ?? .nan)
            w.uint8(UInt8(number.count))
            w.bytes(number)
        }
        for s in segments {
            w.int64(s.id)
            w.int64(s.from)
            w.int64(s.to)
            w.double(s.length)
            let p = s.profile
            for v in [p.separated, p.bikePriority, p.quietShared, p.ruralLane, p.paintedLane, p.sharedRoad,
                      p.ferry, p.semiPaved, p.unpaved, p.surfaceUnknown, p.lengthScale,
                      p.urban, p.trafficSignalsPerKm, p.lf, p.euroVelo] { w.double(v) }
            w.uint32(UInt32(s.displayPath.count))
            for c in s.displayPath { w.coordinate(c) }
            w.uint32(UInt32(s.pathIndices.count))
            for i in s.pathIndices { w.uint32(UInt32(i)) }
        }
        w.uint32(UInt32(cells.cells.count))
        for (key, c) in cells.cells.sorted(by: { $0.key < $1.key }) {
            let (i, j) = CyclabilityGrid.unpack(key)
            w.uint32(UInt32(bitPattern: Int32(i)))
            w.uint32(UInt32(bitPattern: Int32(j)))
            w.uint16(UInt16(clamping: Int((c.builtUp * 1_000).rounded())))
            w.uint16(UInt16(clamping: Int((c.builtUpAround * 1_000).rounded())))
            w.uint16(UInt16(clamping: Int((c.networkKm * 100).rounded())))
            w.uint16(UInt16(clamping: Int((c.quality * 1_000).rounded())))
            w.uint16(UInt16(clamping: c.trafficSignals))
            w.uint16(UInt16(clamping: Int((c.scenic * 1_000).rounded())))
            w.uint8(UInt8(clamping: c.cyclability))
        }
        return w.data
    }

    /// Writes `network.bin` (or any file name) for this network.
    public func writeBinary(to url: URL) throws {
        try binaryData().write(to: url, options: .atomic)
    }

    /// Loads a network from a file written by `writeBinary(to:)`.
    public static func load(binary url: URL) throws -> KnooppuntNetwork {
        try load(binary: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func load(binary data: Data) throws -> KnooppuntNetwork {
        try data.withUnsafeBytes { raw in
            var r = BinaryReader(raw)
            guard try r.bytes(4) == binaryMagic else { throw BinaryFormatError.notANetworkFile }
            let version = try r.uint32()
            guard version == binaryVersion else { throw BinaryFormatError.unsupportedVersion(version) }
            let junctionCount = Int(try r.uint32())
            let segmentCount = Int(try r.uint32())

            var junctions: [Int64: Junction] = [:]
            junctions.reserveCapacity(junctionCount)
            for _ in 0..<junctionCount {
                let id = try r.int64()
                let coordinate = try r.coordinate()
                let elevation = try r.double()
                let length = Int(try r.uint8())
                guard let number = String(bytes: try r.bytes(length), encoding: .utf8)
                else { throw BinaryFormatError.invalidJunctionNumber }
                junctions[id] = Junction(id: id, number: number, coordinate: coordinate,
                                         elevation: elevation.isNaN ? nil : elevation)
            }

            var segments: [Segment] = []
            segments.reserveCapacity(segmentCount)
            for _ in 0..<segmentCount {
                let id = try r.int64(), from = try r.int64(), to = try r.int64()
                let length = try r.double()
                let profile = SegmentProfile(
                    separated: try r.double(), bikePriority: try r.double(), quietShared: try r.double(),
                    ruralLane: try r.double(), paintedLane: try r.double(), sharedRoad: try r.double(),
                    ferry: try r.double(), semiPaved: try r.double(), unpaved: try r.double(),
                    surfaceUnknown: try r.double(), lengthScale: try r.double(),
                    urban: try r.double(), trafficSignalsPerKm: try r.double(),
                    lf: try r.double(), euroVelo: try r.double())
                let displayCount = Int(try r.uint32())
                var display: [Coordinate] = []
                display.reserveCapacity(displayCount)
                for _ in 0..<displayCount { display.append(try r.coordinate()) }
                let pathCount = Int(try r.uint32())
                var indices: [Int] = []
                indices.reserveCapacity(pathCount)
                for _ in 0..<pathCount { indices.append(Int(try r.uint32())) }
                // Indices must start at the first display point, end at the last, and rise.
                guard indices.count >= 2, indices.first == 0, indices.last == display.count - 1,
                      zip(indices, indices.dropFirst()).allSatisfy({ $0 < $1 })
                else { throw BinaryFormatError.inconsistentSegment(id) }
                segments.append(Segment(id: id, from: from, to: to, length: length,
                                        displayPath: display, pathIndices: indices, profile: profile))
            }
            let cellCount = Int(try r.uint32())
            var cells: [Int64: CyclabilityGrid.Cell] = [:]
            cells.reserveCapacity(cellCount)
            for _ in 0..<cellCount {
                let i = Int(Int32(bitPattern: try r.uint32())), j = Int(Int32(bitPattern: try r.uint32()))
                cells[CyclabilityGrid.key(i, j)] = CyclabilityGrid.Cell(
                    builtUp: Double(try r.uint16()) / 1_000, builtUpAround: Double(try r.uint16()) / 1_000,
                    networkKm: Double(try r.uint16()) / 100, quality: Double(try r.uint16()) / 1_000,
                    trafficSignals: Int(try r.uint16()), scenic: Double(try r.uint16()) / 1_000,
                    cyclability: Int(try r.uint8()))
            }
            return KnooppuntNetwork(junctions: junctions, segments: segments, cells: CyclabilityGrid(cells: cells))
        }
    }
}

// MARK: - Little-endian byte helpers

private struct BinaryWriter {
    var data = Data()

    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func uint8(_ v: UInt8) { data.append(v) }
    mutating func uint16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func uint32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func int64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func double(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    mutating func coordinate(_ c: Coordinate) { double(c.latitude); double(c.longitude) }
}

private struct BinaryReader {
    let raw: UnsafeRawBufferPointer
    var offset = 0

    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    private mutating func take(_ n: Int) throws -> Int {
        guard n >= 0, offset + n <= raw.count else { throw KnooppuntNetwork.BinaryFormatError.truncated }
        defer { offset += n }
        return offset
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        let at = try take(n)
        return Array(raw[at..<(at + n)])
    }
    mutating func uint8() throws -> UInt8 { raw[try take(1)] }
    mutating func uint16() throws -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: try take(2), as: UInt16.self))
    }
    mutating func uint32() throws -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: try take(4), as: UInt32.self))
    }
    mutating func int64() throws -> Int64 {
        Int64(littleEndian: raw.loadUnaligned(fromByteOffset: try take(8), as: Int64.self))
    }
    mutating func double() throws -> Double {
        Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: try take(8), as: UInt64.self)))
    }
    mutating func coordinate() throws -> Coordinate {
        Coordinate(latitude: try double(), longitude: try double())
    }
}
