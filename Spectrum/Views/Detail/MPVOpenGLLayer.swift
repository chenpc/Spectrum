import AppKit
import OpenGL.GL3
import CoreVideo
import Darwin

/// Boxed context for MDK prepare callback — carries the layer reference
/// and load generation so stale callbacks can be detected and discarded.
private final class PrepareContext {
    unowned let layer: MPVOpenGLLayer
    let generation: Int
    init(layer: MPVOpenGLLayer, generation: Int) {
        self.layer = layer; self.generation = generation
    }
}

// MARK: - Display Peak Nits

/// Query the display's actual peak HDR luminance via CoreDisplay private API.
func displayPeakNits() -> Int {
    typealias FnCreateInfo = @convention(c) (UInt32) -> CFDictionary?
    guard let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
          let sym = dlsym(cd, "CoreDisplay_DisplayCreateInfoDictionary") else { return 400 }
    let fn = unsafeBitCast(sym, to: FnCreateInfo.self)
    guard let dict = fn(CGMainDisplayID()) as? [String: Any] else { return 400 }
    if let v = dict["NonReferencePeakHDRLuminance"] as? Int { return v }  // Apple Silicon
    if let v = dict["DisplayBacklight"] as? Int { return v }              // Intel
    return 400
}

// MARK: - Gyro Lens Snapshot

/// Snapshot of per-frame lens parameters captured alongside gyro matrix computation.
/// Used by the precomputation system to avoid reading GyroCoreProvider properties
/// on the render thread when a precomputed result is available, preventing races.
struct GyroLensSnapshot {
    let frameFx, frameFy, frameCx, frameCy: Float
    let frameK: [Float]
    let distortionK: [Float]
    let distortionModel: Int32
    let rLimit, frameFov, lensCorrectionAmount: Float
    let lastFetchMs: Double

    init(from core: GyroCoreProvider) {
        frameFx = core.frameFx; frameFy = core.frameFy
        frameCx = core.frameCx; frameCy = core.frameCy
        frameK = core.frameK; distortionK = core.distortionK
        distortionModel = core.distortionModel
        rLimit = core.rLimit; frameFov = core.frameFov
        lensCorrectionAmount = core.lensCorrectionAmount
        lastFetchMs = core.lastFetchMs
    }
}

// MARK: - MPVOpenGLLayer

/// CAOpenGLLayer that renders video via MDK with per-content HDR configuration.
class MPVOpenGLLayer: CAOpenGLLayer, @unchecked Sendable {

    private var cglPF:     CGLPixelFormatObj?
    private var cglCtx:    CGLContextObj?
    private var isFloat:   Bool = false

    // Frame timing — updated in draw(), read by MPVController poll (diagnostics only).
    // draw() runs on CAOpenGLLayer's dedicated rendering thread (isAsynchronous = true).
    // Doubles on arm64 are naturally aligned; single-instruction reads cannot tear.
    private var frameIntervals: [Double] = []   // last 60 inter-frame durations (seconds)
    private var lastFrameTime: CFTimeInterval = 0
    private(set) var renderFPS: Double = 0
    /// Coefficient of variation of frame intervals (stddev/mean). Lower = more stable.
    private(set) var renderCV: Double = 0
    /// 0 = jittery, 1 = perfectly stable (based on coefficient of variation of intervals)
    private(set) var renderStability: Double = 1
    /// Gyro Stability Index: RMS of inter-frame residual rotation angle (radians).
    /// Lower = more stable. Only computed when diagnosticsEnabled.
    private(set) var gyroSI: Double = 0
    private var prevMidRow: (Float, Float, Float, Float, Float, Float, Float, Float, Float)?
    private var siAngles: [Double] = []

    /// When false, frame timing measurement in draw() is skipped entirely.
    var diagnosticsEnabled: Bool = true

    /// Human-readable CALayer colorspace name (e.g. "PQ", "HLG", "sRGB").
    var layerColorspaceInfo: String {
        guard let cs = colorspace?.name as String? else { return "-" }
        if cs.contains("2100_PQ") { return "PQ" }
        if cs.contains("2100_HLG") { return "HLG" }
        if cs.contains("sRGB") || cs.contains("SRGB") { return "sRGB" }
        if cs.contains("709") { return "BT.709" }
        // Fallback: last component
        return (cs as NSString).lastPathComponent
    }

    /// Set by mpv update callback (any thread); cleared at the top of draw().
    /// arm64 Bool store/load is a single instruction — safe without a lock.
    private var pendingFrame: Bool = false

    /// Set when bounds change — forces one redraw even if paused, preventing
    /// macOS from stretching stale backing store to the new aspect ratio.
    private var lastDrawnSize: CGSize = .zero

    /// Monotonic guard: prevents audio clock jitter from causing frame index oscillation.
    /// nil = not yet initialized (first frame after load/seek). Reset on gyro reload.
    private var lastGyroFrameIdx: Int? = nil

    // Gyro matrix precomputation (double buffer)
    private let gyroPrecompQueue = DispatchQueue(label: "gyro.precomp", qos: .userInteractive)
    private var precompMats: [Float]? = nil
    private var precompFrameIdx: Int = -1
    private var precompLens: GyroLensSnapshot? = nil
    private let precompLock = NSLock()
    private let gyroCoreLock = NSLock()
    private var lastLensSnapshot: GyroLensSnapshot? = nil

    /// When true, suppress rendering until gyroCore is ready.
    /// Prevents the visual flash of an unstabilized first frame.
    var waitingForGyro: Bool = false

    // MARK: - MDK backend state

    private var mdkAPI: UnsafePointer<mdkPlayerAPI>?
    private var mdkGLAPI = mdkGLRenderAPI()
    private var mdkReady = false
    /// Incremented on each mdkLoadFile(); stale prepare callbacks check this to bail out.
    private var mdkLoadGeneration: Int = 0
    private var mdkMuted = true
    private var mdkDuration: Double = 0
    /// Timestamp (seconds) of the last frame rendered by MDK's renderVideo()
    private var mdkRenderedTime: Double = 0
    /// Human-readable name of the colorspace passed to MDK setColorSpace() (e.g. "PQ", "HLG").
    private(set) var mdkColorspaceInfo: String = "-"

    /// Video native resolution — read from mpv once, used for letterboxing.
    /// Simple blit shader for non-gyro letterbox pass.
    private var blitProg: GLuint = 0
    private var uBlitTex: GLint = -1
    /// Frame counter for AR debug logging (log first 5 frames + on resize).

    // MARK: - Gyroflow warp pipeline

    /// Set from main thread (MPVPlayerNSView.loadGyroCore); read in draw().
    var activeGyro: GyroCoreProvider?

    // Intermediate FBO — mpv renders here; warp pass reads this and writes to displayFBO
    private var stabFBO:  GLuint = 0
    private var stabTex:  GLuint = 0
    private var stabW:    GLsizei = 0
    private var stabH:    GLsizei = 0
    // Warp shader program + VBO
    private var warpProg: GLuint = 0
    private var warpVAO:  GLuint = 0     // VAO (required for Core profile)
    private var warpVBO:  GLuint = 0
    private var useCoreProfile = false
    // Per-row matrix texture (width=4, height=videoH, RGBA32F)
    private var matTexId: GLuint = 0
    private var matTexH:  Int    = 0
    // Uniform locations
    private var uTex:       GLint = -1
    private var uMatTex:    GLint = -1
    private var uVideoSize: GLint = -1
    private var uMatCount:  GLint = -1
    private var uFIn:       GLint = -1
    private var uCIn:       GLint = -1
    private var uDistK:     GLint = -1   // vec4[3] = k[12]
    private var uDistModel: GLint = -1   // int
    private var uRLimit:    GLint = -1   // float
    private var uFrameFov:  GLint = -1   // float — per-frame FOV for lens correction
    private var uLensCorr:  GLint = -1   // float — lens_correction_amount (0=full undistort, 1=none)

    // Pre-allocated draw() buffers
    private var sysViewport = (GLint(0), GLint(0), GLint(0), GLint(0))

    override init() {
        super.init()
        isAsynchronous = true
        setupGL()
        setupMDK()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - OpenGL setup

    private func setupGL() {
        // ── Progressive pixel format selection ──────────────────
        let glVersions: [CGLOpenGLProfile] = [
            kCGLOGLPVersion_3_2_Core,
            kCGLOGLPVersion_Legacy
        ]
        let glFormat10Bit: [CGLPixelFormatAttribute] = [
            kCGLPFAColorSize, _CGLPixelFormatAttribute(rawValue: 64),
            kCGLPFAColorFloat
        ]
        let glFormatOptional: [[CGLPixelFormatAttribute]] = [
            [kCGLPFABackingStore],
            [kCGLPFAAllowOfflineRenderers],
            [kCGLPFASupportsAutomaticGraphicsSwitching]
        ]

        var pf: CGLPixelFormatObj?
        var npix = GLint(0)
        var depth: GLint = 8

        outer: for ver in glVersions {
            let glBase: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(ver.rawValue),
                kCGLPFAAccelerated,
                kCGLPFADoubleBuffer
            ]
            var groups: [[CGLPixelFormatAttribute]] = [glBase, glFormat10Bit] + glFormatOptional

            for index in stride(from: groups.count - 1, through: 0, by: -1) {
                let format = groups.flatMap { $0 } + [_CGLPixelFormatAttribute(rawValue: 0)]
                let err = CGLChoosePixelFormat(format, &pf, &npix)
                if err == kCGLBadAttribute || err == kCGLBadPixelFormat || pf == nil {
                    let removed = groups.remove(at: index)
                    let names = removed.map { String($0.rawValue) }.joined(separator: ",")
                    print("[GL]   Removed attributes [\(names)], retrying...")
                } else if err == kCGLNoError {
                    useCoreProfile = (ver == kCGLOGLPVersion_3_2_Core)
                    let has10Bit = groups.contains(where: { $0 == glFormat10Bit })
                    depth = has10Bit ? 16 : 8
                    let profile = useCoreProfile ? "3.2 Core" : "Legacy"
                    print("[GL] Pixel format OK: \(profile), depth=\(depth)")
                    break outer
                }
            }
        }

        guard let pixelFormat = pf else {
            print("[GL] Failed to create any pixel format!")
            return
        }

        cglPF = pixelFormat
        isFloat = (depth > 8)
        if isFloat { contentsFormat = .RGBA16Float }

        // EDR + initial PQ colorspace (prepareForContent will set dynamically)
        wantsExtendedDynamicRangeContent = true

        // ── CGL Context creation ──────────────────────────
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        guard let context = ctx else {
            print("[GL] Failed to create CGL context!")
            return
        }
        cglCtx = context

        // Sync to vertical retrace
        var swapInterval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swapInterval)

        // Enable multi-threaded GL engine
        CGLEnable(context, kCGLCEMPEngine)

        print("[GL] CGL context created (isFloat=\(isFloat), coreProfile=\(useCoreProfile), swap=1, MPEngine=on)")

        setupWarpPipeline()
    }

    // MARK: - MDK setup

    private func setupMDK() {
        guard LibMDK.shared.ok else { return }
        let api = mdkPlayerAPI_new()!
        mdkAPI = api
        let obj = api.pointee.object!

        // Decoders: prefer VideoToolbox, fallback to FFmpeg
        var decoders: [UnsafePointer<CChar>?] = [
            ("VideoToolbox" as NSString).utf8String,
            ("FFmpeg" as NSString).utf8String,
            nil
        ]
        api.pointee.setVideoDecoders(obj, &decoders)

        // Start muted
        api.pointee.setMute(obj, true)
        mdkMuted = true

        // Configure GL render API: type=OpenGL, fbo set dynamically in draw()
        mdkGLAPI.type = MDK_RenderAPI_OpenGL
        mdkGLAPI.fbo = -1

        // Render callback: signal new frame
        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        api.pointee.setRenderCallback(obj, mdkRenderCallback(cb: { _, opaque in
            guard let opaque else { return }
            let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(opaque).takeUnretainedValue()
            layer.pendingFrame = true
            CATransaction.begin()
            layer.setNeedsDisplay()
            CATransaction.commit()
        }, opaque: selfRef))

        // Default PQ output for HDR (overridden per-content in prepareForContent)
        api.pointee.setColorSpace(obj, MDK_ColorSpace_BT2100_PQ, nil)
    }

    // MARK: - HDR configuration

    /// Apply CALayer colorspace for the given content and HDR state.
    /// When toggling off, also tells MDK to output BT.709 so the tone-mapped pixels
    /// match the sRGB CALayer colorspace (instead of PQ pixels in an sRGB container).
    func applyHDRSettings(showHDR: Bool, hdrType: VideoHDRType?) {
        if showHDR, let hdrType {
            wantsExtendedDynamicRangeContent = true
            switch hdrType {
            case .hdr10:
                colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                setMDKColorSpace(MDK_ColorSpace_BT2100_PQ, info: "PQ")
            case .dolbyVision, .slog2, .slog3:
                colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                setMDKColorSpace(MDK_ColorSpace_BT2100_PQ, info: "PQ")
            case .hlg:
                colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                setMDKColorSpace(MDK_ColorSpace_BT2100_HLG, info: "HLG")
            }
        } else {
            colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            wantsExtendedDynamicRangeContent = false
            setMDKColorSpace(MDK_ColorSpace_BT709, info: "BT.709")
        }
        pendingFrame = true
        setNeedsDisplay()
    }

    private func setMDKColorSpace(_ cs: MDK_ColorSpace, info: String) {
        guard let api = mdkAPI, let obj = api.pointee.object else { return }
        api.pointee.setColorSpace(obj, cs, nil)
        mdkColorspaceInfo = info
    }

    /// Convenience: call on new file load (always starts in HDR mode).
    func prepareForContent(hdrType: VideoHDRType?) {
        applyHDRSettings(showHDR: true, hdrType: hdrType)
    }

    // MARK: - Gyroflow warp pipeline setup

    private func setupWarpPipeline() {
        guard let cglCtx else { return }
        CGLSetCurrentContext(cglCtx)

        // ── Shader version selection based on GL profile ──
        let vsSrc:     String
        let fsSrc:     String
        let blitFsSrc: String

        if useCoreProfile {
            vsSrc     = WarpShader.vertexCore
            fsSrc     = WarpShader.fragmentCore
            blitFsSrc = WarpShader.blitFragmentCore
        } else {
            vsSrc     = WarpShader.vertexLegacy
            fsSrc     = WarpShader.fragmentLegacy
            blitFsSrc = WarpShader.blitFragmentLegacy
        }

        let vs = WarpShader.compile(GLenum(GL_VERTEX_SHADER),   vsSrc)
        let fs = WarpShader.compile(GLenum(GL_FRAGMENT_SHADER), fsSrc)
        guard vs != 0, fs != 0 else { return }

        warpProg = glCreateProgram()
        glAttachShader(warpProg, vs)
        glAttachShader(warpProg, fs)
        glBindAttribLocation(warpProg, 0, "pos")
        glLinkProgram(warpProg)
        glDeleteShader(vs); glDeleteShader(fs)

        var status = GLint(0)
        glGetProgramiv(warpProg, GLenum(GL_LINK_STATUS), &status)
        guard status == GLint(GL_TRUE) else {
            print("[Warp] Shader link failed"); warpProg = 0; return
        }

        uTex       = glGetUniformLocation(warpProg, "tex")
        uMatTex    = glGetUniformLocation(warpProg, "matTex")
        uVideoSize = glGetUniformLocation(warpProg, "videoSize")
        uMatCount  = glGetUniformLocation(warpProg, "matCount")
        uFIn       = glGetUniformLocation(warpProg, "fIn")
        uCIn       = glGetUniformLocation(warpProg, "cIn")
        uDistK     = glGetUniformLocation(warpProg, "distK")
        uDistModel = glGetUniformLocation(warpProg, "distModel")
        uRLimit    = glGetUniformLocation(warpProg, "rLimit")
        uFrameFov  = glGetUniformLocation(warpProg, "frameFov")
        uLensCorr  = glGetUniformLocation(warpProg, "lensCorr")
        let profile = useCoreProfile ? "GL 3.2 Core (#version 150)" : "Legacy (#version 120)"
        print("[Warp] Shader compiled OK (\(profile))")

        // ── VAO (required for Core profile, optional but harmless for Legacy) ──
        glGenVertexArrays(1, &warpVAO)
        glBindVertexArray(warpVAO)

        // ── Fullscreen quad VBO ──
        var verts: [Float] = [-1,-1, 1,-1, -1,1, 1,1]
        glGenBuffers(1, &warpVBO)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), warpVBO)
        verts.withUnsafeMutableBytes { ptr in
            glBufferData(GLenum(GL_ARRAY_BUFFER), GLsizeiptr(ptr.count),
                         ptr.baseAddress, GLenum(GL_STATIC_DRAW))
        }
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 8, nil)
        glBindVertexArray(0)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), 0)

        // Per-row matrix texture (RGBA32F, width=4, height set dynamically)
        glGenTextures(1, &matTexId)
        glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_NEAREST))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_NEAREST))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLint(GL_CLAMP_TO_EDGE))
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        // Intermediate FBO (size set dynamically in draw())
        glGenFramebuffers(1, &stabFBO)
        glGenTextures(1, &stabTex)
        glBindTexture(GLenum(GL_TEXTURE_2D), stabTex)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLint(GL_CLAMP_TO_EDGE))
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        // Blit shader (simple texture pass-through for non-gyro letterbox)
        let blitVs = WarpShader.compile(GLenum(GL_VERTEX_SHADER), vsSrc)
        let blitFs = WarpShader.compile(GLenum(GL_FRAGMENT_SHADER), blitFsSrc)
        if blitVs != 0 && blitFs != 0 {
            blitProg = glCreateProgram()
            glAttachShader(blitProg, blitVs)
            glAttachShader(blitProg, blitFs)
            glBindAttribLocation(blitProg, 0, "pos")
            glLinkProgram(blitProg)
            glDeleteShader(blitVs); glDeleteShader(blitFs)

            var blitStatus = GLint(0)
            glGetProgramiv(blitProg, GLenum(GL_LINK_STATUS), &blitStatus)
            if blitStatus == GLint(GL_TRUE) {
                uBlitTex = glGetUniformLocation(blitProg, "tex")
                print("[Blit] Shader compiled OK (\(profile))")
            } else {
                print("[Blit] Shader link failed"); blitProg = 0
            }
        }

    }

    /// Call from main thread to attach/detach gyro stabilization.
    func loadGyroCore(_ core: GyroCoreProvider?) {
        activeGyro = core
        lastGyroFrameIdx = nil   // reset monotonic guard
        precompMats = nil; precompFrameIdx = -1; precompLens = nil; lastLensSnapshot = nil
        prevMidRow = nil; siAngles.removeAll(); gyroSI = 0
        waitingForGyro = false   // gyro ready (or detach) -> allow rendering
        pendingFrame = true
        setNeedsDisplay()
    }

    // MARK: - CVDisplayLink (disabled — CAOpenGLLayer sync mode unreliable on modern macOS)

    func startDisplayLink() { }
    func stopDisplayLink() { }

    // MARK: - Playback control

    func loadFile(_ path: String) {
        mdkLoadFile(path)
    }

    func stop() {
        mdkStop()
    }

    var isPaused: Bool { mdkIsPaused }

    var currentTime: Double { mdkCurrentTimeSec }

    var videoDuration: Double { mdkDuration }

    var isEOFReached: Bool {
        guard let api = mdkAPI else { return false }
        let obj = api.pointee.object!
        let status = api.pointee.mediaStatus(obj)
        return status.rawValue & MDK_MediaStatus_End.rawValue != 0
    }

    func setPause(_ paused: Bool) {
        mdkSetPause(paused)
    }

    func setMute(_ muted: Bool) {
        guard let api = mdkAPI else { return }
        let obj = api.pointee.object!
        api.pointee.setMute(obj, muted)
        mdkMuted = muted
    }

    func seek(to seconds: Double) {
        mdkSeek(to: seconds)
    }

    /// Declared FPS of the loaded video (e.g. 29.97, 60).
    var videoFPS: Double {
        guard let api = mdkAPI else { return 0 }
        let obj = api.pointee.object!
        guard let info = api.pointee.mediaInfo(obj), info.pointee.nb_video > 0 else { return 0 }
        var codec = mdkVideoCodecParameters()
        MDK_VideoStreamCodecParameters(&info.pointee.video[0], &codec)
        return Double(codec.frame_rate)
    }

    // MARK: - MDK playback control

    private func mdkLoadFile(_ path: String) {
        guard let api = mdkAPI else { return }
        let obj = api.pointee.object!
        // Stop any in-progress playback/prepare before loading new media.
        // Without this, prepare() can block waiting for the previous decode to finish.
        api.pointee.setState(obj, MDK_State_Stopped)
        mdkReady = false
        mdkLoadGeneration += 1
        api.pointee.setMedia(obj, path)

        // Box layer + generation so the C callback can detect stale invocations.
        let ctx = Unmanaged.passRetained(PrepareContext(layer: self, generation: mdkLoadGeneration)).toOpaque()
        api.pointee.prepare(obj, 0, mdkPrepareCallback(cb: { position, boost, opaque in
            guard let opaque else { return true }
            let box = Unmanaged<PrepareContext>.fromOpaque(opaque).takeRetainedValue()
            let layer = box.layer
            // Stale callback from a previous load — discard.
            guard layer.mdkLoadGeneration == box.generation else { return false }
            guard position >= 0 else { return false }
            // Read media info for duration and color space
            if let api = layer.mdkAPI, let rawObj = api.pointee.object,
               let info = api.pointee.mediaInfo(rawObj) {
                layer.mdkDuration = Double(info.pointee.duration) / 1000.0
                if info.pointee.nb_video > 0 {
                    var codec = mdkVideoCodecParameters()
                    MDK_VideoStreamCodecParameters(&info.pointee.video[0], &codec)
                    let cs = codec.color_space
                    let doviProfile = codec.dovi_profile

                    let mdkCS: MDK_ColorSpace
                    let csInfo: String
                    let layerCS: CFString
                    let edr: Bool

                    if doviProfile == 8 {
                        mdkCS = MDK_ColorSpace_BT2100_PQ; csInfo = "PQ"
                        layerCS = CGColorSpace.itur_2100_PQ; edr = true
                    } else if cs == MDK_ColorSpace_BT2100_HLG {
                        mdkCS = MDK_ColorSpace_BT2100_HLG; csInfo = "HLG"
                        layerCS = CGColorSpace.itur_2100_HLG; edr = true
                    } else if cs == MDK_ColorSpace_BT2100_PQ {
                        mdkCS = MDK_ColorSpace_BT2100_PQ; csInfo = "PQ"
                        layerCS = CGColorSpace.itur_2100_PQ; edr = true
                    } else {
                        mdkCS = MDK_ColorSpace_BT709; csInfo = "BT.709"
                        layerCS = CGColorSpace.sRGB; edr = false
                    }

                    api.pointee.setColorSpace(rawObj, mdkCS, nil)
                    layer.mdkColorspaceInfo = csInfo
                    CATransaction.begin()
                    layer.colorspace = CGColorSpace(name: layerCS)
                    layer.wantsExtendedDynamicRangeContent = edr
                    CATransaction.commit()
                }
            }
            layer.mdkReady = true
            return true
        }, opaque: ctx), MDK_SeekFlag_FromStart)

        api.pointee.setState(obj, MDK_State_Playing)
    }

    private func mdkStop() {
        guard let api = mdkAPI else { return }
        let obj = api.pointee.object!
        api.pointee.setState(obj, MDK_State_Stopped)
        api.pointee.setMedia(obj, nil)
        mdkReady = false
        mdkRenderedTime = 0
        mdkDuration = 0
    }

    private var mdkIsPaused: Bool {
        guard let api = mdkAPI else { return true }
        let obj = api.pointee.object!
        return api.pointee.state(obj) == MDK_State_Paused
    }

    private var mdkCurrentTimeSec: Double {
        guard let api = mdkAPI else { return 0 }
        let obj = api.pointee.object!
        return Double(api.pointee.position(obj)) / 1000.0
    }

    private func mdkSetPause(_ paused: Bool) {
        guard let api = mdkAPI else { return }
        let obj = api.pointee.object!
        api.pointee.setState(obj, paused ? MDK_State_Paused : MDK_State_Playing)
    }

    private func mdkSeek(to seconds: Double) {
        guard let api = mdkAPI else { return }
        let obj = api.pointee.object!
        let ms = Int64(seconds * 1000)
        let flags = MDK_SeekFlag(rawValue: MDK_SeekFlag_FromStart.rawValue | MDK_SeekFlag_KeyFrame.rawValue)
        _ = api.pointee.seekWithFlags(obj, ms, flags, mdkSeekCallback(cb: nil, opaque: nil))
    }

    // MARK: - CAOpenGLLayer overrides

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        cglPF ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        cglCtx ?? super.copyCGLContext(forPixelFormat: pf)
    }

    override func canDraw(inCGLContext ctx: CGLContextObj,
                          pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval,
                          displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        if waitingForGyro { return false }
        guard mdkAPI != nil, mdkReady else { return false }
        if bounds.size != lastDrawnSize { return true }
        return pendingFrame
    }

    override func draw(inCGLContext ctx: CGLContextObj,
                       pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval,
                       displayTime ts: UnsafePointer<CVTimeStamp>?) {
        pendingFrame = false
        guard mdkAPI != nil, mdkReady else { return }

        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }

        // ── Display FBO: system-managed triple-buffer ────────────────────────
        withUnsafeMutablePointer(to: &sysViewport) {
            $0.withMemoryRebound(to: GLint.self, capacity: 4) {
                glGetIntegerv(GLenum(GL_VIEWPORT), $0)
            }
        }
        let fboW = sysViewport.2 > 0 ? sysViewport.2 : GLsizei(max(1, bounds.size.width))
        let fboH = sysViewport.3 > 0 ? sysViewport.3 : GLsizei(max(1, bounds.size.height))
        let w = GLsizei(max(1, bounds.size.width))
        let h = GLsizei(max(1, bounds.size.height))

        var displayFBO = GLint(0)
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &displayFBO)

        // ── Gyro matrix — computed AFTER Pass 1 (uses renderVideo timestamp) ──
        var gyroMatrices: [Float]? = nil
        var gyroMatChanged = false
        var gyroFrameRepeated = false
        var gyroRenderTime: Double = 0
        var gyroCurrentFi: Int = -1

        // ── Intermediate FBO sizing ──────────────────────────────────────────
        let gyroActive = activeGyro?.isReady == true && warpProg != 0
        let vidW: GLsizei, vidH: GLsizei
        if gyroActive {
            vidW = GLsizei(activeGyro!.gyroVideoW)
            vidH = GLsizei(activeGyro!.gyroVideoH)
        } else {
            vidW = w; vidH = h
        }

        if stabW != vidW || stabH != vidH {
            stabW = vidW; stabH = vidH
            glBindTexture(GLenum(GL_TEXTURE_2D), stabTex)
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, isFloat ? 0x881A : GLint(GL_RGBA),
                         vidW, vidH, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), stabFBO)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                   GLenum(GL_TEXTURE_2D), stabTex, 0)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(displayFBO))
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        }

        lastDrawnSize = bounds.size

        // ── Pass 1: MDK video decode → FBO ────────────────────────────────────
        guard let api = mdkAPI else { return }
        let obj = api.pointee.object!
        mdkGLAPI.fbo = GLint(stabFBO)
        withUnsafeMutablePointer(to: &mdkGLAPI) { glPtr in
            api.pointee.setRenderAPI(obj, OpaquePointer(glPtr), nil)
        }
        api.pointee.setVideoSurfaceSize(obj, Int32(vidW), Int32(vidH), nil)
        let ts = api.pointee.renderVideo(obj, nil)
        if ts >= 0 { mdkRenderedTime = ts }

        // ── Gyro matrix AFTER Pass 1 (uses renderVideo timestamp) ────────────
        if let core = activeGyro, core.isReady {
            let renderTime = max(0, mdkRenderedTime)
            var fi = max(0, min(Int((renderTime * core.gyroFps).rounded()),
                                core.frameCount - 1))
            if let lastFi = lastGyroFrameIdx {
                let delta = fi - lastFi
                if delta < 0 && delta >= -2 { fi = lastFi }
            }
            if fi == lastGyroFrameIdx {
                gyroFrameRepeated = true
            } else {
                lastGyroFrameIdx = fi

                // Check precomputed result for this frame index
                precompLock.lock()
                let cachedMats = precompMats
                let cachedIdx = precompFrameIdx
                let cachedLens = precompLens
                precompMats = nil; precompFrameIdx = -1; precompLens = nil
                precompLock.unlock()

                if cachedIdx == fi, let mats = cachedMats, let lens = cachedLens {
                    // Precomp hit — use cached matrices + lens snapshot
                    gyroMatrices = mats
                    gyroMatChanged = true
                    lastLensSnapshot = lens
                } else if gyroCoreLock.try() {
                    // Precomp miss — sync fallback (only if precomp not in-flight)
                    if let (buf, changed) = core.computeMatrixAtTime(timeSec: renderTime) {
                        gyroMatrices = Array(buf)
                        gyroMatChanged = changed
                    }
                    lastLensSnapshot = GyroLensSnapshot(from: core)
                    gyroCoreLock.unlock()
                } else {
                    // Precomp in-flight — reuse previous frame's matTex
                    gyroFrameRepeated = true
                }
            }
            gyroRenderTime = max(0, mdkRenderedTime)
            gyroCurrentFi = fi

            // ── Stability Index (SI) — only when diagnostics badge is visible ──
            if diagnosticsEnabled, let mats = gyroMatrices {
                let vH = Int(core.gyroVideoH)
                let midY = vH / 2
                let base = midY * 16  // each row = 16 floats (RGBA32F, width=4)
                if mats.count >= base + 12 {
                    // Extract 3x3 from matTex layout: row0=[m00,m01,m02,_] row1=[m10,m11,m12,_] row2=[m20,m21,m22,_]
                    let m = (mats[base], mats[base+1], mats[base+2],
                             mats[base+4], mats[base+5], mats[base+6],
                             mats[base+8], mats[base+9], mats[base+10])
                    if let p = prevMidRow {
                        // R_delta = M_cur * M_prev^T (both orthonormal, so inverse = transpose)
                        let d00 = m.0*p.0 + m.1*p.1 + m.2*p.2
                        let d11 = m.3*p.3 + m.4*p.4 + m.5*p.5
                        let d22 = m.6*p.6 + m.7*p.7 + m.8*p.8
                        let tr = Double(d00 + d11 + d22)
                        let cosA = min(1, max(-1, (tr - 1) / 2))
                        let angle = acos(cosA)
                        siAngles.append(angle)
                        if siAngles.count > 120 { siAngles.removeFirst() }
                        let sumSq = siAngles.reduce(0.0) { $0 + $1 * $1 }
                        gyroSI = (sumSq / Double(siAngles.count)).squareRoot()
                    }
                    prevMidRow = m
                }
            }
        }

        let hasStab = (gyroMatrices != nil || gyroFrameRepeated) && warpProg != 0

        // ── Pass 2: gyroflow per-row warp (stabTex -> displayFBO) ─────────────
        if hasStab, let core = activeGyro {
            let vH = Int(core.gyroVideoH)
            let vW = core.gyroVideoW

            // Upload new gyro matrices only for new frames (not repeated).
            // For repeated frames stabFBO + matTex are both unchanged from last draw.
            if let matrices = gyroMatrices {
                // Update matTex dimensions (width=4: mat3x3 + IBIS sx/sy/ra + OIS ox/oy)
                if matTexH != vH {
                    matTexH = vH
                    glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
                    glTexImage2D(GLenum(GL_TEXTURE_2D), 0,
                                 0x8814,   // GL_RGBA32F
                                 4, GLsizei(vH), 0,
                                 GLenum(GL_RGBA), GLenum(GL_FLOAT), nil)
                    glBindTexture(GLenum(GL_TEXTURE_2D), 0)
                }

                // Upload matrices (cache hit skips upload entirely)
                if gyroMatChanged {
                    matrices.withUnsafeBufferPointer { ptr in
                        glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
                        glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0,
                                        0, 0, 4, GLsizei(vH),
                                        GLenum(GL_RGBA), GLenum(GL_FLOAT),
                                        ptr.baseAddress)
                        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
                    }
                }
            }

            // Warp pass → display FBO.
            // Letterbox uses bounds (w×h) for AR, then pre-compensate for
            // the system's FBO→bounds compositing stretch.
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(displayFBO))
            glViewport(0, 0, fboW, fboH)
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

            // Compute letterbox in bounds space, then map to FBO space
            let videoAspect = Float(vidW) / Float(vidH)
            let viewAspect  = Float(w) / Float(h)
            let sX = Float(fboW) / Float(w)   // FBO→bounds stretch factor
            let sY = Float(fboH) / Float(h)
            var vpX: GLint = 0, vpY: GLint = 0, vpW2 = fboW, vpH2 = fboH
            if viewAspect > videoAspect {
                let fitW = Float(h) * videoAspect  // in bounds space
                vpW2 = GLsizei(fitW * sX)
                vpX = (fboW - vpW2) / 2
            } else if viewAspect < videoAspect {
                let fitH = Float(w) / videoAspect
                vpH2 = GLsizei(fitH * sY)
                vpY = (fboH - vpH2) / 2
            }
            glViewport(vpX, vpY, vpW2, vpH2)

            glUseProgram(warpProg)

            glActiveTexture(GLenum(GL_TEXTURE0))
            glBindTexture(GLenum(GL_TEXTURE_2D), stabTex)
            glUniform1i(uTex, 0)

            glActiveTexture(GLenum(GL_TEXTURE1))
            glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
            glUniform1i(uMatTex, 1)

            glUniform2f(uVideoSize, vW, core.gyroVideoH)
            glUniform1f(uMatCount,  Float(vH))
            // Per-frame lens parameters from snapshot (avoids race with precomp thread)
            let lens = lastLensSnapshot
            let fx = lens?.frameFx ?? core.frameFx
            let fy = lens?.frameFy ?? core.frameFy
            let cx = lens?.frameCx ?? core.frameCx
            let cy = lens?.frameCy ?? core.frameCy
            let fk = lens?.frameK ?? core.frameK
            let dk = lens?.distortionK ?? core.distortionK
            glUniform2f(uFIn, fx, fy)
            glUniform2f(uCIn, cx, cy)
            // Per-frame distortion k[0..3] + static k[4..11] (merged into 3 × vec4)
            var mergedK: [Float] = [Float](repeating: 0, count: 12)
            mergedK[0] = fk[0]; mergedK[1] = fk[1]; mergedK[2] = fk[2]; mergedK[3] = fk[3]
            for i in 4..<12 { mergedK[i] = dk[i] }
            mergedK.withUnsafeBufferPointer { kPtr in
                glUniform4fv(uDistK, 3, kPtr.baseAddress)
            }
            glUniform1i(uDistModel, lens?.distortionModel ?? core.distortionModel)
            glUniform1f(uRLimit, lens?.rLimit ?? core.rLimit)
            glUniform1f(uFrameFov, lens?.frameFov ?? core.frameFov)
            glUniform1f(uLensCorr, lens?.lensCorrectionAmount ?? core.lensCorrectionAmount)

            // Draw fullscreen quad (VAO contains VBO binding + attrib setup)
            glBindVertexArray(warpVAO)
            glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
            glBindVertexArray(0)

            glActiveTexture(GLenum(GL_TEXTURE1))
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            glActiveTexture(GLenum(GL_TEXTURE0))
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            glUseProgram(0)
        } else if blitProg != 0 {
            // ── Non-gyro: blit intermediate → display FBO (stretch-to-fill) ──
            // mpv rendered at bounds dimensions with keepaspect (correct AR).
            // Fill the entire display FBO; system compositing FBO→bounds
            // applies the inverse stretch, preserving AR.
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(displayFBO))
            glViewport(0, 0, fboW, fboH)

            glUseProgram(blitProg)
            glActiveTexture(GLenum(GL_TEXTURE0))
            glBindTexture(GLenum(GL_TEXTURE_2D), stabTex)
            glUniform1i(uBlitTex, 0)

            glBindVertexArray(warpVAO)
            glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
            glBindVertexArray(0)

            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            glUseProgram(0)
        }

        // ── Gyro precomputation for next frame ──────────────────────────────
        if gyroCurrentFi >= 0, let core = activeGyro, core.isReady {
            let fps = core.gyroFps
            let nextTime = gyroRenderTime + 1.0 / fps
            let nextFi = max(0, min(Int((nextTime * fps).rounded()), core.frameCount - 1))
            if nextFi != gyroCurrentFi {
                gyroPrecompQueue.async { [weak self] in
                    guard let self else { return }
                    self.gyroCoreLock.lock()
                    defer { self.gyroCoreLock.unlock() }
                    guard let c = self.activeGyro, c.isReady else { return }
                    guard let (buf, _) = c.computeMatrixAtTime(timeSec: nextTime) else { return }
                    let mats = Array(buf)
                    let lens = GyroLensSnapshot(from: c)
                    self.precompLock.lock()
                    self.precompMats = mats
                    self.precompFrameIdx = nextFi
                    self.precompLens = lens
                    self.precompLock.unlock()
                }
            }
        }

        // ── Frame timing measurement (skipped when diagnostics are disabled) ──
        guard diagnosticsEnabled else { return }
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt < 2.0 {
                frameIntervals.append(dt)
                if frameIntervals.count > 60 { frameIntervals.removeFirst() }

                if frameIntervals.count >= 5 {
                    let mean = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                    renderFPS = mean > 0 ? 1.0 / mean : 0

                    let variance = frameIntervals.map { ($0 - mean) * ($0 - mean) }
                                                 .reduce(0, +) / Double(frameIntervals.count)
                    let cv = mean > 0 ? variance.squareRoot() / mean : 1
                    renderCV = cv
                    renderStability = max(0, 1 - min(cv * 5, 1))
                }
            }
        }
        lastFrameTime = now
    }

    deinit {
        if mdkAPI != nil {
            var p: UnsafePointer<mdkPlayerAPI>? = mdkAPI
            mdkPlayerAPI_delete(&p)
        }
        // Warp pipeline cleanup (must be called on GL context thread; best-effort here)
        if warpProg != 0 { glDeleteProgram(warpProg) }
        if blitProg != 0 { glDeleteProgram(blitProg) }
        if warpVAO  != 0 { glDeleteVertexArrays(1, &warpVAO) }
        if warpVBO  != 0 { glDeleteBuffers(1, &warpVBO) }
        if matTexId != 0 { glDeleteTextures(1, &matTexId) }
        if stabTex  != 0 { glDeleteTextures(1, &stabTex) }
        if stabFBO  != 0 { glDeleteFramebuffers(1, &stabFBO) }
    }
}
