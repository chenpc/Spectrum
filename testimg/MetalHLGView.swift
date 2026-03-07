import Cocoa
import Metal
import QuartzCore

// MARK: - Metal HLG View (Mode 7: CGImage + Metal HLG shader)

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
        ml.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        ml.backgroundColor = NSColor.black.cgColor
        ml.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
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
        float imgAspect;
    };

    vertex VertexOut hlgVertex(uint vid [[vertex_id]]) {
        float2 positions[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uvs[4]       = { {0,1},   {1,1},  {0,0},  {1,0} };
        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }

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

    // BT.2020 → Display P3 (precise, from ICC spec)
    // Derived: P3_from_XYZ * XYZ_from_BT2020
    constant float3x3 bt2020_to_p3 = float3x3(
        float3( 1.3437, -0.0653,  0.0028),
        float3(-0.2825,  1.0762, -0.0196),
        float3(-0.0611, -0.0109,  1.0168)
    );

    // BT.2100 HLG OOTF: scene-linear → display-linear
    // Applies system gamma (1.2 for nominal HLG) to luminance channel
    float3 hlg_ootf(float3 rgb, float gamma) {
        float Ys = dot(rgb, float3(0.2627, 0.6780, 0.0593));  // BT.2020 luminance
        if (Ys <= 0.0) return float3(0.0);
        float factor = pow(Ys, gamma - 1.0);
        return rgb * factor;
    }

    fragment float4 hlgFragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant FragmentParams &params [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 pixel = tex.sample(s, in.uv);

        // Step 1: HLG inverse OETF → scene-linear BT.2020
        float3 sceneLinear = float3(
            hlg_eotf(pixel.r),
            hlg_eotf(pixel.g),
            hlg_eotf(pixel.b)
        );

        // Step 2: OOTF — scene-linear → display-linear (system gamma = 1.2)
        float3 displayLinear = hlg_ootf(sceneLinear, 1.2);

        // Step 3: BT.2020 → Display P3 gamut conversion
        float3 p3 = bt2020_to_p3 * displayLinear;
        p3 = max(p3, 0.0);

        if (params.hdrEnabled) {
            // EDR output: scale by maxEDR so peak white maps to screen headroom
            // HLG nominal peak after OOTF(1.2) ≈ 1.0, scale to available EDR
            float scale = params.maxEDR;
            return float4(p3 * scale, 1.0);
        } else {
            // SDR: Reinhard tone map + sRGB gamma
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

    // MARK: - Configure from CGImage

    func configure(cgImage: CGImage, hdr: Bool, colorSpace: CGColorSpace? = nil) {
        showHDR = hdr
        // Layer colorspace stays extendedLinearDisplayP3 — shader outputs linear P3
        guard let device else { return }
        guard let extracted = extractRGBA16(from: cgImage) else {
            print("[metal] failed to extract RGBA16 from CGImage")
            return
        }
        defer { free(extracted.data) }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm,
            width: extracted.width,
            height: extracted.height,
            mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            print("[metal] texture creation failed")
            return
        }
        tex.replace(region: MTLRegionMake2D(0, 0, extracted.width, extracted.height),
                    mipmapLevel: 0,
                    withBytes: extracted.data,
                    bytesPerRow: extracted.stride)
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

        let imgAspect = Double(texture.width) / Double(texture.height)
        let drawAspect = drawW / drawH
        let vpX, vpY, vpW, vpH: Double
        if imgAspect > drawAspect {
            vpW = drawW
            vpH = drawW / imgAspect
            vpX = 0
            vpY = (drawH - vpH) / 2
        } else {
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
