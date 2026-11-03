import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum MMPPixelFormat: UInt32, Sendable, CaseIterable {
    case dxt1 = 1
    case dxt2 = 2
    case dxt3 = 3
    case dxt4 = 4
    case dxt5 = 5
    case a8r8g8b8 = 6
    case a4r4g4b4 = 7
    case r5g6b5 = 8
    case a1r5g5b5 = 9

    public var displayName: String {
        switch self {
        case .dxt1: return "CF_DXT1 (BC1)"
        case .dxt2: return "CF_DXT2 (BC2 Premul)"
        case .dxt3: return "CF_DXT3 (BC2)"
        case .dxt4: return "CF_DXT4 (BC3 Premul)"
        case .dxt5: return "CF_DXT5 (BC3)"
        case .a8r8g8b8: return "CF_A8R8G8B8 (BGRA8)"
        case .a4r4g4b4: return "CF_A4R4G4B4 (16-bit)"
        case .r5g6b5: return "CF_R5G6B5 (16-bit)"
        case .a1r5g5b5: return "CF_A1R5G5B5 (16-bit)"
        }
    }
}

public struct MMPHeader: Sendable {
    public static let signature: UInt32 = 0x00504D4D // "MMP\0"

    public let format: MMPPixelFormat
    public let averageColorBGRA: UInt32
    public let width: Int
    public let height: Int
    public let mipLevels: Int

    public init?(data: Data) {
        guard data.count >= 24 else { return nil }
        let sig = ShortChunkReader.readUInt32LE(data, at: 0)
        guard sig == Self.signature else { return nil }
        let rawFmt = ShortChunkReader.readUInt32LE(data, at: 4)
        guard let fmt = MMPPixelFormat(rawValue: rawFmt) else { return nil }
        self.format = fmt
        self.averageColorBGRA = ShortChunkReader.readUInt32LE(data, at: 8)
        self.width = Int(ShortChunkReader.readInt32LE(data, at: 12))
        self.height = Int(ShortChunkReader.readInt32LE(data, at: 16))
        self.mipLevels = Int(ShortChunkReader.readInt32LE(data, at: 20))
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
    }
}

public struct DecodedMMPTexture: Sendable {
    public let header: MMPHeader
    public let rgbaPixels: [UInt8] // width * height * 4

    public func makeCGImage() -> CGImage? {
        let width = header.width
        let height = header.height
        let bytesPerRow = width * 4
        let cfData = Data(rgbaPixels) as CFData
        guard let provider = CGDataProvider(data: cfData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    public func writePNG(to url: URL) throws {
        guard let cgImage = makeCGImage() else {
            throw NSError(domain: "MMPTextureDecoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "MMPTextureDecoder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "MMPTextureDecoder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG write"])
        }
    }
}

/// Decodes Silent Storm `.mmp` textures (`TexConv/mmpFormat.h`, `Main/GTexture.cpp`).
public enum MMPTextureDecoder {
    public static func decode(_ data: Data) -> DecodedMMPTexture? {
        guard let header = MMPHeader(data: data) else { return nil }
        let w = header.width
        let h = header.height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)

        data.withUnsafeBytes { raw in
            let payloadOffset = 24
            let available = raw.count - payloadOffset
            guard available > 0 else { return }

            switch header.format {
            case .a8r8g8b8:
                let count = min(w * h, available / 4)
                for i in 0..<count {
                    let p = payloadOffset + i * 4
                    let b = raw[p]
                    let g = raw[p + 1]
                    let r = raw[p + 2]
                    let a = raw[p + 3]
                    let dst = i * 4
                    rgba[dst] = r
                    rgba[dst + 1] = g
                    rgba[dst + 2] = b
                    rgba[dst + 3] = a
                }
            case .r5g6b5:
                let count = min(w * h, available / 2)
                for i in 0..<count {
                    let p = payloadOffset + i * 2
                    let v = UInt16(raw[p]) | (UInt16(raw[p + 1]) << 8)
                    let r = UInt8(((v >> 11) & 0x1F) * 255 / 31)
                    let g = UInt8(((v >> 5) & 0x3F) * 255 / 63)
                    let b = UInt8((v & 0x1F) * 255 / 31)
                    let dst = i * 4
                    rgba[dst] = r
                    rgba[dst + 1] = g
                    rgba[dst + 2] = b
                    rgba[dst + 3] = 255
                }
            case .a1r5g5b5:
                let count = min(w * h, available / 2)
                for i in 0..<count {
                    let p = payloadOffset + i * 2
                    let v = UInt16(raw[p]) | (UInt16(raw[p + 1]) << 8)
                    let a: UInt8 = ((v >> 15) & 1) != 0 ? 255 : 0
                    let r = UInt8(((v >> 10) & 0x1F) * 255 / 31)
                    let g = UInt8(((v >> 5) & 0x1F) * 255 / 31)
                    let b = UInt8((v & 0x1F) * 255 / 31)
                    let dst = i * 4
                    rgba[dst] = r
                    rgba[dst + 1] = g
                    rgba[dst + 2] = b
                    rgba[dst + 3] = a
                }
            case .a4r4g4b4:
                let count = min(w * h, available / 2)
                for i in 0..<count {
                    let p = payloadOffset + i * 2
                    let v = UInt16(raw[p]) | (UInt16(raw[p + 1]) << 8)
                    let a = UInt8(((v >> 12) & 0x0F) * 17)
                    let r = UInt8(((v >> 8) & 0x0F) * 17)
                    let g = UInt8(((v >> 4) & 0x0F) * 17)
                    let b = UInt8((v & 0x0F) * 17)
                    let dst = i * 4
                    rgba[dst] = r
                    rgba[dst + 1] = g
                    rgba[dst + 2] = b
                    rgba[dst + 3] = a
                }
            case .dxt1:
                decodeDXT1(raw: raw, offset: payloadOffset, width: w, height: h, into: &rgba)
            case .dxt2, .dxt3:
                decodeDXT3(raw: raw, offset: payloadOffset, width: w, height: h, into: &rgba)
            case .dxt4, .dxt5:
                decodeDXT5(raw: raw, offset: payloadOffset, width: w, height: h, into: &rgba)
            }
        }

        return DecodedMMPTexture(header: header, rgbaPixels: rgba)
    }

    @inline(__always)
    private static func unpackRGB565(_ c: UInt16) -> (Int, Int, Int) {
        let r = Int((c >> 11) & 0x1F) * 255 / 31
        let g = Int((c >> 5) & 0x3F) * 255 / 63
        let b = Int(c & 0x1F) * 255 / 31
        return (r, g, b)
    }

    private static func decodeDXT1(raw: UnsafeRawBufferPointer, offset: Int, width: Int, height: Int, into rgba: inout [UInt8]) {
        let blocksX = max(1, (width + 3) / 4)
        let blocksY = max(1, (height + 3) / 4)
        var pos = offset

        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                guard pos + 8 <= raw.count else { return }
                let c0 = UInt16(raw[pos]) | (UInt16(raw[pos + 1]) << 8)
                let c1 = UInt16(raw[pos + 2]) | (UInt16(raw[pos + 3]) << 8)
                let bits = UInt32(raw[pos + 4])
                    | (UInt32(raw[pos + 5]) << 8)
                    | (UInt32(raw[pos + 6]) << 16)
                    | (UInt32(raw[pos + 7]) << 24)
                pos += 8

                let (r0, g0, b0) = unpackRGB565(c0)
                let (r1, g1, b1) = unpackRGB565(c1)

                var palette: [(UInt8, UInt8, UInt8, UInt8)] = [
                    (UInt8(r0), UInt8(g0), UInt8(b0), 255),
                    (UInt8(r1), UInt8(g1), UInt8(b1), 255),
                    (0, 0, 0, 255),
                    (0, 0, 0, 255)
                ]
                if c0 > c1 {
                    palette[2] = (UInt8((2 * r0 + r1) / 3), UInt8((2 * g0 + g1) / 3), UInt8((2 * b0 + b1) / 3), 255)
                    palette[3] = (UInt8((r0 + 2 * r1) / 3), UInt8((g0 + 2 * g1) / 3), UInt8((b0 + 2 * b1) / 3), 255)
                } else {
                    palette[2] = (UInt8((r0 + r1) / 2), UInt8((g0 + g1) / 2), UInt8((b0 + b1) / 2), 255)
                    palette[3] = (0, 0, 0, 0)
                }

                for py in 0..<4 {
                    let y = by * 4 + py
                    if y >= height { continue }
                    for px in 0..<4 {
                        let x = bx * 4 + px
                        if x >= width { continue }
                        let idx = Int((bits >> (2 * (py * 4 + px))) & 0x3)
                        let color = palette[idx]
                        let dst = (y * width + x) * 4
                        rgba[dst] = color.0
                        rgba[dst + 1] = color.1
                        rgba[dst + 2] = color.2
                        rgba[dst + 3] = color.3
                    }
                }
            }
        }
    }

    private static func decodeDXT3(raw: UnsafeRawBufferPointer, offset: Int, width: Int, height: Int, into rgba: inout [UInt8]) {
        let blocksX = max(1, (width + 3) / 4)
        let blocksY = max(1, (height + 3) / 4)
        var pos = offset

        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                guard pos + 16 <= raw.count else { return }
                var alphaBits: UInt64 = 0
                for k in 0..<8 {
                    alphaBits |= UInt64(raw[pos + k]) << (8 * k)
                }
                let c0 = UInt16(raw[pos + 8]) | (UInt16(raw[pos + 9]) << 8)
                let c1 = UInt16(raw[pos + 10]) | (UInt16(raw[pos + 11]) << 8)
                let bits = UInt32(raw[pos + 12])
                    | (UInt32(raw[pos + 13]) << 8)
                    | (UInt32(raw[pos + 14]) << 16)
                    | (UInt32(raw[pos + 15]) << 24)
                pos += 16

                let (r0, g0, b0) = unpackRGB565(c0)
                let (r1, g1, b1) = unpackRGB565(c1)
                let palette: [(UInt8, UInt8, UInt8)] = [
                    (UInt8(r0), UInt8(g0), UInt8(b0)),
                    (UInt8(r1), UInt8(g1), UInt8(b1)),
                    (UInt8((2 * r0 + r1) / 3), UInt8((2 * g0 + g1) / 3), UInt8((2 * b0 + b1) / 3)),
                    (UInt8((r0 + 2 * r1) / 3), UInt8((g0 + 2 * g1) / 3), UInt8((b0 + 2 * b1) / 3))
                ]

                for py in 0..<4 {
                    let y = by * 4 + py
                    if y >= height { continue }
                    for px in 0..<4 {
                        let x = bx * 4 + px
                        if x >= width { continue }
                        let pIndex = py * 4 + px
                        let cIdx = Int((bits >> (2 * pIndex)) & 0x3)
                        let a4 = UInt8((alphaBits >> (4 * pIndex)) & 0xF)
                        let color = palette[cIdx]
                        let dst = (y * width + x) * 4
                        rgba[dst] = color.0
                        rgba[dst + 1] = color.1
                        rgba[dst + 2] = color.2
                        rgba[dst + 3] = a4 * 17
                    }
                }
            }
        }
    }

    private static func decodeDXT5(raw: UnsafeRawBufferPointer, offset: Int, width: Int, height: Int, into rgba: inout [UInt8]) {
        let blocksX = max(1, (width + 3) / 4)
        let blocksY = max(1, (height + 3) / 4)
        var pos = offset

        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                guard pos + 16 <= raw.count else { return }
                let a0 = Int(raw[pos])
                let a1 = Int(raw[pos + 1])
                var alphaBits: UInt64 = 0
                for k in 0..<6 {
                    alphaBits |= UInt64(raw[pos + 2 + k]) << (8 * k)
                }

                var alphas = [UInt8](repeating: 0, count: 8)
                alphas[0] = UInt8(a0)
                alphas[1] = UInt8(a1)
                if a0 > a1 {
                    alphas[2] = UInt8((6 * a0 + 1 * a1) / 7)
                    alphas[3] = UInt8((5 * a0 + 2 * a1) / 7)
                    alphas[4] = UInt8((4 * a0 + 3 * a1) / 7)
                    alphas[5] = UInt8((3 * a0 + 4 * a1) / 7)
                    alphas[6] = UInt8((2 * a0 + 5 * a1) / 7)
                    alphas[7] = UInt8((1 * a0 + 6 * a1) / 7)
                } else {
                    alphas[2] = UInt8((4 * a0 + 1 * a1) / 5)
                    alphas[3] = UInt8((3 * a0 + 2 * a1) / 5)
                    alphas[4] = UInt8((2 * a0 + 3 * a1) / 5)
                    alphas[5] = UInt8((1 * a0 + 4 * a1) / 5)
                    alphas[6] = 0
                    alphas[7] = 255
                }

                let c0 = UInt16(raw[pos + 8]) | (UInt16(raw[pos + 9]) << 8)
                let c1 = UInt16(raw[pos + 10]) | (UInt16(raw[pos + 11]) << 8)
                let bits = UInt32(raw[pos + 12])
                    | (UInt32(raw[pos + 13]) << 8)
                    | (UInt32(raw[pos + 14]) << 16)
                    | (UInt32(raw[pos + 15]) << 24)
                pos += 16

                let (r0, g0, b0) = unpackRGB565(c0)
                let (r1, g1, b1) = unpackRGB565(c1)
                let palette: [(UInt8, UInt8, UInt8)] = [
                    (UInt8(r0), UInt8(g0), UInt8(b0)),
                    (UInt8(r1), UInt8(g1), UInt8(b1)),
                    (UInt8((2 * r0 + r1) / 3), UInt8((2 * g0 + g1) / 3), UInt8((2 * b0 + b1) / 3)),
                    (UInt8((r0 + 2 * r1) / 3), UInt8((g0 + 2 * g1) / 3), UInt8((b0 + 2 * b1) / 3))
                ]

                for py in 0..<4 {
                    let y = by * 4 + py
                    if y >= height { continue }
                    for px in 0..<4 {
                        let x = bx * 4 + px
                        if x >= width { continue }
                        let pIndex = py * 4 + px
                        let cIdx = Int((bits >> (2 * pIndex)) & 0x3)
                        let aIdx = Int((alphaBits >> (3 * pIndex)) & 0x7)
                        let color = palette[cIdx]
                        let dst = (y * width + x) * 4
                        rgba[dst] = color.0
                        rgba[dst + 1] = color.1
                        rgba[dst + 2] = color.2
                        rgba[dst + 3] = alphas[aIdx]
                    }
                }
            }
        }
    }
}
