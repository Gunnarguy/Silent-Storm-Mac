import AppKit
import Metal
import MetalKit
import SwiftUI
import simd
import OpenStormCore

public enum MeshShadingMode: String, CaseIterable, Identifiable, Sendable {
    case lit = "Textured"
    case hologram = "Hologram"
    case normals = "Surface normals"
    case uv = "UV map"

    public var id: String { rawValue }
    public var shaderIndex: UInt32 {
        switch self {
        case .lit: return 0
        case .normals: return 1
        case .uv: return 2
        case .hologram: return 3
        }
    }
}

private struct Uniforms {
    var mvpMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var mode: UInt32
    var wireframePass: UInt32
    var hasBoundTexture: UInt32
    var timeSeconds: Float
}

@MainActor
public final class MetalGeometryCoordinator: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let samplerState: MTLSamplerState

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount: Int = 0
    private let sampleCount: Int
    private var boundTexture: MTLTexture?
    private var loadedGeometryKey: String?
    private var loadedTextureKey: String?
    private var meshCenter: SIMD3<Float> = .zero
    private var meshRadius: Float = 1.0
    private let startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    public var yaw: Float = 0.6
    public var pitch: Float = 0.35
    public var zoom: Float = 2.4
    public var autoRotate: Bool = true
    public var showWireframe: Bool = false
    public var shadingMode: MeshShadingMode = .lit

    public init?(mtkView: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            return nil
        }
        self.device = dev
        self.commandQueue = queue

        mtkView.device = dev
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.sampleCount = dev.supportsTextureSampleCount(4) ? 4 : 1
        self.sampleCount = mtkView.sampleCount
        mtkView.clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0)
        mtkView.preferredFramesPerSecond = 60

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            packed_float3 position;
            packed_float3 normal;
            packed_float2 uv;
        };

        struct Uniforms {
            float4x4 mvpMatrix;
            float4x4 modelMatrix;
            uint mode;
            uint wireframePass;
            uint hasBoundTexture;
            float timeSeconds;
        };

        struct VertexOut {
            float4 position [[position]];
            float3 worldNormal;
            float3 localPos;
            float2 uv;
        };

        vertex VertexOut vertex_main(
            const device VertexIn* vertices [[buffer(0)]],
            constant Uniforms& uniforms [[buffer(1)]],
            uint vid [[vertex_id]]
        ) {
            VertexOut out;
            float3 pos = float3(vertices[vid].position);
            float3 nrm = float3(vertices[vid].normal);
            out.position = uniforms.mvpMatrix * float4(pos, 1.0);
            if (uniforms.wireframePass != 0) {
                out.position.z -= 0.0005 * out.position.w;
            }
            out.worldNormal = normalize((uniforms.modelMatrix * float4(nrm, 0.0)).xyz);
            out.localPos = pos;
            out.uv = float2(vertices[vid].uv);
            return out;
        }

        fragment float4 fragment_main(
            VertexOut in [[stage_in]],
            constant Uniforms& uniforms [[buffer(1)]],
            texture2d<float> albedoTex [[texture(0)]],
            sampler linearSampler [[sampler(0)]]
        ) {
            if (uniforms.wireframePass != 0) {
                return float4(0.25, 0.92, 0.78, 0.90);
            }
            float3 n = normalize(in.worldNormal);
            if (uniforms.mode == 1) {
                return float4(n * 0.5 + 0.5, 1.0);
            } else if (uniforms.mode == 2) {
                if (uniforms.hasBoundTexture != 0) {
                    float4 sampled = albedoTex.sample(linearSampler, fract(in.uv));
                    return float4(sampled.rgb, 1.0);
                }
                return float4(fract(in.uv.x), fract(in.uv.y), 0.35, 1.0);
            } else if (uniforms.mode == 3) {
                // Tactical Scanline Hologram
                float scan = 0.5 + 0.5 * sin(in.position.y * 0.35 - uniforms.timeSeconds * 6.0);
                float rim = pow(1.0 - abs(n.z), 1.8);
                float3 holo = float3(0.08, 0.88, 0.62) * (0.35 + rim * 0.85 + scan * 0.25);
                return float4(holo, 1.0);
            }

            float3 keyLight = normalize(float3(0.55, 0.78, 0.65));
            float3 fillLight = normalize(float3(-0.65, -0.25, -0.50));
            float3 viewDir = float3(0.0, 0.0, 1.0);
            float3 halfVec = normalize(keyLight + viewDir);

            float ndotl = max(dot(n, keyLight), 0.0);
            float fill = max(dot(n, fillLight), 0.0) * 0.32;
            float spec = pow(max(dot(n, halfVec), 0.0), 42.0) * 0.38;
            float rim = pow(1.0 - max(dot(n, viewDir), 0.0), 3.0) * 0.18;
            float ambient = 0.22 + 0.16 * (n.y * 0.5 + 0.5);

            float3 baseColor = float3(0.76, 0.80, 0.86);
            if (uniforms.hasBoundTexture != 0) {
                baseColor = albedoTex.sample(linearSampler, fract(in.uv)).rgb;
            }
            float3 lit = baseColor * (ambient + ndotl * 0.82 + fill) + float3(spec) + float3(0.2, 0.7, 1.0) * rim;
            return float4(lit, 1.0);
        }
        """

        guard let library = try? dev.makeLibrary(source: shaderSource, options: nil),
              let vFunc = library.makeFunction(name: "vertex_main"),
              let fFunc = library.makeFunction(name: "fragment_main") else {
            return nil
        }

        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vFunc
        pipeDesc.fragmentFunction = fFunc
        pipeDesc.rasterSampleCount = mtkView.sampleCount
        pipeDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        pipeDesc.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat

        guard let pState = try? dev.makeRenderPipelineState(descriptor: pipeDesc) else {
            return nil
        }
        self.pipelineState = pState

        let dDesc = MTLDepthStencilDescriptor()
        dDesc.depthCompareFunction = .lessEqual
        dDesc.isDepthWriteEnabled = true
        guard let dState = dev.makeDepthStencilState(descriptor: dDesc) else {
            return nil
        }
        self.depthState = dState

        let sDesc = MTLSamplerDescriptor()
        sDesc.minFilter = .linear
        sDesc.magFilter = .linear
        sDesc.sAddressMode = .repeat
        sDesc.tAddressMode = .repeat
        sDesc.maxAnisotropy = 8
        guard let sState = dev.makeSamplerState(descriptor: sDesc) else {
            return nil
        }
        self.samplerState = sState

        super.init()
        mtkView.delegate = self
        Self.latest = self
    }

    /// The most recently created viewport, for the hub's own self-check.
    public private(set) nonisolated(unsafe) static weak var latest: MetalGeometryCoordinator?

    public func loadGeometry(_ geom: DecodedGeometry?, key: String) {
        guard key != loadedGeometryKey else { return }
        loadedGeometryKey = key
        guard let geom = geom, !geom.vertices.isEmpty, !geom.triangleIndices.isEmpty else {
            self.vertexBuffer = nil
            self.indexBuffer = nil
            self.indexCount = 0
            return
        }
        self.meshCenter = geom.center
        self.meshRadius = max(0.01, geom.boundingRadius)

        var packedFloats: [Float] = []
        packedFloats.reserveCapacity(geom.vertices.count * 8)
        for v in geom.vertices {
            packedFloats.append(v.position.x)
            packedFloats.append(v.position.y)
            packedFloats.append(v.position.z)
            packedFloats.append(v.normal.x)
            packedFloats.append(v.normal.y)
            packedFloats.append(v.normal.z)
            packedFloats.append(v.uv.x)
            packedFloats.append(v.uv.y)
        }

        self.vertexBuffer = device.makeBuffer(
            bytes: packedFloats,
            length: packedFloats.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
        self.indexBuffer = device.makeBuffer(
            bytes: geom.triangleIndices,
            length: geom.triangleIndices.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )
        self.indexCount = geom.triangleIndices.count
    }

    public func bindTexture(_ tex: DecodedMMPTexture?, key: String) {
        guard key != loadedTextureKey else { return }
        loadedTextureKey = key
        guard let tex, tex.header.width > 0, tex.header.height > 0 else {
            self.boundTexture = nil
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: tex.header.width, height: tex.header.height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let mtlTex = device.makeTexture(descriptor: desc) else { return }
        tex.rgbaPixels.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                mtlTex.replace(region: MTLRegionMake2D(0, 0, tex.header.width, tex.header.height), mipmapLevel: 0, withBytes: base, bytesPerRow: tex.header.width * 4)
            }
        }
        self.boundTexture = mtlTex
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let renderPassDesc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        if autoRotate {
            yaw += 0.008
        }
        encodeScene(into: encoder, aspect: Float(max(1.0, view.drawableSize.width) / max(1.0, view.drawableSize.height)))
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Draws one frame off screen and reads it back, for the hub's self-check. The viewport is a Metal layer, which a window snapshot leaves blank.
    public func snapshot(width: Int, height: Int) -> CGImage? {
        func target(_ format: MTLPixelFormat, multisample: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = multisample ? .private : .shared
            if multisample { d.textureType = .type2DMultisample; d.sampleCount = sampleCount }
            return device.makeTexture(descriptor: d)
        }
        guard let resolve = target(.bgra8Unorm, multisample: false), let color = sampleCount > 1 ? target(.bgra8Unorm, multisample: true) : resolve,
              let depth = target(.depth32Float, multisample: sampleCount > 1), let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0)
        if sampleCount > 1 {
            pass.colorAttachments[0].resolveTexture = resolve
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].storeAction = .store
        }
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encodeScene(into: encoder, aspect: Float(width) / Float(height))
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        resolve.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func encodeScene(into encoder: MTLRenderCommandEncoder, aspect: Float) {
        if let vBuf = vertexBuffer, let iBuf = indexBuffer, indexCount > 0 {
            let proj = Self.perspective(fovY: .pi / 4.0, aspect: aspect, near: 0.05, far: 100.0)
            let viewMat = Self.translation(SIMD3<Float>(0, 0, -zoom))
            let rotX = Self.rotationX(pitch)
            let rotY = Self.rotationY(yaw)
            let zUpToYUp = Self.rotationX(-.pi / 2.0)
            let scale = 1.0 / meshRadius
            let scaleMat = Self.scaling(SIMD3<Float>(repeating: scale))
            let centerMat = Self.translation(-meshCenter)

            let modelMat = rotX * rotY * zUpToYUp * scaleMat * centerMat
            let mvp = proj * viewMat * modelMat
            let elapsed = Float(CFAbsoluteTimeGetCurrent() - startTime)

            encoder.setRenderPipelineState(pipelineState)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(vBuf, offset: 0, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            if let bTex = boundTexture {
                encoder.setFragmentTexture(bTex, index: 0)
            }

            var solidUniforms = Uniforms(
                mvpMatrix: mvp,
                modelMatrix: rotX * rotY * zUpToYUp,
                mode: shadingMode.shaderIndex,
                wireframePass: 0,
                hasBoundTexture: boundTexture != nil ? 1 : 0,
                timeSeconds: elapsed
            )
            encoder.setTriangleFillMode(.fill)
            encoder.setVertexBytes(&solidUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&solidUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indexCount,
                indexType: .uint32,
                indexBuffer: iBuf,
                indexBufferOffset: 0
            )

            if showWireframe {
                var wireUniforms = solidUniforms
                wireUniforms.wireframePass = 1
                encoder.setTriangleFillMode(.lines)
                encoder.setVertexBytes(&wireUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&wireUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: indexCount,
                    indexType: .uint32,
                    indexBuffer: iBuf,
                    indexBufferOffset: 0
                )
            }
        }
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1.0)
        return m
    }

    private static func scaling(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_diagonal_matrix(SIMD4<Float>(s.x, s.y, s.z, 1.0))
    }

    private static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let yScale = 1.0 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let wzScale = -2.0 * far * near / zRange
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }
}

public final class InteractiveMTKView: MTKView {
    public var coordinator: MetalGeometryCoordinator?   // strong: MTKView.delegate is weak, so nothing else keeps it alive

    public override func mouseDragged(with event: NSEvent) {
        guard let c = coordinator else { return }
        c.autoRotate = false
        c.yaw += Float(event.deltaX) * 0.01
        c.pitch = max(-.pi * 0.48, min(.pi * 0.48, c.pitch + Float(event.deltaY) * 0.01))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let c = coordinator else { return }
        c.zoom = max(0.5, min(12.0, c.zoom - Float(event.scrollingDeltaY) * 0.02))
    }
}

public struct MetalGeometryViewport: NSViewRepresentable {
    public let geometry: DecodedGeometry?
    public let geometryKey: String
    public let texture: DecodedMMPTexture?
    public let textureKey: String
    public var autoRotate: Bool
    public var showWireframe: Bool
    public var shadingMode: MeshShadingMode
    /// Stops drawing, so the viewer leaves the GPU to a running game.
    public var paused: Bool

    public init(geometry: DecodedGeometry?, geometryKey: String, texture: DecodedMMPTexture?, textureKey: String,
                autoRotate: Bool, showWireframe: Bool, shadingMode: MeshShadingMode, paused: Bool) {
        self.geometry = geometry
        self.geometryKey = geometryKey
        self.texture = texture
        self.textureKey = textureKey
        self.autoRotate = autoRotate
        self.showWireframe = showWireframe
        self.shadingMode = shadingMode
        self.paused = paused
    }

    public func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView()
        if let coord = MetalGeometryCoordinator(mtkView: view) {
            view.coordinator = coord
        }
        updateNSView(view, context: context)
        return view
    }

    public func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        guard let coord = nsView.coordinator else { return }
        coord.autoRotate = autoRotate
        coord.showWireframe = showWireframe
        coord.shadingMode = shadingMode
        coord.loadGeometry(geometry, key: geometryKey)
        coord.bindTexture(texture, key: textureKey)
        nsView.isPaused = paused
    }
}
