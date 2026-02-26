import Cocoa
import OpenGL.GL3

// MARK: - MPVImageView (Mode 7: libmpv rendering)

class MPVImageView: NSView {
    private var mpvLayer: MPVImageLayer?
    private var loadedPath: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        guard LibMPV.shared.ok else {
            print("[mpv-img] libmpv not available: \(LibMPV.shared.loadedPath ?? "not found")")
            return
        }
        print("[mpv-img] loaded: \(LibMPV.shared.loadedPath ?? "?")")

        let l = MPVImageLayer()
        mpvLayer = l
        l.frame = bounds
        l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(l)
    }

    required init?(coder: NSCoder) { fatalError() }

    func loadImage(path: String) {
        guard loadedPath != path else { return }
        loadedPath = path
        mpvLayer?.loadImage(path: path)
    }

    func applyHDR(on: Bool) {
        mpvLayer?.applyHDR(on: on)
    }

    func adjustZoom(delta: Double) {
        mpvLayer?.adjustZoom(delta: delta)
    }

    func resetZoom() {
        mpvLayer?.resetZoom()
    }

    func adjustPan(dx: Double, dy: Double) {
        mpvLayer?.adjustPan(dx: dx, dy: dy)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2.0
        mpvLayer?.contentsScale = scale
    }

    override func layout() {
        super.layout()
        mpvLayer?.frame = bounds
        mpvLayer?.requestRedraw()
    }

    deinit {
        mpvLayer?.shutdown()
    }
}

// MARK: - MPVImageLayer

class MPVImageLayer: CAOpenGLLayer {

    private var mpvCtx:    OpaquePointer?
    private var renderCtx: OpaquePointer?
    private var cglPF:     CGLPixelFormatObj?
    private var cglCtx:    CGLContextObj?
    private var isFloat    = false
    private var pendingFrame = false
    private let apiTypeStr = "opengl" as NSString

    override init() {
        super.init()
        isAsynchronous = true
        setupGL()
        setupMPV()
    }

    required init?(coder: NSCoder) { fatalError() }

    func requestRedraw() {
        pendingFrame = true
    }

    // MARK: - GL Setup

    private func setupGL() {
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

        wantsExtendedDynamicRangeContent = true

        if let pf = cglPF {
            CGLCreateContext(pf, nil, &cglCtx)
        }
    }

    // MARK: - mpv Setup

    private func setupMPV() {
        let lib = LibMPV.shared
        guard let ctx = lib.create?() else { return }
        mpvCtx = ctx

        lib.set(ctx, "vo", "libmpv")
        lib.set(ctx, "pause", "yes")
        lib.set(ctx, "keep-open", "yes")
        lib.set(ctx, "image-display-duration", "inf")
        lib.set(ctx, "hwdec", "auto")
        lib.set(ctx, "keepaspect", "yes")
        lib.set(ctx, "background", "color")
        lib.set(ctx, "vid", "auto")

        guard lib.initialize?(ctx) == 0 else {
            print("[mpv-img] mpv_initialize failed")
            return
        }
        setupRenderContext(ctx: ctx)
        startEventThread()
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
            guard err == 0, let rc else {
                print("[mpv-img] render context creation failed: \(err)")
                return
            }
            renderCtx = rc

            let selfRef = Unmanaged.passUnretained(self).toOpaque()
            rcSetCb(rc, { ptr in
                guard let ptr else { return }
                let layer = Unmanaged<MPVImageLayer>.fromOpaque(ptr).takeUnretainedValue()
                layer.pendingFrame = true
            }, selfRef)
        }}
    }

    private func startEventThread() {
        Thread.detachNewThread { [weak self] in
            guard let self,
                  let ctx = self.mpvCtx,
                  let waitFn = LibMPV.shared.waitEvent else { return }
            while true {
                let evRaw = waitFn(ctx, -1)
                let ev = evRaw.assumingMemoryBound(to: MPVEvent.self)
                let eid = ev.pointee.event_id
                if eid == MPV_EV_SHUTDOWN { return }
                if eid == 8 { // MPV_EVENT_FILE_LOADED
                    self.selectBestVideoTrack()
                }
            }
        }
    }

    /// After file loads, find the video track with the largest resolution and switch to it.
    private func selectBestVideoTrack() {
        guard let ctx = mpvCtx else { return }
        let lib = LibMPV.shared

        guard let countRaw = lib.getStr?(ctx, "track-list/count") else { return }
        let count = Int(String(cString: countRaw)) ?? 0
        lib.free?(countRaw)

        var bestId = -1
        var bestPixels = 0

        for i in 0..<count {
            let typeProp = "track-list/\(i)/type"
            guard let typeRaw = typeProp.withCString({ lib.getStr?(ctx, $0) }) else { continue }
            let type = String(cString: typeRaw)
            lib.free?(typeRaw)
            guard type == "video" else { continue }

            let wProp = "track-list/\(i)/demux-w"
            let hProp = "track-list/\(i)/demux-h"
            let idProp = "track-list/\(i)/id"

            let wRaw = wProp.withCString { lib.getStr?(ctx, $0) }
            let hRaw = hProp.withCString { lib.getStr?(ctx, $0) }
            let idRaw = idProp.withCString { lib.getStr?(ctx, $0) }

            let w = wRaw.flatMap { Int(String(cString: $0)) } ?? 0
            let h = hRaw.flatMap { Int(String(cString: $0)) } ?? 0
            let tid = idRaw.flatMap { Int(String(cString: $0)) } ?? 0

            if let s = wRaw  { lib.free?(s) }
            if let s = hRaw  { lib.free?(s) }
            if let s = idRaw { lib.free?(s) }

            let pixels = w * h
            print("[mpv-img] track \(i): vid=\(tid) \(w)×\(h) (\(pixels) px)")

            if pixels > bestPixels {
                bestPixels = pixels
                bestId = tid
            }
        }

        if bestId > 0 {
            print("[mpv-img] selecting vid=\(bestId) (\(bestPixels) px)")
            lib.setProperty(ctx, "vid", "\(bestId)")
            pendingFrame = true
        }
    }

    // MARK: - Image loading

    func loadImage(path: String) {
        guard let ctx = mpvCtx, let cmd = LibMPV.shared.command else { return }
        let args: [String] = ["loadfile", path]
        var cargs = args.map { strdup($0) }
        cargs.append(nil)
        _ = cmd(ctx, cargs.map { UnsafePointer($0) })
        cargs.compactMap { $0 }.forEach { Darwin.free($0) }
        pendingFrame = true
    }

    // MARK: - HDR toggle

    func applyHDR(on: Bool) {
        if on {
            colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        } else {
            colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        guard let ctx = mpvCtx else { return }
        let lib = LibMPV.shared
        if on {
            lib.setProperty(ctx, "target-trc", "auto")
            lib.setProperty(ctx, "target-prim", "auto")
        } else {
            lib.setProperty(ctx, "target-trc", "bt.709")
            lib.setProperty(ctx, "target-prim", "bt.709")
        }
        pendingFrame = true
    }

    // MARK: - Zoom control

    func adjustZoom(delta: Double) {
        guard let ctx = mpvCtx else { return }
        let lib = LibMPV.shared
        // video-zoom is log2 scale: +1 = 2x, -1 = 0.5x
        if let cur = lib.getStr?(ctx, "video-zoom") {
            let curVal = Double(String(cString: cur)) ?? 0.0
            lib.free?(cur)
            lib.setProperty(ctx, "video-zoom", String(format: "%.2f", curVal + delta))
        } else {
            lib.setProperty(ctx, "video-zoom", String(format: "%.2f", delta))
        }
        pendingFrame = true
    }

    func resetZoom() {
        guard let ctx = mpvCtx else { return }
        let lib = LibMPV.shared
        lib.setProperty(ctx, "video-zoom", "0")
        lib.setProperty(ctx, "video-pan-x", "0")
        lib.setProperty(ctx, "video-pan-y", "0")
        pendingFrame = true
    }

    func adjustPan(dx: Double, dy: Double) {
        guard let ctx = mpvCtx else { return }
        let lib = LibMPV.shared
        if let curX = lib.getStr?(ctx, "video-pan-x"),
           let curY = lib.getStr?(ctx, "video-pan-y") {
            let x = Double(String(cString: curX)) ?? 0.0
            let y = Double(String(cString: curY)) ?? 0.0
            lib.free?(curX); lib.free?(curY)
            lib.setProperty(ctx, "video-pan-x", String(format: "%.4f", x + dx))
            lib.setProperty(ctx, "video-pan-y", String(format: "%.4f", y + dy))
        }
        pendingFrame = true
    }

    // MARK: - CAOpenGLLayer rendering

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        return cglPF!
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        return cglCtx!
    }

    override func canDraw(inCGLContext ctx: CGLContextObj,
                          pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval,
                          displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        if bounds.width < 1 || bounds.height < 1 { return false }
        return pendingFrame
    }

    override func draw(inCGLContext glCtx: CGLContextObj,
                       pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval,
                       displayTime ts: UnsafePointer<CVTimeStamp>?) {
        pendingFrame = false
        guard let renderCtx, let rcRender = LibMPV.shared.rcRender else { return }

        CGLLockContext(glCtx)
        defer { CGLUnlockContext(glCtx) }

        // Query the ACTUAL system FBO — NOT hardcoded 0
        var displayFBO = GLint(0)
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &displayFBO)

        // Compute pixel dimensions from bounds × contentsScale
        // (GL_VIEWPORT may return 0 on CAOpenGLLayer; bounds is in points)
        let scale = contentsScale
        let w = Int32(max(1, bounds.width * scale))
        let h = Int32(max(1, bounds.height * scale))

        var fbo = MPVOpenGLFBO(fbo: Int32(displayFBO), w: w, h: h, internal_format: 0)
        var flipY: Int32 = 1
        var depth: Int32 = isFloat ? 16 : 8

        withUnsafeMutablePointer(to: &fbo)   { fboPtr   in
        withUnsafeMutablePointer(to: &flipY) { flipPtr  in
        withUnsafeMutablePointer(to: &depth) { depthPtr in
            var params: [MPVRenderParam] = [
                MPVRenderParam(MPV_RC_OGL_FBO, UnsafeMutableRawPointer(fboPtr)),
                MPVRenderParam(MPV_RC_FLIP_Y,  UnsafeMutableRawPointer(flipPtr)),
                MPVRenderParam(MPV_RC_DEPTH,   UnsafeMutableRawPointer(depthPtr)),
                MPVRenderParam()
            ]
            params.withUnsafeMutableBufferPointer { buf in
                _ = rcRender(renderCtx, UnsafeMutableRawPointer(buf.baseAddress!))
            }
        }}}

        LibMPV.shared.rcSwap?(renderCtx)
    }

    // MARK: - Cleanup

    func shutdown() {
        if let rc = renderCtx {
            LibMPV.shared.rcFree?(rc)
            renderCtx = nil
        }
        if let ctx = mpvCtx {
            LibMPV.shared.destroy?(ctx)
            mpvCtx = nil
        }
    }
}
