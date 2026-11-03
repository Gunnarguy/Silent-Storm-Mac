import Foundation

/// Low-level reader for Nival Interactive's `CStructureSaver` (`ShortChunkSave`) TLV binary streams
/// and `.res` resource archives (`0x95938921` v0 and `0x96948A22` v1).
public enum ShortChunkReader {
    public struct Chunk: Sendable {
        public let id: UInt8
        public let payloadRange: Range<Int>
        public var length: Int { payloadRange.count }
    }

    @inlinable
    public static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        return data.withUnsafeBytes { raw in
            guard offset >= 0, offset + 4 <= raw.count else { return 0 }
            let b0 = UInt32(raw[offset])
            let b1 = UInt32(raw[offset + 1]) << 8
            let b2 = UInt32(raw[offset + 2]) << 16
            let b3 = UInt32(raw[offset + 3]) << 24
            return b0 | b1 | b2 | b3
        }
    }

    @inlinable
    public static func readInt32LE(_ data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32LE(data, at: offset))
    }

    @inlinable
    public static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        return data.withUnsafeBytes { raw in
            guard offset >= 0, offset + 2 <= raw.count else { return 0 }
            return UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
        }
    }

    @inlinable
    public static func readFloatLE(_ data: Data, at offset: Int) -> Float {
        Float(bitPattern: readUInt32LE(data, at: offset))
    }

    /// Iterates `ShortChunkSave` chunks within `range` of `data`.
    public static func iterateChunks(in data: Data, range: Range<Int>? = nil) -> [Chunk] {
        let r = range ?? (0..<data.count)
        var chunks: [Chunk] = []
        data.withUnsafeBytes { raw in
            var pos = r.lowerBound
            let end = min(r.upperBound, raw.count)
            while pos + 2 <= end {
                let id = raw[pos]
                let b0 = raw[pos + 1]
                pos += 2
                let length: Int
                if (b0 & 1) != 0 {
                    guard pos + 3 <= end else { break }
                    let combined = UInt32(b0)
                        | (UInt32(raw[pos]) << 8)
                        | (UInt32(raw[pos + 1]) << 16)
                        | (UInt32(raw[pos + 2]) << 24)
                    pos += 3
                    length = Int(combined >> 1)
                } else {
                    length = Int(b0 >> 1)
                }
                guard length >= 0, pos + length <= end else { break }
                chunks.append(Chunk(id: id, payloadRange: pos..<(pos + length)))
                pos += length
            }
        }
        return chunks
    }

    /// Locates the root payload (top-level chunk `1`) of a `CStructureSaver` stream.
    public static func rootDataRange(in data: Data, range: Range<Int>? = nil) -> Range<Int> {
        let r = range ?? (0..<data.count)
        for chunk in iterateChunks(in: data, range: r) where chunk.id == 1 {
            return chunk.payloadRange
        }
        return r
    }

    /// Reads a `DoDataVector<T>` chunk (`subchunk 1` = `Int32 count`, `subchunk 2` = raw payload).
    public static func readDataVector(in data: Data, range: Range<Int>) -> (count: Int, bytesRange: Range<Int>) {
        var count = 0
        var bytesRange = range.lowerBound..<range.lowerBound
        for sub in iterateChunks(in: data, range: range) {
            if sub.id == 1 && sub.length >= 4 {
                count = Int(readInt32LE(data, at: sub.payloadRange.lowerBound))
            } else if sub.id == 2 {
                bytesRange = sub.payloadRange
            }
        }
        return (count, bytesRange)
    }

    /// Reads a `DataChunkString(std::string)` payload directly from `range`.
    public static func readASCIIString(in data: Data, range: Range<Int>) -> String {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= data.count else { return "" }
        let slice = data[range]
        return String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .windowsCP1251)
            ?? String(data: slice, encoding: .isoLatin1)
            ?? ""
    }

    /// Reads a `DataChunkString(std::wstring)` UTF-16LE payload directly from `range`.
    public static func readUTF16String(in data: Data, range: Range<Int>) -> String {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= data.count else { return "" }
        let slice = data[range]
        return String(data: slice, encoding: .utf16LittleEndian) ?? ""
    }
}

public struct ResFileEntry: Sendable, Identifiable, Hashable {
    public let id: UInt32
    public let offset: UInt32
    public let length: UInt32

    public init(id: UInt32, offset: UInt32, length: UInt32) {
        self.id = id
        self.offset = offset
        self.length = length
    }
}

/// Reader for Silent Storm `.res` packages (`FileIO/FilesPackage.cpp`).
public struct ResPackageReader: Sendable {
    public static let signatureV0: UInt32 = 0x95938921
    public static let signatureV1: UInt32 = 0x96948A22

    public let fileURL: URL
    public let signature: UInt32
    public let headerOffset: UInt32
    public let entries: [UInt32: ResFileEntry]
    public let sortedEntries: [ResFileEntry]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        guard let topHeader = try handle.read(upToCount: 8), topHeader.count == 8 else {
            throw NSError(domain: "ResPackageReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid .res header in \(fileURL.lastPathComponent)"])
        }
        let sig = ShortChunkReader.readUInt32LE(topHeader, at: 0)
        guard sig == Self.signatureV0 || sig == Self.signatureV1 else {
            throw NSError(domain: "ResPackageReader", code: 2, userInfo: [NSLocalizedDescriptionKey: String(format: "Unsupported .res signature 0x%08X", sig)])
        }
        let hdrPos = ShortChunkReader.readUInt32LE(topHeader, at: 4)
        self.signature = sig
        self.headerOffset = hdrPos

        try handle.seek(toOffset: UInt64(hdrPos))
        let headerData = try handle.readToEnd() ?? Data()

        let rootRange = ShortChunkReader.rootDataRange(in: headerData)
        var parsedEntries: [UInt32: ResFileEntry] = [:]

        for chunk in ShortChunkReader.iterateChunks(in: headerData, range: rootRange) where chunk.id == 1 {
            var keys: [UInt32] = []
            var values: [(UInt32, UInt32)] = []
            let subChunks = ShortChunkReader.iterateChunks(in: headerData, range: chunk.payloadRange)
            keys.reserveCapacity(subChunks.count / 2)
            values.reserveCapacity(subChunks.count / 2)

            for sub in subChunks {
                if sub.id == 1 && sub.length >= 4 {
                    keys.append(ShortChunkReader.readUInt32LE(headerData, at: sub.payloadRange.lowerBound))
                } else if sub.id == 2 && sub.length >= 8 {
                    let start = ShortChunkReader.readUInt32LE(headerData, at: sub.payloadRange.lowerBound)
                    let len = ShortChunkReader.readUInt32LE(headerData, at: sub.payloadRange.lowerBound + 4)
                    values.append((start, len))
                }
            }
            let count = min(keys.count, values.count)
            for i in 0..<count {
                let k = keys[i]
                let (s, l) = values[i]
                parsedEntries[k] = ResFileEntry(id: k, offset: s, length: l)
            }
        }

        self.entries = parsedEntries
        self.sortedEntries = parsedEntries.values.sorted { $0.id < $1.id }
    }

    /// Reads the raw bytes for a given resource ID from the package.
    public func readEntryData(id: UInt32) throws -> Data {
        guard let entry = entries[id] else {
            throw NSError(domain: "ResPackageReader", code: 404, userInfo: [NSLocalizedDescriptionKey: "Resource ID \(id) not found in \(fileURL.lastPathComponent)"])
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        return try handle.read(upToCount: Int(entry.length)) ?? Data()
    }
}
