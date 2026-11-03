import Foundation
import simd

public struct GeometryVertex: Sendable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var uv: SIMD2<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) {
        self.position = position
        self.normal = normal
        self.uv = uv
    }
}

public struct DecodedGeometry: Sendable {
    public let vertices: [GeometryVertex]
    public let triangleIndices: [UInt32] // 3 per triangle
    public let pieceCount: Int
    public let vertexStrideBytes: Int
    public let minBounds: SIMD3<Float>
    public let maxBounds: SIMD3<Float>

    public var triangleCount: Int { triangleIndices.count / 3 }
    public var center: SIMD3<Float> { (minBounds + maxBounds) * 0.5 }
    public var boundingRadius: Float {
        let ext = maxBounds - minBounds
        let r = simd_length(ext) * 0.5
        return r > 0.0001 ? r : 1.0
    }

    public func exportWavefrontOBJ(name: String = "SilentStormMesh") -> String {
        var out = "# Silent Storm 3D Mesh exported by OpenStorm\n"
        out += "o \(name)\n"
        for v in vertices {
            out += String(format: "v %.6f %.6f %.6f\n", v.position.x, v.position.y, v.position.z)
        }
        for v in vertices {
            out += String(format: "vn %.6f %.6f %.6f\n", v.normal.x, v.normal.y, v.normal.z)
        }
        for v in vertices {
            out += String(format: "vt %.6f %.6f\n", v.uv.x, 1.0 - v.uv.y)
        }
        let triCount = triangleCount
        for t in 0..<triCount {
            let i0 = triangleIndices[t * 3] + 1
            let i1 = triangleIndices[t * 3 + 1] + 1
            let i2 = triangleIndices[t * 3 + 2] + 1
            out += "f \(i0)/\(i0)/\(i0) \(i1)/\(i1)/\(i1) \(i2)/\(i2)/\(i2)\n"
        }
        return out
    }
}

/// Decodes Silent Storm 3D geometries from `Geometries.res` (`Main/GObjectInfo.cpp`, `Main/GGeometry.cpp`).
public enum GGeometryDecoder {
    public static func decode(_ data: Data) -> DecodedGeometry? {
        let rootRange = ShortChunkReader.rootDataRange(in: data)
        var allVertices: [GeometryVertex] = []
        var allTriangles: [UInt32] = []
        var pieceCount = 0
        var detectedStride = 0

        let topChunks = ShortChunkReader.iterateChunks(in: data, range: rootRange)

        // 1. Check direct mesh chunks (chunk 1 = points, chunk 2 = indices, chunk 3 = polys)
        if let (verts, tris, stride) = decodeFacesRange(in: data, chunks: topChunks, baseVertexOffset: 0), !verts.isEmpty {
            allVertices.append(contentsOf: verts)
            allTriangles.append(contentsOf: tris)
            pieceCount += 1
            detectedStride = stride
        }

        // 2. Also check chunk 4 (CObjectInfoPieces CPieceMap: unordered_map<int, SFacesVector>)
        for chunk in topChunks where chunk.id == 4 {
            let mapChunks = ShortChunkReader.iterateChunks(in: data, range: chunk.payloadRange)
            for sub in mapChunks where sub.id == 2 {
                let pieceChunks = ShortChunkReader.iterateChunks(in: data, range: sub.payloadRange)
                let baseOffset = UInt32(allVertices.count)
                if let (verts, tris, stride) = decodeFacesRange(in: data, chunks: pieceChunks, baseVertexOffset: baseOffset), !verts.isEmpty {
                    allVertices.append(contentsOf: verts)
                    allTriangles.append(contentsOf: tris)
                    pieceCount += 1
                    if detectedStride == 0 { detectedStride = stride }
                }
            }
        }

        // 3. Also check CObjectInfo::SData save layout (chunk 2 = verts, chunk 3 = SPolygonIndices)
        if allVertices.isEmpty {
            var vChunkRange: Range<Int>?
            var geomChunkRange: Range<Int>?
            for chunk in topChunks {
                if chunk.id == 2 { vChunkRange = chunk.payloadRange }
                else if chunk.id == 3 { geomChunkRange = chunk.payloadRange }
            }
            if let vr = vChunkRange, let gr = geomChunkRange {
                let (vCount, vBytes) = ShortChunkReader.readDataVector(in: data, range: vr)
                let (verts, stride) = parseVertexBuffer(data: data, count: vCount, bytesRange: vBytes)
                var indices: [UInt16] = []
                var polys: [UInt16] = []
                for gc in ShortChunkReader.iterateChunks(in: data, range: gr) {
                    if gc.id == 2 {
                        indices = parseUInt16Vector(data: data, range: gc.payloadRange)
                    } else if gc.id == 3 {
                        polys = parseUInt16Vector(data: data, range: gc.payloadRange)
                    }
                }
                let tris = triangulatePolygons(indices: indices, polys: polys, vertexCount: verts.count, baseOffset: 0)
                if !verts.isEmpty {
                    allVertices = verts
                    allTriangles = tris
                    pieceCount = 1
                    detectedStride = stride
                }
            }
        }

        guard !allVertices.isEmpty else { return nil }

        var minB = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in allVertices {
            minB = simd_min(minB, v.position)
            maxB = simd_max(maxB, v.position)
        }
        if !minB.x.isFinite || !maxB.x.isFinite {
            minB = SIMD3<Float>(-1, -1, -1)
            maxB = SIMD3<Float>(1, 1, 1)
        }

        return DecodedGeometry(
            vertices: allVertices,
            triangleIndices: allTriangles,
            pieceCount: max(1, pieceCount),
            vertexStrideBytes: detectedStride,
            minBounds: minB,
            maxBounds: maxB
        )
    }

    private static func decodeFacesRange(
        in data: Data,
        chunks: [ShortChunkReader.Chunk],
        baseVertexOffset: UInt32
    ) -> ([GeometryVertex], [UInt32], Int)? {
        var vertsRange: Range<Int>?
        var indicesRange: Range<Int>?
        var polysRange: Range<Int>?

        for c in chunks {
            switch c.id {
            case 1: vertsRange = c.payloadRange
            case 2: indicesRange = c.payloadRange
            case 3: polysRange = c.payloadRange
            default: break
            }
        }
        guard let vr = vertsRange else { return nil }
        let (vCount, vBytes) = ShortChunkReader.readDataVector(in: data, range: vr)
        let (verts, stride) = parseVertexBuffer(data: data, count: vCount, bytesRange: vBytes)
        guard !verts.isEmpty else { return nil }

        let indices = indicesRange.map { parseUInt16Vector(data: data, range: $0) } ?? []
        let polys = polysRange.map { parseUInt16Vector(data: data, range: $0) } ?? []
        let tris = triangulatePolygons(indices: indices, polys: polys, vertexCount: verts.count, baseOffset: baseVertexOffset)
        return (verts, tris, stride)
    }

    private static func parseUInt16Vector(data: Data, range: Range<Int>) -> [UInt16] {
        let (count, bytesRange) = ShortChunkReader.readDataVector(in: data, range: range)
        guard count > 0, bytesRange.count >= count * 2 else { return [] }
        var result: [UInt16] = []
        result.reserveCapacity(count)
        let start = bytesRange.lowerBound
        for i in 0..<count {
            result.append(ShortChunkReader.readUInt16LE(data, at: start + i * 2))
        }
        return result
    }

    private static func parseVertexBuffer(
        data: Data,
        count: Int,
        bytesRange: Range<Int>
    ) -> ([GeometryVertex], Int) {
        guard count > 0, bytesRange.count >= count * 12 else { return ([], 0) }
        let stride = bytesRange.count / count
        guard stride == 60 || stride == 32 || stride >= 24 else { return ([], 0) }

        var vertices: [GeometryVertex] = []
        vertices.reserveCapacity(count)
        let start = bytesRange.lowerBound

        for i in 0..<count {
            let base = start + i * stride
            let px = ShortChunkReader.readFloatLE(data, at: base)
            let py = ShortChunkReader.readFloatLE(data, at: base + 4)
            let pz = ShortChunkReader.readFloatLE(data, at: base + 8)
            let pos = SIMD3<Float>(
                px.isFinite ? px : 0,
                py.isFinite ? py : 0,
                pz.isFinite ? pz : 0
            )

            let norm: SIMD3<Float>
            let uv: SIMD2<Float>

            if stride >= 60 {
                // SLoadVertex (60 bytes): pos (12), normal (12), tex (8), texU (12), texV (12), dwColor (4)
                let nx = ShortChunkReader.readFloatLE(data, at: base + 12)
                let ny = ShortChunkReader.readFloatLE(data, at: base + 16)
                let nz = ShortChunkReader.readFloatLE(data, at: base + 20)
                let u = ShortChunkReader.readFloatLE(data, at: base + 24)
                let v = ShortChunkReader.readFloatLE(data, at: base + 28)
                let nVec = SIMD3<Float>(nx.isFinite ? nx : 0, ny.isFinite ? ny : 0, nz.isFinite ? nz : 1)
                let len = simd_length(nVec)
                norm = len > 0.0001 ? (nVec / len) : SIMD3<Float>(0, 0, 1)
                uv = SIMD2<Float>(u.isFinite ? u : 0, v.isFinite ? v : 0)
            } else if stride == 32 {
                // SVertex (32 bytes): pos (12), SCompactVector normal (4: z, y, x, w), texU (4), texV (4), tex (8)
                let packedN = ShortChunkReader.readUInt32LE(data, at: base + 12)
                let bz = Float(packedN & 0xFF)
                let by = Float((packedN >> 8) & 0xFF)
                let bx = Float((packedN >> 16) & 0xFF)
                let nVec = SIMD3<Float>((bx - 128.0) / 127.0, (by - 128.0) / 127.0, (bz - 128.0) / 127.0)
                let len = simd_length(nVec)
                norm = len > 0.0001 ? (nVec / len) : SIMD3<Float>(0, 0, 1)
                let u = ShortChunkReader.readFloatLE(data, at: base + 24)
                let v = ShortChunkReader.readFloatLE(data, at: base + 28)
                uv = SIMD2<Float>(u.isFinite ? u : 0, v.isFinite ? v : 0)
            } else {
                norm = SIMD3<Float>(0, 0, 1)
                uv = SIMD2<Float>(0, 0)
            }

            vertices.append(GeometryVertex(position: pos, normal: norm, uv: uv))
        }

        return (vertices, stride)
    }

    /// Exact implementation of `SPolygonIndices::GetTriangles` from `Main/GGeometry.cpp`.
    private static func triangulatePolygons(
        indices: [UInt16],
        polys: [UInt16],
        vertexCount: Int,
        baseOffset: UInt32
    ) -> [UInt32] {
        guard !indices.isEmpty, polys.count >= 2 else { return [] }
        var out: [UInt32] = []
        out.reserveCapacity(max(0, indices.count - (polys.count - 1) * 2) * 3)

        var i1 = 0
        var i2 = 2
        var nPoly = 1

        while nPoly < polys.count && i2 < indices.count && i1 < indices.count {
            let v0 = Int(indices[i1])
            let v1 = Int(indices[i2 - 1])
            let v2 = Int(indices[i2])
            if v0 < vertexCount && v1 < vertexCount && v2 < vertexCount {
                out.append(baseOffset + UInt32(v0))
                out.append(baseOffset + UInt32(v1))
                out.append(baseOffset + UInt32(v2))
            }
            i2 += 1
            if i2 >= Int(polys[nPoly]) {
                i1 = Int(polys[nPoly])
                i2 = i1 + 2
                nPoly += 1
            }
        }
        return out
    }
}
