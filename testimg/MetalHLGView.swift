import Cocoa
import Metal
import QuartzCore

// MARK: - Metal HLG View (Mode 8: FFmpeg + Metal shader)

class MetalHLGView: NSView {
    private var metalLayer: CAMetalLayer?
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var showHDR = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupMetal()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            print("[metal] no Metal device")
            return
        }
        device = dev
        commandQueue = dev.makeCommandQueue()

        let ml = CAMetalLayer()
        ml.device = dev
        ml.pixelFormat = .rgba16Float
        ml.wantsExtendedDynamicRangeContent = true
        ml.framebufferOnly = false
        ml.backgroundColor = NSColor.black.cgColor
        ml.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        // Do NOT set drawableSize — let CAMetalLayer auto-track from frame × contentsScale
        ml.frame = bounds
        ml.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(ml)
        metalLayer = ml

        buildPipeline(device: dev)
    }

    // MARK: - Shader source

    private let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct FragmentParams {
        int   hdrEnabled;
        float maxEDR;
        float imgAspect;   // image width / height
    };

    // Full-screen quad
    vertex VertexOut hlgVertex(uint vid [[vertex_id]]) {
        float2 positions[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uvs[4]       = { {0,1},   {1,1},  {0,0},  {1,0} };
        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }

    // HLG EOTF (ARIB STD-B67 inverse OETF)
    float hlg_eotf(float Ep) {
        const float a = 0.17883277;
        const float b = 0.28466892;
        const float c = 0.55991073;
        float E;
        if (Ep >= 0.5) {
            E = (exp((Ep - c) / a) + b) / 12.0;
        } else {
            E = Ep * Ep / 3.0;
        }
        return E;
    }

    // BT.2020 → Display P3 matrix
    constant float3x3 bt2020_to_p3 = float3x3(
        float3( 1.3434, -0.0653,  0.0025),  // column 0
        float3(-0.2822,  1.0760, -0.0197),   // column 1
        float3(-0.0612, -0.0107,  1.0172)    // column 2
    );

    fragment float4 hlgFragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant FragmentParams &params [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 pixel = tex.sample(s, in.uv);

        // Apply HLG EOTF → scene linear BT.2020
        float3 linear2020 = float3(
            hlg_eotf(pixel.r),
            hlg_eotf(pixel.g),
            hlg_eotf(pixel.b)
        );

        // BT.2020 → Display P3
        float3 p3 = bt2020_to_p3 * linear2020;
        p3 = clamp(p3, 0.0, 100.0);

        if (params.hdrEnabled) {
            // HDR: output EDR values (scale for HLG peak ~3.77x SDR)
            return float4(p3 * 3.77, 1.0);
        } else {
            // SDR: Reinhard tone map + gamma 2.2
            float3 mapped = p3 / (p3 + 1.0);
            mapped = pow(mapped, float3(1.0 / 2.2));
            return float4(mapped, 1.0);
        }
    }
    """;

    private func buildPipeline(device: MTLDevice) {
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction   = library.makeFunction(name: "hlgVertex")
            desc.fragmentFunction = library.makeFunction(name: "hlgFragment")
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("[metal] pipeline error: \(error)")
        }
    }

    // MARK: - Upload decoded image

    func configure(decoded: DecodedImageData, hdr: Bool, colorSpace: CGColorSpace? = nil) {
        showHDR = hdr
        if let cs = colorSpace {
            metalLayer?.colorspace = cs
        }
        guard let device else { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm,
            width: decoded.width,
            height: decoded.height,
            mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            print("[metal] texture creation failed")
            return
        }
        tex.replace(region: MTLRegionMake2D(0, 0, decoded.width, decoded.height),
                    mipmapLevel: 0,
                    withBytes: decoded.data,
                    bytesPerRow: decoded.stride)
        texture = tex
        render()
    }

    func setHDR(_ on: Bool) {
        showHDR = on
        render()
    }

    // MARK: - Render

    private func render() {
        guard let metalLayer, let commandQueue, let pipelineState,
              let texture, let drawable = metalLayer.nextDrawable() else { return }

        let drawW = Double(drawable.texture.width)
        let drawH = Double(drawable.texture.height)

        // Compute letterboxed/pillarboxed viewport to maintain aspect ratio
        let imgAspect = Double(texture.width) / Double(texture.height)
        let drawAspect = drawW / drawH
        let vpX, vpY, vpW, vpH: Double
        if imgAspect > drawAspect {
            // Image wider than view → pillarbox (black bars top/bottom)
            vpW = drawW
            vpH = drawW / imgAspect
            vpX = 0
            vpY = (drawH - vpH) / 2
        } else {
            // Image taller than view → letterbox (black bars left/right)
            vpH = drawH
            vpW = drawH * imgAspect
            vpX = (drawW - vpW) / 2
            vpY = 0
        }

        struct FragmentParams {
            var hdrEnabled: Int32
            var maxEDR: Float
            var imgAspect: Float
        }
        var params = FragmentParams(
            hdrEnabled: showHDR ? 1 : 0,
            maxEDR: Float(NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0),
            imgAspect: Float(imgAspect)
        )

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(pipelineState)
        enc.setViewport(MTLViewport(originX: vpX, originY: vpY,
                                    width: vpW, height: vpH,
                                    znear: 0, zfar: 1))
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<FragmentParams>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cb.present(drawable)
        cb.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        metalLayer?.contentsScale = window?.backingScaleFactor ?? 2.0
        render()
    }

    override func layout() {
        super.layout()
        metalLayer?.frame = bounds
        render()
    }
}
