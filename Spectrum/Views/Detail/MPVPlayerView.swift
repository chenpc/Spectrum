import SwiftUI
import OpenGL.GL3
import CoreVideo
import Darwin

// MARK: - Display Peak Nits

/// Query the display's actual peak HDR luminance via CoreDisplay private API (IINA approach).
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

// MARK: - MPVOpenGLLayer

/// CAOpenGLLayer that renders video via libmpv with per-content HDR configuration.
///
/// HDR pipeline — IINA-style PQ output:
///   All HDR (HLG/HDR10/DV) → mpv target-trc=pq, CALayer = itur_2100_PQ
///   SDR content / HDR toggle off → mpv target-trc=bt.709, CALayer = sRGB
class MPVOpenGLLayer: CAOpenGLLayer, @unchecked Sendable {

    private var mpvCtx:    OpaquePointer?
    fileprivate var renderCtx: OpaquePointer?   // accessed by CVDisplayLink callback
    private var cglPF:     CGLPixelFormatObj?
    private var cglCtx:    CGLContextObj?
    private var isFloat:   Bool = false
    private var displayLink: CVDisplayLink?

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

    /// When false, frame timing measurement in draw() is skipped entirely.
    var diagnosticsEnabled: Bool = true

    /// Set by mpv update callback (any thread); cleared at the top of draw().
    /// arm64 Bool store/load is a single instruction — safe without a lock.
    private var pendingFrame: Bool = false

    /// Set when bounds change — forces one redraw even if paused, preventing
    /// macOS from stretching stale backing store to the new aspect ratio.
    private var lastDrawnSize: CGSize = .zero

    /// Monotonic guard: prevents audio clock jitter from causing frame index oscillation.
    /// nil = not yet initialized (first frame after load/seek). Reset on gyro reload.
    private var lastGyroFrameIdx: Int? = nil

    /// When true, suppress rendering until gyroCore is ready.
    /// Prevents the visual flash of an unstabilized first frame.
    fileprivate var waitingForGyro: Bool = false

    /// Video native resolution — read from mpv once, used for letterboxing.
    /// Simple blit shader for non-gyro letterbox pass.
    private var blitProg: GLuint = 0
    private var uBlitTex: GLint = -1
    /// Frame counter for AR debug logging (log first 5 frames + on resize).

    // Keeps "opengl" string alive during render context creation
    private let apiTypeStr = "opengl" as NSString

    // MARK: - Gyroflow warp pipeline

    /// Set from main thread (MPVPlayerNSView.loadGyroCore); read in draw().
    fileprivate var gyroCore: GyroCore?

    // Intermediate FBO — mpv renders here; warp pass reads this and writes to displayFBO
    private var stabFBO:  GLuint = 0
    private var stabTex:  GLuint = 0
    private var stabW:    GLsizei = 0
    private var stabH:    GLsizei = 0
    // Warp shader program + VBO
    private var warpProg: GLuint = 0
    private var warpVAO:  GLuint = 0     // VAO (Core profile 必須)
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

    // Pre-allocated draw() buffers — zero heap allocation per frame
    private var sysViewport = (GLint(0), GLint(0), GLint(0), GLint(0))
    private var fboParam    = MPVOpenGLFBO(fbo: 0, w: 0, h: 0, internal_format: 0)
    private var flipYParam: Int32 = 1
    private var depthParam: Int32 = 8
    private var renderParams = (MPVRenderParam(), MPVRenderParam(),
                                MPVRenderParam(), MPVRenderParam())

    override init() {
        super.init()
        guard LibMPV.shared.ok else { return }
        // isAsynchronous = true: CAOpenGLLayer drives draw() on its own dedicated
        // rendering thread at the display refresh rate (vsync-aligned).
        // This keeps the main thread free for SwiftUI and AppKit work.
        isAsynchronous = true
        setupGL()
        setupMPV()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - OpenGL setup

    private func setupGL() {
        // ── IINA 風格：漸進式 pixel format 選擇 ──────────────────
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
                    print("[GL]   移除屬性 [\(names)]，繼續嘗試...")
                } else if err == kCGLNoError {
                    useCoreProfile = (ver == kCGLOGLPVersion_3_2_Core)
                    let has10Bit = groups.contains(where: { $0 == glFormat10Bit })
                    depth = has10Bit ? 16 : 8
                    let profile = useCoreProfile ? "3.2 Core" : "Legacy"
                    print("[GL] ✅ Pixel format: \(profile), depth=\(depth)")
                    break outer
                }
            }
        }

        guard let pixelFormat = pf else {
            print("[GL] ❌ 無法建立任何 pixel format!")
            return
        }

        cglPF = pixelFormat
        isFloat = (depth > 8)
        if isFloat { contentsFormat = .RGBA16Float }

        // EDR + initial PQ colorspace (prepareForContent will set dynamically)
        wantsExtendedDynamicRangeContent = true

        // ── IINA 風格：Context 建立 ──────────────────────────
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        guard let context = ctx else {
            print("[GL] ❌ 無法建立 CGL context!")
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

    // MARK: - mpv setup

    private func setupMPV() {
        let lib = LibMPV.shared
        guard let ctx = lib.create?() else { return }
        mpvCtx = ctx

        lib.set(ctx, "vo", "libmpv")
        let hwdec = UserDefaults.standard.string(forKey: "mpvHwdec") ?? "auto"
        lib.set(ctx, "hwdec", hwdec)
        lib.set(ctx, "keep-open", "yes")       // pause at end of file, don't terminate
        lib.set(ctx, "pause", "yes")           // start paused; user presses Space to play
        lib.set(ctx, "keepaspect", "yes")      // letterbox within FBO to preserve AR
        lib.set(ctx, "background", "color")    // black bars for letterbox

        // Sync & frame-drop settings (from Settings > Playback)
        let syncMode = UserDefaults.standard.string(forKey: "mpvVideoSync") ?? "display-resample"
        let dropMode = UserDefaults.standard.string(forKey: "mpvFrameDrop") ?? "vo"
        lib.set(ctx, "video-sync", syncMode)
        lib.set(ctx, "framedrop", dropMode)
        print("[mpv] init: video-sync=\(syncMode)  framedrop=\(dropMode)  hwdec=\(hwdec)")
        // HDR/colorspace options are set dynamically in prepareForContent(isHLG:)

        guard lib.initialize?(ctx) == 0 else { return }
        setupRenderContext(ctx: ctx)
        setupDisplayLink()
        startEventThread()
    }

    // MARK: - HDR configuration

    /// Apply CALayer colorspace + mpv tone-mapping options for the given content and HDR state.
    /// Called on new file load (showHDR=true) and on user HDR/SDR toggle.
    func applyHDRSettings(showHDR: Bool, hdrType: VideoHDRType?) {
        let lib = LibMPV.shared
        guard let ctx = mpvCtx else { return }
        let peakNits = displayPeakNits()

        if showHDR && hdrType != nil {
            // All HDR content (HLG/HDR10/DV) → PQ output (IINA approach)
            lib.set(ctx, "icc-profile-auto", "no")
            lib.set(ctx, "target-trc",       "pq")
            lib.set(ctx, "target-prim",      "bt.2020")
            lib.set(ctx, "target-peak",      String(peakNits))
            lib.set(ctx, "hdr-compute-peak", "no")
            lib.set(ctx, "tone-mapping",     "auto")
            colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            wantsExtendedDynamicRangeContent = true
        } else {
            // SDR content or HDR toggle off
            lib.set(ctx, "icc-profile-auto", "yes")
            lib.set(ctx, "target-trc",       "bt.709")
            lib.set(ctx, "target-prim",      "bt.709")
            lib.set(ctx, "target-peak",      "auto")
            lib.set(ctx, "hdr-compute-peak", "auto")
            lib.set(ctx, "tone-mapping",     "auto")
            colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            wantsExtendedDynamicRangeContent = false
        }
        pendingFrame = true
        setNeedsDisplay()
    }

    /// Convenience: call on new file load (always starts in HDR mode).
    func prepareForContent(hdrType: VideoHDRType?) {
        applyHDRSettings(showHDR: true, hdrType: hdrType)
    }

    private func setupRenderContext(ctx: OpaquePointer) {
        let lib = LibMPV.shared
        guard let cglCtx,
              let rcCreate = lib.rcCreate,
              let rcSetCb  = lib.rcSetCb else { return }

        CGLSetCurrentContext(cglCtx)

        var initParams = MPVOpenGLInitParams(get_proc_address: mpvGLProcAddr,
                                             get_proc_address_ctx: nil)
        var advanced: Int32 = 0

        withUnsafeMutablePointer(to: &initParams) { initPtr in
        withUnsafeMutablePointer(to: &advanced)   { advPtr  in
            var params: [MPVRenderParam] = [
                MPVRenderParam(MPV_RC_API_TYPE, UnsafeMutableRawPointer(mutating: apiTypeStr.utf8String!)),
                MPVRenderParam(MPV_RC_OGL_INIT, UnsafeMutableRawPointer(initPtr)),
                MPVRenderParam(MPV_RC_ADVANCED, UnsafeMutableRawPointer(advPtr)),
                MPVRenderParam()
            ]
            var rc: OpaquePointer?
            let err = withUnsafeMutablePointer(to: &rc) { rcPtr in
                params.withUnsafeMutableBufferPointer { buf in
                    rcCreate(UnsafeMutableRawPointer(rcPtr),
                             ctx,
                             UnsafeMutableRawPointer(buf.baseAddress!))
                }
            }
            guard err == 0, let rc else { return }
            renderCtx = rc

            // With isAsynchronous = true, draw() runs on CAOpenGLLayer's rendering thread.
            // The callback only needs to flag "new frame available" + wake the layer.
            // setNeedsDisplay() is thread-safe and schedules the next vsync draw.
            // No main thread dispatch needed — eliminates the primary source of frame jitter.
            let selfRef = Unmanaged.passUnretained(self).toOpaque()
            rcSetCb(rc, { ptr in
                guard let ptr else { return }
                let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(ptr).takeUnretainedValue()
                // ⚠️ callback 中禁止呼叫任何 mpv API（會死鎖）。
                layer.pendingFrame = true
                layer.setNeedsDisplay()
            }, selfRef)
        }}
    }

    // MARK: - Gyroflow warp pipeline setup

    private func setupWarpPipeline() {
        guard let cglCtx else { return }
        CGLSetCurrentContext(cglCtx)

        // ── Shader 版本根據 GL profile 選擇 ──
        // Core 3.2: #version 150 (in/out, texture(), 需要 VAO)
        // Legacy:   #version 120 (attribute/varying, texture2D, gl_FragColor)
        let vsSrc: String
        let fsSrc: String
        let blitFsSrc: String

        if useCoreProfile {
            vsSrc = """
#version 150
in vec2 pos;
out vec2 uv;
void main() {
    uv = pos * 0.5 + 0.5;
    gl_Position = vec4(pos, 0.0, 1.0);
}
"""
            // Fragment shader: gyroflow-core pipeline with IBIS/OIS + two-pass RS row indexing.
            fsSrc = """
#version 150
in vec2 uv;
out vec4 fragColor;
uniform sampler2D tex;
uniform sampler2D matTex;
uniform vec2  videoSize;
uniform float matCount;
uniform vec2  fIn;
uniform vec2  cIn;
vec2 rotate_and_distort(vec2 out_px, float texY) {
    vec4 m0 = texture(matTex, vec2(0.125, texY));
    vec4 m1 = texture(matTex, vec2(0.375, texY));
    vec4 m2 = texture(matTex, vec2(0.625, texY));
    vec4 m3 = texture(matTex, vec2(0.875, texY));
    float _x = m0.r*out_px.x + m0.g*out_px.y + m0.b;
    float _y = m1.r*out_px.x + m1.g*out_px.y + m1.b;
    float _w = m2.r*out_px.x + m2.g*out_px.y + m2.b;
    if (_w <= 0.0) return vec2(-99999.0);
    vec2 pt = fIn * vec2(_x / _w, _y / _w);
    float sx = m0.a; float sy = m1.a; float ra = m2.a;
    float ox = m3.r; float oy = m3.g;
    if (sx != 0.0 || sy != 0.0 || ra != 0.0 || ox != 0.0 || oy != 0.0) {
        float cos_a = cos(-ra);
        float sin_a = sin(-ra);
        pt = vec2(cos_a * pt.x - sin_a * pt.y - sx + ox,
                  sin_a * pt.x + cos_a * pt.y - sy + oy);
    }
    return pt + cIn;
}
void main() {
    vec2 out_px = vec2(uv.x * videoSize.x, (1.0 - uv.y) * videoSize.y);
    float sy = clamp(out_px.y, 0.0, matCount - 1.0);
    if (matCount > 1.0) {
        float midTexY = (floor(matCount * 0.5) + 0.5) / matCount;
        vec2 midPt = rotate_and_distort(out_px, midTexY);
        if (midPt.x > -99998.0) {
            sy = clamp(floor(0.5 + midPt.y), 0.0, matCount - 1.0);
        }
    }
    float texY = (sy + 0.5) / matCount;
    vec2 src_px = rotate_and_distort(out_px, texY);
    if (src_px.x < -99998.0) { fragColor = vec4(0.0,0.0,0.0,1.0); return; }
    vec2 src = vec2(src_px.x / videoSize.x, 1.0 - src_px.y / videoSize.y);
    if (any(lessThan(src, vec2(0.0))) || any(greaterThan(src, vec2(1.0)))) {
        fragColor = vec4(0.0,0.0,0.0,1.0);
    } else {
        fragColor = texture(tex, src);
    }
}
"""
            blitFsSrc = """
#version 150
in vec2 uv;
out vec4 fragColor;
uniform sampler2D tex;
void main() {
    fragColor = texture(tex, uv);
}
"""
        } else {
            vsSrc = """
#version 120
attribute vec2 pos;
varying vec2 uv;
void main() {
    uv = pos * 0.5 + 0.5;
    gl_Position = vec4(pos, 0.0, 1.0);
}
"""
            fsSrc = """
#version 120
varying vec2 uv;
uniform sampler2D tex;
uniform sampler2D matTex;
uniform vec2  videoSize;
uniform float matCount;
uniform vec2  fIn;
uniform vec2  cIn;
vec2 rotate_and_distort(vec2 out_px, float texY) {
    vec4 m0 = texture2D(matTex, vec2(0.125, texY));
    vec4 m1 = texture2D(matTex, vec2(0.375, texY));
    vec4 m2 = texture2D(matTex, vec2(0.625, texY));
    vec4 m3 = texture2D(matTex, vec2(0.875, texY));
    float _x = m0.r*out_px.x + m0.g*out_px.y + m0.b;
    float _y = m1.r*out_px.x + m1.g*out_px.y + m1.b;
    float _w = m2.r*out_px.x + m2.g*out_px.y + m2.b;
    if (_w <= 0.0) return vec2(-99999.0);
    vec2 pt = fIn * vec2(_x / _w, _y / _w);
    float sx = m0.a; float sy = m1.a; float ra = m2.a;
    float ox = m3.r; float oy = m3.g;
    if (sx != 0.0 || sy != 0.0 || ra != 0.0 || ox != 0.0 || oy != 0.0) {
        float cos_a = cos(-ra);
        float sin_a = sin(-ra);
        pt = vec2(cos_a * pt.x - sin_a * pt.y - sx + ox,
                  sin_a * pt.x + cos_a * pt.y - sy + oy);
    }
    return pt + cIn;
}
void main() {
    vec2 out_px = vec2(uv.x * videoSize.x, (1.0 - uv.y) * videoSize.y);
    float sy = clamp(out_px.y, 0.0, matCount - 1.0);
    if (matCount > 1.0) {
        float midTexY = (floor(matCount * 0.5) + 0.5) / matCount;
        vec2 midPt = rotate_and_distort(out_px, midTexY);
        if (midPt.x > -99998.0) {
            sy = clamp(floor(0.5 + midPt.y), 0.0, matCount - 1.0);
        }
    }
    float texY = (sy + 0.5) / matCount;
    vec2 src_px = rotate_and_distort(out_px, texY);
    if (src_px.x < -99998.0) { gl_FragColor = vec4(0.0,0.0,0.0,1.0); return; }
    vec2 src = vec2(src_px.x / videoSize.x, 1.0 - src_px.y / videoSize.y);
    if (any(lessThan(src, vec2(0.0))) || any(greaterThan(src, vec2(1.0)))) {
        gl_FragColor = vec4(0.0,0.0,0.0,1.0);
    } else {
        gl_FragColor = texture2D(tex, src);
    }
}
"""
            blitFsSrc = """
#version 120
varying vec2 uv;
uniform sampler2D tex;
void main() {
    gl_FragColor = texture2D(tex, uv);
}
"""
        }

        let vs = compileShader(GLenum(GL_VERTEX_SHADER),   vsSrc)
        let fs = compileShader(GLenum(GL_FRAGMENT_SHADER), fsSrc)
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
            print("[Warp] ❌ Shader link failed"); warpProg = 0; return
        }

        uTex       = glGetUniformLocation(warpProg, "tex")
        uMatTex    = glGetUniformLocation(warpProg, "matTex")
        uVideoSize = glGetUniformLocation(warpProg, "videoSize")
        uMatCount  = glGetUniformLocation(warpProg, "matCount")
        uFIn       = glGetUniformLocation(warpProg, "fIn")
        uCIn       = glGetUniformLocation(warpProg, "cIn")
        let profile = useCoreProfile ? "GL 3.2 Core (#version 150)" : "Legacy (#version 120)"
        print("[Warp] ✅ shader compiled (\(profile))")

        // ── VAO（Core profile 必須，Legacy 可選但無害）──
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
        let blitVs = compileShader(GLenum(GL_VERTEX_SHADER), vsSrc)
        let blitFs = compileShader(GLenum(GL_FRAGMENT_SHADER), blitFsSrc)
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
                print("[Blit] ✅ shader compiled (\(profile))")
            } else {
                print("[Blit] ❌ Shader link failed"); blitProg = 0
            }
        }
    }

    private func compileShader(_ type: GLenum, _ source: String) -> GLuint {
        let shader = glCreateShader(type)
        source.withCString { ptr in
            var p: UnsafePointer<GLchar>? = ptr
            glShaderSource(shader, 1, &p, nil)
        }
        glCompileShader(shader)
        var status = GLint(0)
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)
        if status == GLint(GL_FALSE) {
            var log = [GLchar](repeating: 0, count: 512)
            glGetShaderInfoLog(shader, 512, nil, &log)
            print("[Warp] ❌ Shader compile error: \(String(cString: log))")
            glDeleteShader(shader); return 0
        }
        return shader
    }

    /// Call from main thread to attach/detach gyro stabilization.
    func loadGyroCore(_ core: GyroCore?) {
        gyroCore = core
        lastGyroFrameIdx = nil   // 重置單調保護
        waitingForGyro = false   // gyro ready（或 detach）→ 允許渲染
        // Apply user's Sync & Drop settings (from Settings → Playback).
        if let ctx = mpvCtx {
            let sync     = UserDefaults.standard.string(forKey: "mpvVideoSync") ?? "display-resample"
            let dropMode = UserDefaults.standard.string(forKey: "mpvFrameDrop") ?? "vo"
            LibMPV.shared.setProperty(ctx, "video-sync", sync)
            LibMPV.shared.setProperty(ctx, "framedrop", dropMode)
            print("[mpv] loadGyroCore: video-sync=\(sync)  framedrop=\(dropMode)  gyro=\(core != nil)")
        }
        pendingFrame = true
        setNeedsDisplay()
    }

    // MARK: - CVDisplayLink (swap report)

    /// Creates a CVDisplayLink that calls mpv_render_context_report_swap at each vsync.
    /// This tells mpv the precise time the frame was presented — more accurate than
    /// calling report_swap immediately after render() inside draw().
    private func setupDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, ctx -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(ctx).takeUnretainedValue()
            guard let rc = layer.renderCtx, let fn = LibMPV.shared.rcSwap else {
                return kCVReturnSuccess
            }
            fn(rc)
            return kCVReturnSuccess
        }, selfRef)
        CVDisplayLinkStart(dl)
        displayLink = dl
    }

    // MARK: - Event thread

    private func startEventThread() {
        Thread.detachNewThread { [weak self] in
            guard let self,
                  let ctx = self.mpvCtx,
                  let waitFn = LibMPV.shared.waitEvent else { return }
            while true {
                let evRaw = waitFn(ctx, -1)
                let ev = evRaw.assumingMemoryBound(to: MPVEvent.self)
                if ev.pointee.event_id == MPV_EV_SHUTDOWN { return }
            }
        }
    }

    // MARK: - Playback control

    func loadFile(_ path: String) {
        guard let ctx = mpvCtx, let cmdFn = LibMPV.shared.command else { return }
        "loadfile".withCString { loadPtr in
            path.withCString { pathPtr in
                var args: [UnsafePointer<CChar>?] = [loadPtr, pathPtr, nil]
                _ = cmdFn(ctx, &args)
            }
        }
    }

    func stop() {
        guard let ctx = mpvCtx, let cmdFn = LibMPV.shared.command else { return }
        "stop".withCString { stopPtr in
            var args: [UnsafePointer<CChar>?] = [stopPtr, nil]
            _ = cmdFn(ctx, &args)
        }
    }

    var isPaused: Bool {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return false }
        guard let val = "pause".withCString({ fn(ctx, $0) }) else { return false }
        defer { LibMPV.shared.free?(UnsafeMutableRawPointer(val)) }
        return String(cString: val) == "yes"
    }

    var currentTime: Double {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return 0 }
        guard let val = "time-pos".withCString({ fn(ctx, $0) }) else { return 0 }
        defer { LibMPV.shared.free?(UnsafeMutableRawPointer(val)) }
        return Double(String(cString: val)) ?? 0
    }

    var videoDuration: Double {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return 0 }
        guard let val = "duration".withCString({ fn(ctx, $0) }) else { return 0 }
        defer { LibMPV.shared.free?(UnsafeMutableRawPointer(val)) }
        return Double(String(cString: val)) ?? 0
    }

    var isEOFReached: Bool {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return false }
        guard let val = "eof-reached".withCString({ fn(ctx, $0) }) else { return false }
        defer { LibMPV.shared.free?(UnsafeMutableRawPointer(val)) }
        return String(cString: val) == "yes"
    }

    /// The decoder actually in use, e.g. "videotoolbox", "none" (software), or "no" if idle.
    var hwdecCurrent: String {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return "unknown" }
        guard let val = "hwdec-current".withCString({ fn(ctx, $0) }) else { return "none" }
        defer { LibMPV.shared.free?(UnsafeMutableRawPointer(val)) }
        return String(cString: val)
    }

    func setPause(_ paused: Bool) {
        guard let ctx = mpvCtx else { return }
        LibMPV.shared.set(ctx, "pause", paused ? "yes" : "no")
    }

    func seek(to seconds: Double) {
        guard let ctx = mpvCtx, let cmdFn = LibMPV.shared.command else { return }
        let timeStr = String(format: "%.3f", seconds)
        "seek".withCString { seekPtr in
            timeStr.withCString { timePtr in
                "absolute".withCString { absPtr in
                    var args: [UnsafePointer<CChar>?] = [seekPtr, timePtr, absPtr, nil]
                    _ = cmdFn(ctx, &args)
                }
            }
        }
    }

    /// Declared FPS of the loaded video (e.g. 29.97, 60).
    var videoFPS: Double {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return 0 }
        guard let val = "container-fps".withCString({ fn(ctx, $0) }) else { return 0 }
        defer { LibMPV.shared.free?(UnsafeMutableRawPointer(val)) }
        return Double(String(cString: val)) ?? 0
    }

    /// Cumulative VO-level frame drops (render API: frame replaced before draw).
    var droppedFrames: Int {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return 0 }
        guard let val = "frame-drop-count".withCString({ fn(ctx, $0) }) else { return 0 }
        defer { LibMPV.shared.free?(UnsafeMutableRawPointer(val)) }
        return Int(String(cString: val)) ?? 0
    }

    /// Cumulative decoder-level frame drops (B-frame skip etc.).
    var decoderDroppedFrames: Int {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return 0 }
        guard let val = "decoder-frame-drop-count".withCString({ fn(ctx, $0) }) else { return 0 }
        defer { LibMPV.shared.free?(UnsafeMutableRawPointer(val)) }
        return Int(String(cString: val)) ?? 0
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
        // Suppress rendering until gyro is ready — avoids flashing unstabilized first frame.
        if waitingForGyro { return false }
        guard renderCtx != nil else { return false }
        // Redraw when bounds changed (e.g. fullscreen/inspector toggle) to avoid
        // macOS stretching the stale backing store to a new aspect ratio.
        if bounds.size != lastDrawnSize { return true }
        // Only render when mpv has signalled a new frame — avoids busy-rendering
        // static content (e.g. paused video) at 120 Hz.
        return pendingFrame
    }

    override func draw(inCGLContext ctx: CGLContextObj,
                       pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval,
                       displayTime ts: UnsafePointer<CVTimeStamp>?) {
        pendingFrame = false
        let lib = LibMPV.shared
        guard let rc = renderCtx,
              let renderFn = lib.rcRender else { return }

        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }

        // ── Display FBO: system-managed triple-buffer ────────────────────────
        // GL_VIEWPORT gives the ACTUAL display FBO pixel dimensions.
        // bounds gives the LOGICAL layer size (may differ during resize).
        // Strategy: always render mpv to our own intermediate FBO at bounds
        // dimensions (correct AR via keepaspect), then blit/warp to fill the
        // entire display FBO. System composites FBO→bounds, stretches cancel out.
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

        // ── Gyro matrix（同步 ~0.5ms，cache hit 時 ~0）────────────────────────
        var gyroResult: (UnsafeBufferPointer<Float>, Bool)? = nil
        var gyroFrameRepeated = false   // true → same video frame, skip mpv_render + gyro
        if let core = gyroCore, core.isReady,
           let ctx = mpvCtx, let getFn = lib.getStr {
            let timeSec: Double
            if let val = "time-pos".withCString({ getFn(ctx, $0) }) {
                timeSec = strtod(val, nil)   // zero-alloc: parse C string directly
                lib.free?(UnsafeMutableRawPointer(val))
            } else { timeSec = 0 }
            // Fixed half-frame offset: centres floor(t × fps) in each frame
            // interval, far from boundaries. Without it, 120 Hz draw on 60 fps
            // content lands every other sample at a frame edge → jitter.
            let halfFrame = 0.5 / core.gyroFps
            let adjustedTime = max(0, timeSec - halfFrame)
            var fi = max(0, min(Int(adjustedTime * core.gyroFps),
                                core.frameCount - 1))
            let prevFi = lastGyroFrameIdx
            if let lastFi = prevFi {
                let delta = fi - lastFi
                if delta < 0 && delta >= -2 { fi = lastFi }
            }

            if fi == lastGyroFrameIdx {
                // Same video frame as last draw — reuse existing stabFBO + matTex.
                // Skip mpv_render + computeMatrix; only the cheap warp pass runs.
                // This guarantees identical gyro data for both 120 Hz draws of each
                // 60 fps frame (no jitter from slightly different time-pos values).
                gyroFrameRepeated = true
            } else {
                lastGyroFrameIdx = fi
                gyroResult = core.computeMatrix(frameIdx: fi)
            }
        }

        let hasStab = (gyroResult != nil || gyroFrameRepeated) && warpProg != 0

        // ── Intermediate FBO sizing ──────────────────────────────────────────
        // Always use intermediate FBO so we control exact pixel dimensions.
        // Gyro: render at gyrocore video resolution for warp shader.
        // Non-gyro: render at bounds size; mpv keepaspect handles AR.
        let vidW: GLsizei, vidH: GLsizei
        if hasStab {
            vidW = GLsizei(gyroCore!.gyroVideoW)
            vidH = GLsizei(gyroCore!.gyroVideoH)
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

        // ── Pass 1：mpv renders to intermediate FBO ──────────────────────────
        // Skip when the video frame hasn't changed (gyroFrameRepeated) —
        // stabFBO already contains this frame from the previous draw().
        if !gyroFrameRepeated {
            // Pre-allocated params — no heap allocation per frame
            fboParam = MPVOpenGLFBO(fbo: GLint(stabFBO), w: vidW, h: vidH, internal_format: 0)
            depthParam = isFloat ? 16 : 8

            withUnsafeMutablePointer(to: &fboParam)   { fboPtr  in
            withUnsafeMutablePointer(to: &flipYParam) { flipPtr in
            withUnsafeMutablePointer(to: &depthParam) { depthPtr in
                renderParams.0 = MPVRenderParam(MPV_RC_OGL_FBO, UnsafeMutableRawPointer(fboPtr))
                renderParams.1 = MPVRenderParam(MPV_RC_FLIP_Y,  UnsafeMutableRawPointer(flipPtr))
                renderParams.2 = MPVRenderParam(MPV_RC_DEPTH,   UnsafeMutableRawPointer(depthPtr))
                renderParams.3 = MPVRenderParam()
                withUnsafeMutablePointer(to: &renderParams) {
                    $0.withMemoryRebound(to: MPVRenderParam.self, capacity: 4) { buf in
                        _ = renderFn(rc, UnsafeMutableRawPointer(buf))
                    }
                }
            }}}
        }

        // ── Pass 2：gyroflow per-row warp（stabTex → displayFBO）─────────────
        if hasStab, let core = gyroCore {
            let vH = Int(core.gyroVideoH)
            let vW = core.gyroVideoW

            // Upload new gyro matrices only for new frames (not repeated).
            // For repeated frames stabFBO + matTex are both unchanged from last draw.
            if let (matrices, matChanged) = gyroResult {
                // 更新 matTex 尺寸（width=4：mat3×3 + IBIS sx/sy/ra + OIS ox/oy）
                if matTexH != vH {
                    matTexH = vH
                    glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
                    glTexImage2D(GLenum(GL_TEXTURE_2D), 0,
                                 0x8814,   // GL_RGBA32F
                                 4, GLsizei(vH), 0,
                                 GLenum(GL_RGBA), GLenum(GL_FLOAT), nil)
                    glBindTexture(GLenum(GL_TEXTURE_2D), 0)
                }

                // 只在矩陣變更時上傳（cache hit 跳過 ~0.1ms texture upload）
                if matChanged {
                    glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
                    glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0,
                                    0, 0, 4, GLsizei(vH),
                                    GLenum(GL_RGBA), GLenum(GL_FLOAT),
                                    matrices.baseAddress)
                    glBindTexture(GLenum(GL_TEXTURE_2D), 0)
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
            glUniform2f(uFIn, core.gyroFx, core.gyroFy)
            glUniform2f(uCIn, core.gyroCx, core.gyroCy)

            // Draw fullscreen quad (VAO 包含 VBO 綁定 + attrib 設定)
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
        if let dl = displayLink { CVDisplayLinkStop(dl) }
        let lib = LibMPV.shared
        if let rc  = renderCtx { lib.rcFree?(rc) }
        if let ctx = mpvCtx    { lib.destroy?(ctx) }
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

// MARK: - MPVPlayerNSView

class MPVPlayerNSView: NSView {
    private let mpvLayer = MPVOpenGLLayer()
    private var currentPath: String?
    private var scopeURL: URL?
    private var scopeStarted = false
    weak var controller: MPVController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = mpvLayer
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 1.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mpvLayer.contentsScale = scale
        mpvLayer.frame = bounds
        CATransaction.commit()
    }

    func load(path: String, bookmarkData: Data?, hdrType: VideoHDRType? = nil) {
        guard path != currentPath else { return }
        stopScope()
        currentPath = path
        startScope(bookmarkData: bookmarkData)
        mpvLayer.setPause(true)    // Ensure paused before loading new file
        mpvLayer.prepareForContent(hdrType: hdrType)
        mpvLayer.loadFile(path)
    }

    func stop() {
        controller?.stopPolling()
        mpvLayer.stop()
        stopScope()
        currentPath = nil
    }

    // Gyro stabilization pass-through
    nonisolated func loadGyroCore(_ core: GyroCore?) {
        mpvLayer.loadGyroCore(core)
    }
    /// Suppress rendering until gyro is ready — prevents unstabilized first-frame flash.
    nonisolated func setWaitingForGyro(_ waiting: Bool) {
        mpvLayer.waitingForGyro = waiting
    }

    // HDR toggle pass-through
    func applyHDR(showHDR: Bool, hdrType: VideoHDRType?) {
        mpvLayer.applyHDRSettings(showHDR: showHDR, hdrType: hdrType)
    }

    // Diagnostics pass-through
    nonisolated var diagnosticsEnabled: Bool {
        get { mpvLayer.diagnosticsEnabled }
        set { mpvLayer.diagnosticsEnabled = newValue }
    }

    // Playback pass-throughs — nonisolated because the underlying mpv C API
    // is thread-safe.  The poll queue reads these off the main thread.
    nonisolated var isPaused: Bool { mpvLayer.isPaused }
    nonisolated var isEOFReached: Bool { mpvLayer.isEOFReached }
    nonisolated var currentTime: Double { mpvLayer.currentTime }
    nonisolated var videoDuration: Double { mpvLayer.videoDuration }
    nonisolated var hwdecCurrent: String { mpvLayer.hwdecCurrent }
    nonisolated var renderFPS: Double { mpvLayer.renderFPS }
    nonisolated var renderCV: Double { mpvLayer.renderCV }
    nonisolated var renderStability: Double { mpvLayer.renderStability }
    nonisolated var videoFPS: Double { mpvLayer.videoFPS }
    nonisolated var droppedFrames: Int { mpvLayer.droppedFrames }
    nonisolated var decoderDroppedFrames: Int { mpvLayer.decoderDroppedFrames }
    nonisolated func setPause(_ paused: Bool) { mpvLayer.setPause(paused) }
    nonisolated func seek(to seconds: Double) { mpvLayer.seek(to: seconds) }

    private func startScope(bookmarkData: Data?) {
        guard let data = bookmarkData,
              let url = try? BookmarkService.resolveBookmark(data) else { return }
        scopeURL = url
        scopeStarted = url.startAccessingSecurityScopedResource()
    }

    private func stopScope() {
        if scopeStarted, let url = scopeURL {
            url.stopAccessingSecurityScopedResource()
        }
        scopeURL = nil
        scopeStarted = false
    }

    deinit { MainActor.assumeIsolated { stop() } }
}

// MARK: - MPVPlayerView (SwiftUI)

struct MPVPlayerView: NSViewRepresentable {
    let path: String
    let bookmarkData: Data?
    let controller: MPVController
    var hdrType: VideoHDRType? = nil
    var showHDR: Bool = true

    func makeNSView(context: Context) -> MPVPlayerNSView {
        let view = MPVPlayerNSView()
        view.controller = controller
        view.load(path: path, bookmarkData: bookmarkData, hdrType: hdrType)
        controller.startPolling(view: view)
        return view
    }

    func updateNSView(_ nsView: MPVPlayerNSView, context: Context) {
        controller.startPolling(view: nsView)   // idempotent if same view
        nsView.load(path: path, bookmarkData: bookmarkData, hdrType: hdrType)
        // Apply HDR toggle state (no-op if unchanged; mpv re-renders on option change)
        nsView.applyHDR(showHDR: showHDR, hdrType: hdrType)
    }

    static func dismantleNSView(_ nsView: MPVPlayerNSView, coordinator: ()) {
        nsView.stop()
    }
}
