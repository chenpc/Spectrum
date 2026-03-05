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


    /// When true, suppress rendering until gyroCore is ready.
    /// Prevents the visual flash of an unstabilized first frame.
    fileprivate var waitingForGyro: Bool = false

    // MARK: - MDK backend state

    private var mdkAPI: UnsafePointer<mdkPlayerAPI>?
    private var mdkGLAPI = mdkGLRenderAPI()
    private var mdkReady = false
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
    fileprivate var activeGyro: GyroCoreProvider?

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
        // ── IINA-style: progressive pixel format selection ──────────────────
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

        // ── IINA-style: Context creation ──────────────────────────
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
            layer.setNeedsDisplay()
        }, opaque: selfRef))

        // Default PQ output for HDR
        api.pointee.setColorSpace(obj, MDK_ColorSpace_BT2100_PQ, nil)
    }

    // MARK: - HDR configuration

    /// Apply CALayer colorspace for the given content and HDR state.
    func applyHDRSettings(showHDR: Bool, hdrType: VideoHDRType?) {
        if showHDR && hdrType != nil {
            wantsExtendedDynamicRangeContent = true
        } else {
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

    // MARK: - Gyroflow warp pipeline setup

    private func setupWarpPipeline() {
        guard let cglCtx else { return }
        CGLSetCurrentContext(cglCtx)

        // ── Shader version selection based on GL profile ──
        // Core 3.2: #version 150 (in/out, texture(), requires VAO)
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
            // Fragment shader: gyroflow-core pipeline with lens distortion + IBIS/OIS + RS.
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
uniform vec4  distK[3];    // k[0..11] as 3 × vec4
uniform int   distModel;   // 0=None 1=OpenCVFisheye 3=Poly3 4=Poly5 7=Sony
uniform float rLimit;      // radial distortion limit (0 = unlimited)
uniform float frameFov;    // per-frame FOV from adaptive zoom
uniform float lensCorr;    // lens_correction_amount (0=full undistort, 1=none)

// ── Lens undistort: Newton-Raphson inverse (output-space correction) ──
vec2 undistort_point(vec2 pos) {
    if (distModel == 1) {
        // OpenCV Fisheye inverse
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta_d = clamp(length(pos), -1.5707963, 1.5707963);
        float theta = theta_d; float scale = 0.0; bool converged = false;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t4 = t2*t2;
                float t6 = t4*t2; float t8 = t6*t2;
                float k0t2 = distK[0].x*t2; float k1t4 = distK[0].y*t4;
                float k2t6 = distK[0].z*t6; float k3t8 = distK[0].w*t8;
                float theta_fix = (theta*(1.0+k0t2+k1t4+k2t6+k3t8) - theta_d)
                                / (1.0+3.0*k0t2+5.0*k1t4+7.0*k2t6+9.0*k3t8);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) { converged = true; break; }
            }
            scale = tan(theta) / theta_d;
        } else { converged = true; }
        bool flipped = (theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0);
        if (converged && !flipped) return pos * scale;
        return vec2(0.0);
    }
    if (distModel == 7) {
        // Sony inverse
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        vec2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = vec2(1.0);
        vec2 p = pos / post_scale;
        float theta_d = length(p); float theta = theta_d; float scale = 0.0; bool converged = false;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t3 = t2*theta;
                float t4 = t2*t2; float t5 = t4*theta;
                float k0 = distK[0].x; float k1t = distK[0].y*theta;
                float k2t2 = distK[0].z*t2; float k3t3 = distK[0].w*t3;
                float k4t4 = distK[1].x*t4; float k5t5 = distK[1].y*t5;
                float theta_fix = (theta*(k0+k1t+k2t2+k3t3+k4t4+k5t5) - theta_d)
                                / (k0+2.0*k1t+3.0*k2t2+4.0*k3t3+5.0*k4t4+6.0*k5t5);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) { converged = true; break; }
            }
            scale = tan(theta) / theta_d;
        } else { converged = true; }
        bool flipped = (theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0);
        if (converged && !flipped) return p * scale;
        return vec2(0.0);
    }
    return pos; // None/Poly: identity
}

// ── Lens distortion: map 3D homogeneous → 2D distorted normalized coords ──
vec2 distort_point(float x, float y, float w) {
    vec2 pos = vec2(x, y) / w;
    if (distModel == 0) return pos; // None: identity
    float r = length(pos);
    if (rLimit > 0.0 && r > rLimit) return vec2(-99999.0);

    if (distModel == 1) {
        // OpenCV Fisheye: theta_d = theta * (1 + k0*t2 + k1*t4 + k2*t6 + k3*t8)
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta * theta; float t4 = t2 * t2;
        float t6 = t4 * t2; float t8 = t4 * t4;
        float theta_d = theta * (1.0 + distK[0].x*t2 + distK[0].y*t4 + distK[0].z*t6 + distK[0].w*t8);
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        return pos * scale;
    }
    if (distModel == 3) {
        float poly2 = distK[0].x * (pos.x*pos.x + pos.y*pos.y) + 1.0;
        return pos * poly2;
    }
    if (distModel == 4) {
        float r2 = pos.x*pos.x + pos.y*pos.y;
        float poly4 = 1.0 + distK[0].x * r2 + distK[0].y * r2 * r2;
        return pos * poly4;
    }
    if (distModel == 7) {
        // Sony: theta_d = k0*θ + k1*θ² + ... + k5*θ⁶, post_scale=(k6,k7)
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta * theta; float t3 = t2 * theta;
        float t4 = t2 * t2; float t5 = t4 * theta; float t6 = t3 * t3;
        float theta_d = distK[0].x*theta + distK[0].y*t2 + distK[0].z*t3
                       + distK[0].w*t4 + distK[1].x*t5 + distK[1].y*t6;
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        vec2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = vec2(1.0);
        return pos * scale * post_scale;
    }
    return pos;
}

vec2 rotate_and_distort(vec2 out_px, float texY) {
    vec4 m0 = texture(matTex, vec2(0.125, texY));
    vec4 m1 = texture(matTex, vec2(0.375, texY));
    vec4 m2 = texture(matTex, vec2(0.625, texY));
    vec4 m3 = texture(matTex, vec2(0.875, texY));
    float _x = m0.r*out_px.x + m0.g*out_px.y + m0.b;
    float _y = m1.r*out_px.x + m1.g*out_px.y + m1.b;
    float _w = m2.r*out_px.x + m2.g*out_px.y + m2.b;
    if (_w <= 0.0) return vec2(-99999.0);
    vec2 dp = distort_point(_x, _y, _w);
    if (dp.x < -99998.0) return dp;
    vec2 pt = fIn * dp;
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
    // Lens correction: undistort output coords (matches gyroflow pipeline).
    // lensCorr = lens_correction_amount: 1.0 = no undistort, 0.0 = full undistort.
    // Auto-zoom in gyroflow-core compensates for this expansion.
    // NOTE: gyroflow uses frame center (videoSize/2) as undistort origin,
    // matching K_new which sets principal point = output center.
    if (distModel != 0 && frameFov > 0.0 && lensCorr < 1.0) {
        float factor = max(1.0 - lensCorr, 0.001);
        vec2 out_c = videoSize * 0.5;
        vec2 out_f = fIn / frameFov / factor;
        vec2 norm  = (out_px - out_c) / out_f;
        vec2 corr  = undistort_point(norm);
        vec2 undist = corr * out_f + out_c;
        out_px = undist * (1.0 - lensCorr) + out_px * lensCorr;
    }
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
    // Clamp to frame edge instead of rendering black — hides thin border artifacts.
    src = clamp(src, vec2(0.0), vec2(1.0));
    fragColor = texture(tex, src);
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
uniform vec4  distK[3];
uniform int   distModel;
uniform float rLimit;
uniform float frameFov;
uniform float lensCorr;

vec2 undistort_point(vec2 pos) {
    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta_d = clamp(length(pos), -1.5707963, 1.5707963);
        float theta = theta_d; float scale = 0.0; bool converged = false;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t4 = t2*t2; float t6 = t4*t2; float t8 = t6*t2;
                float k0t2 = distK[0].x*t2; float k1t4 = distK[0].y*t4;
                float k2t6 = distK[0].z*t6; float k3t8 = distK[0].w*t8;
                float theta_fix = (theta*(1.0+k0t2+k1t4+k2t6+k3t8) - theta_d)
                                / (1.0+3.0*k0t2+5.0*k1t4+7.0*k2t6+9.0*k3t8);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) { converged = true; break; }
            }
            scale = tan(theta) / theta_d;
        } else { converged = true; }
        bool flipped = (theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0);
        if (converged && !flipped) return pos * scale;
        return vec2(0.0);
    }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        vec2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = vec2(1.0);
        vec2 p = pos / post_scale;
        float theta_d = length(p); float theta = theta_d; float scale = 0.0; bool converged = false;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t3 = t2*theta; float t4 = t2*t2; float t5 = t4*theta;
                float k0 = distK[0].x; float k1t = distK[0].y*theta; float k2t2 = distK[0].z*t2;
                float k3t3 = distK[0].w*t3; float k4t4 = distK[1].x*t4; float k5t5 = distK[1].y*t5;
                float theta_fix = (theta*(k0+k1t+k2t2+k3t3+k4t4+k5t5) - theta_d)
                                / (k0+2.0*k1t+3.0*k2t2+4.0*k3t3+5.0*k4t4+6.0*k5t5);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) { converged = true; break; }
            }
            scale = tan(theta) / theta_d;
        } else { converged = true; }
        bool flipped = (theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0);
        if (converged && !flipped) return p * scale;
        return vec2(0.0);
    }
    return pos;
}

vec2 distort_point(float x, float y, float w) {
    vec2 pos = vec2(x, y) / w;
    if (distModel == 0) return pos;
    float r = length(pos);
    if (rLimit > 0.0 && r > rLimit) return vec2(-99999.0);
    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta * theta; float t4 = t2 * t2; float t6 = t4 * t2; float t8 = t4 * t4;
        float theta_d = theta * (1.0 + distK[0].x*t2 + distK[0].y*t4 + distK[0].z*t6 + distK[0].w*t8);
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        return pos * scale;
    }
    if (distModel == 3) {
        float poly2 = distK[0].x * (pos.x*pos.x + pos.y*pos.y) + 1.0;
        return pos * poly2;
    }
    if (distModel == 4) {
        float r2 = pos.x*pos.x + pos.y*pos.y;
        float poly4 = 1.0 + distK[0].x * r2 + distK[0].y * r2 * r2;
        return pos * poly4;
    }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta * theta; float t3 = t2 * theta;
        float t4 = t2 * t2; float t5 = t4 * theta; float t6 = t3 * t3;
        float theta_d = distK[0].x*theta + distK[0].y*t2 + distK[0].z*t3
                       + distK[0].w*t4 + distK[1].x*t5 + distK[1].y*t6;
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        vec2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = vec2(1.0);
        return pos * scale * post_scale;
    }
    return pos;
}

vec2 rotate_and_distort(vec2 out_px, float texY) {
    vec4 m0 = texture2D(matTex, vec2(0.125, texY));
    vec4 m1 = texture2D(matTex, vec2(0.375, texY));
    vec4 m2 = texture2D(matTex, vec2(0.625, texY));
    vec4 m3 = texture2D(matTex, vec2(0.875, texY));
    float _x = m0.r*out_px.x + m0.g*out_px.y + m0.b;
    float _y = m1.r*out_px.x + m1.g*out_px.y + m1.b;
    float _w = m2.r*out_px.x + m2.g*out_px.y + m2.b;
    if (_w <= 0.0) return vec2(-99999.0);
    vec2 dp = distort_point(_x, _y, _w);
    if (dp.x < -99998.0) return dp;
    vec2 pt = fIn * dp;
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
    if (distModel != 0 && frameFov > 0.0 && lensCorr < 1.0) {
        float factor = max(1.0 - lensCorr, 0.001);
        vec2 out_c = videoSize * 0.5;
        vec2 out_f = fIn / frameFov / factor;
        vec2 norm  = (out_px - out_c) / out_f;
        vec2 corr  = undistort_point(norm);
        vec2 undist = corr * out_f + out_c;
        out_px = undist * (1.0 - lensCorr) + out_px * lensCorr;
    }
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
    src = clamp(src, vec2(0.0), vec2(1.0));
    gl_FragColor = texture2D(tex, src);
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
                print("[Blit] Shader compiled OK (\(profile))")
            } else {
                print("[Blit] Shader link failed"); blitProg = 0
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
            print("[Warp] Shader compile error: \(String(cString: log))")
            glDeleteShader(shader); return 0
        }
        return shader
    }

    /// Call from main thread to attach/detach gyro stabilization.
    func loadGyroCore(_ core: GyroCoreProvider?) {
        activeGyro = core
        lastGyroFrameIdx = nil   // reset monotonic guard
        waitingForGyro = false   // gyro ready (or detach) -> allow rendering
        pendingFrame = true
        setNeedsDisplay()
    }

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

    var isEOFReached: Bool { false }

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
        mdkReady = false
        api.pointee.setMedia(obj, path)

        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        api.pointee.prepare(obj, 0, mdkPrepareCallback(cb: { position, boost, opaque in
            guard let opaque else { return true }
            let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(opaque).takeUnretainedValue()
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

                    // DV P8.4 always → PQ (even when mediaInfo reports HLG)
                    // Otherwise follow detected color_space.
                    // CALayer colorspace + EDR are thread-safe to set.
                    if doviProfile == 8 {
                        // Dolby Vision P8.4 → PQ
                        api.pointee.setColorSpace(rawObj, MDK_ColorSpace_BT2100_PQ, nil)
                        layer.mdkColorspaceInfo = "PQ"
                        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                        layer.wantsExtendedDynamicRangeContent = true
                    } else if cs == MDK_ColorSpace_BT2100_HLG {
                        api.pointee.setColorSpace(rawObj, MDK_ColorSpace_BT2100_HLG, nil)
                        layer.mdkColorspaceInfo = "HLG"
                        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                        layer.wantsExtendedDynamicRangeContent = true
                    } else if cs == MDK_ColorSpace_BT2100_PQ {
                        api.pointee.setColorSpace(rawObj, MDK_ColorSpace_BT2100_PQ, nil)
                        layer.mdkColorspaceInfo = "PQ"
                        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                        layer.wantsExtendedDynamicRangeContent = true
                    } else {
                        // SDR / BT.709 / unknown → BT.709, no EDR
                        api.pointee.setColorSpace(rawObj, MDK_ColorSpace_BT709, nil)
                        layer.mdkColorspaceInfo = "BT.709"
                        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                        layer.wantsExtendedDynamicRangeContent = false
                    }
                }
            }
            layer.mdkReady = true
            // Play immediately — deferred from user pressing Space.
            return true
        }, opaque: selfRef), MDK_SeekFlag_FromStart)

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
        var gyroResult: (UnsafeBufferPointer<Float>, Bool)? = nil
        var gyroFrameRepeated = false

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
                gyroResult = core.computeMatrixAtTime(timeSec: renderTime)
            }
        }

        let hasStab = (gyroResult != nil || gyroFrameRepeated) && warpProg != 0

        // ── Pass 2: gyroflow per-row warp (stabTex -> displayFBO) ─────────────
        if hasStab, let core = activeGyro {
            let vH = Int(core.gyroVideoH)
            let vW = core.gyroVideoW

            // Upload new gyro matrices only for new frames (not repeated).
            // For repeated frames stabFBO + matTex are both unchanged from last draw.
            if let (matrices, matChanged) = gyroResult {
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

                // Only upload when matrices changed (cache hit skips ~0.1ms texture upload)
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
            // Per-frame f, c (may change due to adaptive zoom or per-frame lens telemetry)
            glUniform2f(uFIn, core.frameFx, core.frameFy)
            glUniform2f(uCIn, core.frameCx, core.frameCy)
            // Per-frame distortion k[0..3] + static k[4..11] (merged into 3 × vec4)
            var mergedK: [Float] = [Float](repeating: 0, count: 12)
            mergedK[0] = core.frameK[0]
            mergedK[1] = core.frameK[1]
            mergedK[2] = core.frameK[2]
            mergedK[3] = core.frameK[3]
            for i in 4..<12 { mergedK[i] = core.distortionK[i] }
            mergedK.withUnsafeBufferPointer { kPtr in
                glUniform4fv(uDistK, 3, kPtr.baseAddress)
            }
            glUniform1i(uDistModel, core.distortionModel)
            glUniform1f(uRLimit, core.rLimit)
            glUniform1f(uFrameFov, core.frameFov)
            glUniform1f(uLensCorr, core.lensCorrectionAmount)

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
        mpvLayer.prepareForContent(hdrType: hdrType)
        mpvLayer.loadFile(path)
        mpvLayer.setMute(false)   // Unmute (MDK starts muted)
        mpvLayer.setPause(false)  // Play immediately (deferred from user press)
    }

    func stop() {
        controller?.stopPolling()
        mpvLayer.stop()
        stopScope()
        currentPath = nil
    }

    // Gyro stabilization pass-through
    nonisolated func loadGyroCore(_ core: GyroCoreProvider?) {
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

    // Playback pass-throughs — nonisolated for poll queue access.
    nonisolated var isPaused: Bool { mpvLayer.isPaused }
    nonisolated var isEOFReached: Bool { mpvLayer.isEOFReached }
    nonisolated var currentTime: Double { mpvLayer.currentTime }
    nonisolated var videoDuration: Double { mpvLayer.videoDuration }
    nonisolated var renderFPS: Double { mpvLayer.renderFPS }
    nonisolated var renderCV: Double { mpvLayer.renderCV }
    nonisolated var renderStability: Double { mpvLayer.renderStability }
    nonisolated var videoFPS: Double { mpvLayer.videoFPS }
    nonisolated var layerColorspaceInfo: String { mpvLayer.layerColorspaceInfo }
    nonisolated var mdkColorspaceInfo: String { mpvLayer.mdkColorspaceInfo }
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
        // Apply HDR toggle state (no-op if unchanged; re-renders on option change)
        nsView.applyHDR(showHDR: showHDR, hdrType: hdrType)
    }

    static func dismantleNSView(_ nsView: MPVPlayerNSView, coordinator: ()) {
        nsView.stop()
    }
}
