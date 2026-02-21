import SwiftUI
import OpenGL.GL3
import CoreVideo
import Darwin

// MARK: - MPVOpenGLLayer

/// CAOpenGLLayer that renders video via libmpv with per-content HDR configuration.
///
/// HDR pipeline — colorspace-only steering, mpv options left on auto:
///   HLG   → CALayer colorspace = itur_2100_HLG; mpv target-trc = auto
///   HDR10 → CALayer colorspace = itur_2100_PQ;  mpv target-trc = auto
///   SDR toggle → CALayer = sRGB, target-trc = bt.709 (explicit, to force SDR output)
///   SDR content → CALayer = sRGB, target-trc = auto
///
/// Dolby Vision (Apple Profile 8.4) decoded by VideoToolbox as HLG, not PQ.
/// DV is handled by AVPlayer (see PhotoDetailView.loadVideo).
class MPVOpenGLLayer: CAOpenGLLayer {

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

    // Keeps "opengl" string alive during render context creation
    private let apiTypeStr = "opengl" as NSString

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
        // Try 64-bit float framebuffer (better HDR precision)
        let floatAttrs: [CGLPixelFormatAttribute] = [
            kCGLPFADoubleBuffer, kCGLPFAAccelerated,
            kCGLPFAColorSize,  _CGLPixelFormatAttribute(rawValue: 64),
            kCGLPFAColorFloat, _CGLPixelFormatAttribute(rawValue: 0)
        ]
        var pf: CGLPixelFormatObj?
        var n = GLint(0)

        if CGLChoosePixelFormat(floatAttrs, &pf, &n) == kCGLNoError, let pf {
            isFloat = true
            cglPF = pf
            contentsFormat = .RGBA16Float
        } else {
            let stdAttrs: [CGLPixelFormatAttribute] = [
                kCGLPFADoubleBuffer, kCGLPFAAccelerated,
                _CGLPixelFormatAttribute(rawValue: 0)
            ]
            CGLChoosePixelFormat(stdAttrs, &pf, &n)
            cglPF = pf
        }

        // Default to SDR; prepareForContent(isHLG:) sets HLG colorspace when needed.
        wantsExtendedDynamicRangeContent = true

        if let pf = cglPF {
            CGLCreateContext(pf, nil, &cglCtx)
        }
    }

    // MARK: - mpv setup

    private func setupMPV() {
        let lib = LibMPV.shared
        guard let ctx = lib.create?() else { return }
        mpvCtx = ctx

        lib.set(ctx, "vo", "libmpv")
        lib.set(ctx, "hwdec", "auto")
        lib.set(ctx, "keep-open", "yes")       // pause at end of file, don't terminate
        lib.set(ctx, "pause", "yes")           // start paused; user presses Space to play
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
        let isHLG = hdrType == .hlg
        let isPQ  = hdrType == .hdr10   // DV handled by AVPlayer, won't reach here

        // --- CALayer colorspace ---
        // Tell macOS compositor the correct transfer function for mpv's output.
        // mpv with target-trc=auto will output in the source TRC, so colorspace must match.
        if showHDR && isHLG {
            colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        } else if showHDR && isPQ {
            colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        } else {
            colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        guard let ctx = mpvCtx else { return }
        let lib = LibMPV.shared

        // --- mpv rendering options ---
        if !showHDR && hdrType != nil {
            // SDR toggle: explicitly force bt.709 so mpv tone-maps HDR → SDR output
            lib.set(ctx, "target-trc",  "bt.709")
            lib.set(ctx, "target-prim", "bt.709")
            lib.set(ctx, "target-peak", "auto")
            lib.set(ctx, "hdr-compute-peak", "auto")
        } else {
            // HDR on or SDR content: let mpv auto-detect everything
            lib.set(ctx, "target-trc",  "auto")
            lib.set(ctx, "target-prim", "auto")
            lib.set(ctx, "target-peak", "auto")
            lib.set(ctx, "hdr-compute-peak", "auto")
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
                layer.pendingFrame = true
                layer.setNeedsDisplay()
            }, selfRef)
        }}
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

    /// Cumulative frames dropped by the renderer since playback started.
    var droppedFrames: Int {
        guard let ctx = mpvCtx, let fn = LibMPV.shared.getStr else { return 0 }
        guard let val = "frame-drop-count".withCString({ fn(ctx, $0) }) else { return 0 }
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
        // Only render when mpv has signalled a new frame — avoids busy-rendering
        // static content (e.g. paused video) at 120 Hz.
        renderCtx != nil && pendingFrame
    }

    override func draw(inCGLContext ctx: CGLContextObj,
                       pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval,
                       displayTime ts: UnsafePointer<CVTimeStamp>?) {
        pendingFrame = false   // consume the pending-frame flag before rendering
        let lib = LibMPV.shared
        guard let rc = renderCtx,
              let renderFn = lib.rcRender,
              let swapFn   = lib.rcSwap else { return }

        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }

        var dims = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)
        let w = dims[2] > 0 ? dims[2] : 1
        let h = dims[3] > 0 ? dims[3] : 1

        var fboID = GLint(0)
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fboID)

        var fbo   = MPVOpenGLFBO(fbo: fboID, w: w, h: h, internal_format: 0)
        var flipY = Int32(1)
        var depth = Int32(isFloat ? 16 : 8)

        withUnsafeMutablePointer(to: &fbo)   { fboPtr  in
        withUnsafeMutablePointer(to: &flipY) { flipPtr in
        withUnsafeMutablePointer(to: &depth) { depthPtr in
            var params: [MPVRenderParam] = [
                MPVRenderParam(MPV_RC_OGL_FBO, UnsafeMutableRawPointer(fboPtr)),
                MPVRenderParam(MPV_RC_FLIP_Y,  UnsafeMutableRawPointer(flipPtr)),
                MPVRenderParam(MPV_RC_DEPTH,   UnsafeMutableRawPointer(depthPtr)),
                MPVRenderParam()
            ]
            params.withUnsafeMutableBufferPointer { buf in
                _ = renderFn(rc, UnsafeMutableRawPointer(buf.baseAddress!))
            }
            // report_swap is called by CVDisplayLink at the actual vsync moment,
            // which is more accurate than calling it here right after render().
        }}}

        // ── Frame timing measurement (skipped when diagnostics are disabled) ──
        guard diagnosticsEnabled else { return }
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt < 2.0 {                           // ignore paused gaps
                frameIntervals.append(dt)
                if frameIntervals.count > 60 { frameIntervals.removeFirst() }

                if frameIntervals.count >= 5 {
                    let mean = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                    renderFPS = mean > 0 ? 1.0 / mean : 0

                    // CV (coefficient of variation): lower = more stable
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
        wantsExtendedDynamicRangeOpenGLSurface = true
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
    }

    func stop() {
        controller?.stopPolling()
        mpvLayer.stop()
        stopScope()
        currentPath = nil
    }

    // HDR toggle pass-through
    func applyHDR(showHDR: Bool, hdrType: VideoHDRType?) {
        mpvLayer.applyHDRSettings(showHDR: showHDR, hdrType: hdrType)
    }

    // Diagnostics pass-through
    var diagnosticsEnabled: Bool {
        get { mpvLayer.diagnosticsEnabled }
        set { mpvLayer.diagnosticsEnabled = newValue }
    }

    // Playback pass-throughs
    var isPaused: Bool { mpvLayer.isPaused }
    var isEOFReached: Bool { mpvLayer.isEOFReached }
    var currentTime: Double { mpvLayer.currentTime }
    var videoDuration: Double { mpvLayer.videoDuration }
    var hwdecCurrent: String { mpvLayer.hwdecCurrent }
    var renderFPS: Double { mpvLayer.renderFPS }
    var renderCV: Double { mpvLayer.renderCV }
    var renderStability: Double { mpvLayer.renderStability }
    var videoFPS: Double { mpvLayer.videoFPS }
    var droppedFrames: Int { mpvLayer.droppedFrames }
    func setPause(_ paused: Bool) { mpvLayer.setPause(paused) }
    func seek(to seconds: Double) { mpvLayer.seek(to: seconds) }

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

    deinit { stop() }
}

// MARK: - MPVController

/// Observable state for mpv playback; polled via background queue at ~4 Hz.
///
/// Property reads (mpv C API calls) happen on `pollQueue` (background) to keep the
/// main thread free for `layer.display()` calls — this is the primary fix for high CV.
/// Only the lightweight @Observable setter assignments are dispatched back to main.
@Observable
final class MPVController {
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    /// Actual render FPS measured in draw() — updated ~every frame.
    private(set) var renderFPS: Double = 0
    /// Coefficient of variation of frame intervals (stddev/mean).
    private(set) var renderCV: Double = 0
    /// 0 = jittery, 1 = perfectly stable.
    private(set) var renderStability: Double = 1
    /// Declared FPS of the video file.
    private(set) var videoFPS: Double = 0
    /// Cumulative dropped frames reported by mpv.
    private(set) var droppedFrames: Int = 0
    /// Reflects the actual hardware decoder in use after file load (e.g. "videotoolbox").
    private(set) var hwdecInfo: String = "-"

    private weak var nsView: MPVPlayerNSView?
    /// Serial background queue: reads mpv properties off the main thread.
    private let pollQueue = DispatchQueue(label: "com.spectrum.mpv.poll", qos: .utility)
    private var isPolling = false
    private var hwdecCheckTask: Task<Void, Never>?

    /// When false, all diagnostic reads (FPS, CV, hwdec) are skipped — zero overhead.
    var diagnosticsEnabled: Bool = true {
        didSet {
            nsView?.diagnosticsEnabled = diagnosticsEnabled
            if !diagnosticsEnabled {
                hwdecCheckTask?.cancel()
                hwdecCheckTask = nil
            }
        }
    }

    /// Call before loading a new file to clear stale state.
    func reset() {
        currentTime = 0
        duration = 0
        isPlaying = false
        renderFPS = 0
        renderCV = 0
        renderStability = 1
        videoFPS = 0
        droppedFrames = 0
        hwdecInfo = "-"
        hwdecCheckTask?.cancel()
    }

    func startPolling(view: MPVPlayerNSView) {
        guard nsView !== view else { return }   // already polling this view
        nsView = view
        // After 1 s the file should be open; read the actual decoder for diagnostics.
        hwdecCheckTask?.cancel()
        if diagnosticsEnabled {
            hwdecCheckTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let v = self.nsView else { return }
                self.hwdecInfo = v.hwdecCurrent
            }
        }
        isPolling = true
        schedulePoll()
    }

    private func schedulePoll() {
        pollQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.doPoll()
        }
    }

    /// Runs on `pollQueue` (background). Reads all mpv properties off the main thread,
    /// then dispatches only the fast @Observable property assignments back to main.
    private func doPoll() {
        guard isPolling, let v = nsView else {
            isPolling = false
            return
        }
        // mpv C API (mpv_get_property_string) is thread-safe per mpv documentation.
        // Playback state (always needed for control bar)
        let d       = v.videoDuration
        let eof     = v.isEOFReached
        let ct      = eof ? 0.0 : v.currentTime
        let playing = eof ? false : !v.isPaused

        // Diagnostics (only read when badge is enabled — zero overhead otherwise)
        let diag = diagnosticsEnabled
        let fps     = diag ? v.renderFPS     : 0
        let cv      = diag ? v.renderCV      : 0
        let stab    = diag ? v.renderStability : 1
        let vfps    = diag ? v.videoFPS      : 0
        let dropped = diag ? v.droppedFrames : 0

        // Main thread only does fast property assignments — no mpv API calls here.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if d > 0 { self.duration = d }
            if eof {
                self.currentTime = 0
                self.isPlaying = false
            } else {
                self.currentTime = ct
                self.isPlaying = playing
            }
            if diag {
                self.renderFPS = fps
                self.renderCV = cv
                self.renderStability = stab
                if vfps > 0 { self.videoFPS = vfps }
                self.droppedFrames = dropped
            }
        }

        schedulePoll()
    }

    func stopPolling() {
        hwdecCheckTask?.cancel()
        hwdecCheckTask = nil
        isPolling = false
        nsView = nil
    }

    func togglePlayPause() {
        if !isPlaying, let v = nsView, v.isEOFReached {
            // Replay from beginning
            v.seek(to: 0)
        }
        isPlaying.toggle()
        nsView?.setPause(!isPlaying)
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        nsView?.seek(to: seconds)
    }
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

// MARK: - MPVControlBar

struct MPVControlBar: View {
    let controller: MPVController
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0   // normalised 0…1

    var body: some View {
        HStack(spacing: 8) {
            // Play / Pause — matches AVPlayerView button weight & size
            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            // Elapsed time
            Text(formatTime(displaySeconds))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            // Scrubber
            Slider(
                value: Binding(
                    get: {
                        isScrubbing ? scrubPosition
                            : (controller.duration > 0
                               ? controller.currentTime / controller.duration
                               : 0)
                    },
                    set: { scrubPosition = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        controller.seek(to: scrubPosition * controller.duration)
                    }
                }
            )
            .controlSize(.small)

            // Remaining / total
            Text(formatTime(controller.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var displaySeconds: Double {
        isScrubbing ? scrubPosition * controller.duration : controller.currentTime
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
