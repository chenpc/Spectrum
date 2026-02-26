// testmpv — Sony HLG 亮度 + 靜態圖片測試 App (仿照 IINA 架構)
//
// Build: bash build.sh
// Run:   ./testmpv /path/to/sony-hlg.mp4
//        ./testmpv /path/to/photo.HIF
//
// mpv log: /tmp/testmpv.log  (詳細解碼資訊)

// 抑制 OpenGL 棄用警告（我們刻意使用，因為 mpv 也用 OpenGL）
#if canImport(OpenGL)
// suppressed by -Xfrontend -disable-safety-checks if needed
#endif

import Cocoa
import OpenGL.GL3
import CoreVideo
import Darwin
import AVFoundation

// 關閉 stdout buffering，確保 print() 在 process 被 kill 前就寫出
setbuf(stdout, nil)

// ════════════════════════════════════════════════════════
// MARK: - Stabilization Data
// ════════════════════════════════════════════════════════

// GyroCore: in-process gyroflow-core 矩陣計算
// 用 dlopen 載入 libgyrocore_c.dylib（與 libmpv 相同模式），無 subprocess
class GyroCore {
    // ── C function pointer types ──────────────────────────────────────────────
    private typealias FnLoad      = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, Double, Double, Double) -> UnsafeMutableRawPointer?
    private typealias FnGetParams = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias FnGetFrame  = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnFree      = @convention(c) (UnsafeMutableRawPointer) -> Void

    // ── 公開元數據 ────────────────────────────────────────────────────────────
    private(set) var frameCount:  Int    = 0
    private(set) var rowCount:    Int    = 1
    private(set) var gyroFx:      Float  = 0
    private(set) var gyroFy:      Float  = 0
    private(set) var gyroCx:      Float  = 0
    private(set) var gyroCy:      Float  = 0
    private(set) var gyroVideoW:  Float  = 0
    private(set) var gyroVideoH:  Float  = 0
    private(set) var gyroFps:     Double = 30

    private var _isReady  = false
    private let readyLock = NSLock()
    var isReady: Bool {
        readyLock.lock(); defer { readyLock.unlock() }; return _isReady
    }

    // ── Rust handle 鎖（保護 computeMatrix 與 stop() 並發）─────────────────────
    private let coreLock   = NSLock()

    // ── 內部狀態 ──────────────────────────────────────────────────────────────
    private let ioQueue    = DispatchQueue(label: "gyrocore.init", qos: .userInteractive)
    private var libHandle:  UnsafeMutableRawPointer?   // dlopen handle
    private var coreHandle: UnsafeMutableRawPointer?   // *mut State (Rust Box)
    private var fnLoad:     FnLoad?
    private var fnGetParams: FnGetParams?
    private var fnGetFrame: FnGetFrame?
    private var fnFree:     FnFree?

    static var dylibPath: String {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("libgyrocore_c.dylib").path
    }

    static func readoutMs(for fps: Double) -> Double {
        if fps >= 100 { return 8.0 }
        if fps >= 50  { return 15.0 }
        return 20.0
    }

    // ── 載入 dylib 並在背景執行 gyrocore_load ────────────────────────────────
    func start(videoPath: String, lensPath: String? = nil, readoutMs: Double,
               smoothness: Double = 0.5, gyroOffsetMs: Double = 0.0,
               onReady: @escaping () -> Void,
               onError: @escaping (String) -> Void) {
        let path = Self.dylibPath
        guard let lib = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            onError("dlopen 失敗：\(String(cString: dlerror()))"); return
        }
        libHandle = lib

        guard let s1 = dlsym(lib, "gyrocore_load"),
              let s2 = dlsym(lib, "gyrocore_get_params"),
              let s3 = dlsym(lib, "gyrocore_get_frame"),
              let s4 = dlsym(lib, "gyrocore_free") else {
            onError("dlsym 失敗：找不到 gyrocore 符號"); return
        }
        fnLoad      = unsafeBitCast(s1, to: FnLoad.self)
        fnGetParams = unsafeBitCast(s2, to: FnGetParams.self)
        fnGetFrame  = unsafeBitCast(s3, to: FnGetFrame.self)
        fnFree      = unsafeBitCast(s4, to: FnFree.self)

        ioQueue.async { [weak self] in
            self?.loadCore(videoPath: videoPath, lensPath: lensPath, readoutMs: readoutMs,
                           smoothness: smoothness, gyroOffsetMs: gyroOffsetMs,
                           onReady: onReady, onError: onError)
        }
    }

    /// ioQueue 上執行：呼叫 gyrocore_load（阻塞 ~0.3s）→ 讀取參數 → 標記 ready
    private func loadCore(videoPath: String, lensPath: String?, readoutMs: Double,
                          smoothness: Double, gyroOffsetMs: Double,
                          onReady: @escaping () -> Void,
                          onError: @escaping (String) -> Void) {
        guard let fn = fnLoad else { onError("No load fn"); return }

        let lensDesc = lensPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
        print("[gyro] 載入 \(URL(fileURLWithPath: videoPath).lastPathComponent)  lens=\(lensDesc)  readoutMs=\(readoutMs)  smooth=\(smoothness)  offset=\(gyroOffsetMs)ms")
        let handle: UnsafeMutableRawPointer?
        if let lp = lensPath {
            handle = videoPath.withCString { vp in lp.withCString { lpp in fn(vp, lpp, readoutMs, smoothness, gyroOffsetMs) } }
        } else {
            handle = videoPath.withCString { fn($0, nil, readoutMs, smoothness, gyroOffsetMs) }
        }
        guard let handle else { onError("gyrocore_load 失敗（無 gyro 資料？）"); return }
        coreHandle = handle

        // 讀取 40-byte 參數 blob（同 GRDY header 的 offset 排列）
        var buf = Data(count: 40)
        let rc = buf.withUnsafeMutableBytes { ptr in
            fnGetParams?(handle, ptr.baseAddress!) ?? -1
        }
        guard rc == 0 else { onError("gyrocore_get_params 失敗"); return }

        frameCount = Int(buf.withUnsafeBytes { $0.load(fromByteOffset:  0, as: UInt32.self) })
        rowCount   = Int(buf.withUnsafeBytes { $0.load(fromByteOffset:  4, as: UInt32.self) })
        gyroVideoW = Float(buf.withUnsafeBytes { $0.load(fromByteOffset:  8, as: UInt32.self) })
        gyroVideoH = Float(buf.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
        gyroFps    = buf.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Float64.self) }
        gyroFx     = buf.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Float32.self) }
        gyroFy     = buf.withUnsafeBytes { $0.load(fromByteOffset: 28, as: Float32.self) }
        gyroCx     = buf.withUnsafeBytes { $0.load(fromByteOffset: 32, as: Float32.self) }
        gyroCy     = buf.withUnsafeBytes { $0.load(fromByteOffset: 36, as: Float32.self) }

        readyLock.lock(); _isReady = true; readyLock.unlock()
        print(String(format: "[gyro] ✅ Ready: %d 幀×%d 行  f=[%.1f,%.1f]  c=[%.1f,%.1f]  %dx%d@%.3ffps",
                     frameCount, rowCount, gyroFx, gyroFy, gyroCx, gyroCy,
                     Int(gyroVideoW), Int(gyroVideoH), gyroFps))
        DispatchQueue.main.async { onReady() }
    }

    // ── Per-frame 矩陣（同步，直接在 render thread 呼叫，~0.5ms）────────────

    /// 最近一次 computeMatrix 的耗時（ms）；供 draw() 印出，無需加鎖（精度已足）
    private(set) var lastFetchMs: Double = 0

    /// 同步計算 frameIdx 的矩陣並展開為 vH×16 floats。
    /// 每行 4 texels (RGBA32F)：
    ///   texel 0: mat row 0 [m00, m01, m02, sx]
    ///   texel 1: mat row 1 [m10, m11, m12, sy]
    ///   texel 2: mat row 2 [m20, m21, m22, ra]
    ///   texel 3: OIS       [ox,  oy,  0,   0]
    /// render thread 呼叫；coreLock 保護並發的 stop()。
    func computeMatrix(frameIdx: Int) -> [Float]? {
        guard isReady else { return nil }
        coreLock.lock(); defer { coreLock.unlock() }
        guard let handle = coreHandle, let fn = fnGetFrame else { return nil }

        let vH     = Int(gyroVideoH)
        let rawLen = rowCount * 14
        var rawBuf = [Float](repeating: 0, count: rawLen)

        let t0 = CACurrentMediaTime()
        let result = rawBuf.withUnsafeMutableBufferPointer {
            fn(handle, UInt32(frameIdx), $0.baseAddress!)
        }
        lastFetchMs = (CACurrentMediaTime() - t0) * 1000
        guard result == Int32(rawLen) else { return nil }

        // 展開 rowCount×14 → vH×16 floats (matTex width=4, RGBA32F)
        var mats = [Float](repeating: 0, count: vH * 16)
        for y in 0..<vH {
            let r = rowCount == 1 ? 0 : min(y * rowCount / max(vH, 1), rowCount - 1)
            let s = r * 14; let b = y * 16
            // texel 0: matrix row 0 + sx
            mats[b+0]  = rawBuf[s+0]; mats[b+1]  = rawBuf[s+1]; mats[b+2]  = rawBuf[s+2]; mats[b+3]  = rawBuf[s+9]
            // texel 1: matrix row 1 + sy
            mats[b+4]  = rawBuf[s+3]; mats[b+5]  = rawBuf[s+4]; mats[b+6]  = rawBuf[s+5]; mats[b+7]  = rawBuf[s+10]
            // texel 2: matrix row 2 + ra
            mats[b+8]  = rawBuf[s+6]; mats[b+9]  = rawBuf[s+7]; mats[b+10] = rawBuf[s+8]; mats[b+11] = rawBuf[s+11]
            // texel 3: ox, oy
            mats[b+12] = rawBuf[s+12]; mats[b+13] = rawBuf[s+13]; mats[b+14] = 0; mats[b+15] = 0
        }
        return mats
    }

    // ── 停止並釋放資源 ────────────────────────────────────────────────────────
    func stop() {
        readyLock.lock(); _isReady = false; readyLock.unlock()
        // 等待 ioQueue 排空（loadCore 執行完畢後才 free）
        ioQueue.sync { }
        coreLock.lock()
        if let handle = coreHandle, let fn = fnFree { fn(handle) }
        coreHandle = nil
        coreLock.unlock()
        if let lib = libHandle { dlclose(lib) }
        libHandle = nil
    }
}

// ════════════════════════════════════════════════════════
// MARK: - mpv C API 型別定義
// ════════════════════════════════════════════════════════

// mpv_render_param_type
private let RC_API_TYPE: Int32    = 1
private let RC_OGL_INIT: Int32    = 2
private let RC_OGL_FBO: Int32     = 3
private let RC_FLIP_Y: Int32      = 4
private let RC_DEPTH: Int32       = 5
private let RC_ADVANCED: Int32    = 10

// mpv_event_id
private let EV_NONE: Int32          = 0
private let EV_SHUTDOWN: Int32      = 1
private let EV_FILE_LOADED: Int32   = 8
private let EV_END_FILE: Int32      = 9
private let EV_VIDEO_RECONFIG: Int32 = 17
private let EV_PROP_CHANGE: Int32   = 22

// mpv_end_file_reason
private let END_EOF: Int32   = 0
private let END_ERROR: Int32 = 3

// mpv_event_end_file: { int reason; int error; }
private struct MPVEndFile { var reason: Int32; var error: Int32 }

// mpv_format
private let FMT_STRING: Int32 = 1

// mpv_render_param: { int type; [4-byte pad]; void *data }
// LayoutL Int32(4B) + _pad(4B) + pointer(8B) = 16B，與 C struct 對齊
private struct RParam {
    var type: Int32
    private var _pad: Int32 = 0
    var data: UnsafeMutableRawPointer?
    init(_ t: Int32, _ d: UnsafeMutableRawPointer?) { type = t; _pad = 0; data = d }
    init() { type = 0; _pad = 0; data = nil }
}

// mpv_opengl_fbo
private struct OGLFBO {
    var fbo: Int32; var w: Int32; var h: Int32; var internal_format: Int32
}

// mpv_opengl_init_params
private struct OGLInit {
    var get_proc_address: (@convention(c) (UnsafeMutableRawPointer?,
                                           UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    var get_proc_address_ctx: UnsafeMutableRawPointer?
}

// mpv_event
private struct MPVEvent {
    var event_id: Int32; var error: Int32; var reply_userdata: UInt64
    var data: UnsafeMutableRawPointer?
}

// mpv_event_property
private struct MPVEventProp {
    var name: UnsafePointer<CChar>?; var format: Int32; var data: UnsafeMutableRawPointer?
}

// ════════════════════════════════════════════════════════
// MARK: - LibMPV
// ════════════════════════════════════════════════════════

// OpenGL proc address lookup
private let glLibHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)

private func glProcAddr(_ ctx: UnsafeMutableRawPointer?,
                        _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return dlsym(glLibHandle, name)
}

private class LibMPV {
    static let shared = LibMPV()
    private var h: UnsafeMutableRawPointer?
    private(set) var ok = false

    // @convention(c) 只能使用 ObjC 可表達的型別（OpaquePointer, UnsafePointer<CChar>, UnsafeMutableRawPointer 等）
    typealias FCreate   = @convention(c) () -> OpaquePointer?
    typealias FInit     = @convention(c) (OpaquePointer) -> Int32
    typealias FSetStr   = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    typealias FGetStr   = @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias FCmd      = @convention(c) (OpaquePointer, UnsafePointer<UnsafePointer<CChar>?>) -> Int32
    typealias FObs      = @convention(c) (OpaquePointer, UInt64, UnsafePointer<CChar>, Int32) -> Int32
    // FWait 回傳 RawPointer，呼叫端自行轉型為 UnsafeMutablePointer<MPVEvent>
    typealias FWait     = @convention(c) (OpaquePointer, Double) -> UnsafeMutableRawPointer
    typealias FWakeCb   = @convention(c) (OpaquePointer,
                                          (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
                                          UnsafeMutableRawPointer?) -> Void
    typealias FDestroy  = @convention(c) (OpaquePointer) -> Void
    typealias FFree     = @convention(c) (UnsafeMutableRawPointer?) -> Void
    // rcCreate / rcRender 使用 RawPointer 避免 ObjC 橋接問題
    typealias FRCCreate = @convention(c) (UnsafeMutableRawPointer,
                                          OpaquePointer,
                                          UnsafeMutableRawPointer) -> Int32
    typealias FRCCb     = @convention(c) (OpaquePointer,
                                          (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
                                          UnsafeMutableRawPointer?) -> Void
    typealias FRCRender = @convention(c) (OpaquePointer, UnsafeMutableRawPointer) -> Int32
    typealias FRCSwap   = @convention(c) (OpaquePointer) -> Void
    typealias FRCFree   = @convention(c) (OpaquePointer) -> Void

    var create:    FCreate?;    var initialize: FInit?;    var setStr:  FSetStr?
    var getStr:    FGetStr?;    var command:    FCmd?;     var observe: FObs?
    var waitEvent: FWait?;      var setWakeCb:  FWakeCb?
    var destroy:   FDestroy?;   var free:       FFree?
    var rcCreate:  FRCCreate?;  var rcSetCb:    FRCCb?
    var rcRender:  FRCRender?;  var rcSwap:     FRCSwap?; var rcFree: FRCFree?

    func load() -> Bool {
        let paths = [
            "/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib",
            "/Applications/IINA.app/Contents/Frameworks/libmpv.dylib",
            "/opt/homebrew/lib/libmpv.dylib",
            "/usr/local/lib/libmpv.dylib",
        ]
        for p in paths {
            h = dlopen(p, RTLD_LAZY | RTLD_GLOBAL)
            if h != nil { print("[libmpv] ✅ Loaded: \(p)"); break }
        }
        guard let h else {
            print("[libmpv] ❌ libmpv not found. Install IINA from https://iina.io")
            return false
        }

        // 顯式標記型別，幫助 Swift 推斷 generic 參數
        create    = dlsym(h, "mpv_create")              .map { unsafeBitCast($0, to: FCreate.self)   }
        initialize = dlsym(h, "mpv_initialize")         .map { unsafeBitCast($0, to: FInit.self)     }
        setStr    = dlsym(h, "mpv_set_option_string")   .map { unsafeBitCast($0, to: FSetStr.self)   }
        getStr    = dlsym(h, "mpv_get_property_string") .map { unsafeBitCast($0, to: FGetStr.self)   }
        command   = dlsym(h, "mpv_command")             .map { unsafeBitCast($0, to: FCmd.self)      }
        observe   = dlsym(h, "mpv_observe_property")    .map { unsafeBitCast($0, to: FObs.self)      }
        waitEvent = dlsym(h, "mpv_wait_event")          .map { unsafeBitCast($0, to: FWait.self)     }
        setWakeCb = dlsym(h, "mpv_set_wakeup_callback") .map { unsafeBitCast($0, to: FWakeCb.self)   }
        destroy   = dlsym(h, "mpv_terminate_destroy")   .map { unsafeBitCast($0, to: FDestroy.self)  }
        free      = dlsym(h, "mpv_free")                .map { unsafeBitCast($0, to: FFree.self)     }
        rcCreate  = dlsym(h, "mpv_render_context_create")             .map { unsafeBitCast($0, to: FRCCreate.self) }
        rcSetCb   = dlsym(h, "mpv_render_context_set_update_callback") .map { unsafeBitCast($0, to: FRCCb.self)    }
        rcRender  = dlsym(h, "mpv_render_context_render")             .map { unsafeBitCast($0, to: FRCRender.self) }
        rcSwap    = dlsym(h, "mpv_render_context_report_swap")        .map { unsafeBitCast($0, to: FRCSwap.self)  }
        rcFree    = dlsym(h, "mpv_render_context_free")               .map { unsafeBitCast($0, to: FRCFree.self)  }

        ok = create != nil
        return ok
    }

    // 便利：取得字串屬性（呼叫端不需要手動 free）
    func getString(_ ctx: OpaquePointer, _ key: String) -> String? {
        guard let fn = getStr else { return nil }
        return key.withCString { kPtr in
            guard let ptr = fn(ctx, kPtr) else { return nil }
            let s = String(cString: ptr)
            free?(ptr)
            return s
        }
    }

    // 便利：設定字串選項
    @discardableResult
    func set(_ ctx: OpaquePointer, _ key: String, _ val: String) -> Int32 {
        guard let fn = setStr else { return -1 }
        return key.withCString { k in val.withCString { v in fn(ctx, k, v) } }
    }
}

private let lib = LibMPV.shared

// ════════════════════════════════════════════════════════
// MARK: - MPVOpenGLLayer
// ════════════════════════════════════════════════════════

class MPVOpenGLLayer: CAOpenGLLayer {

    private var mpvCtx:    OpaquePointer?
    fileprivate var renderCtx: OpaquePointer?   // accessed by CVDisplayLink callback
    private var cglPF:     CGLPixelFormatObj?
    private var cglCtx:    CGLContextObj?
    private(set) var isFloat = false
    private var displayLink: CVDisplayLink?

    // mpv 有新 frame 時由 callback 設為 true；draw() 開頭清除。
    // arm64 Bool store/load 為單一指令，無需 lock。
    var hasPendingFrame = false
    // update callback 觸發時間；draw() 用此計算 vsync 延遲並補償 time-pos。
    // 注意：callback 中不可呼叫任何 mpv API（會死鎖），只記錄時間戳。
    var callbackTime: CFTimeInterval = 0
    // frame counter（每 60 幀印一次 log）
    private var frameCount = 0
    // gyro frame index 單調遞增保護（避免 time-pos 抖動導致矩陣跳動）
    var lastGyroFrameIdx: Int? = nil

    // Frame timing
    private var frameIntervals: [Double] = []
    private var lastFrameTime: CFTimeInterval = 0
    private(set) var renderFPS: Double = 0
    private(set) var renderCV: Double = 0

    // Stability metric: mean absolute error between consecutive frames (lower = more stable)
    // Written in render thread, read in main thread — single Float read/write is safe on ARM64
    private var prevThumb    = [UInt8](repeating: 0, count: 64 * 36 * 4)
    private var hasPrevThumb = false
    private(set) var stabilityScore: Float = -1

    var videoFPS: Double {
        guard let ctx = mpvCtx else { return 0 }
        return Double(lib.getString(ctx, "container-fps") ?? "0") ?? 0
    }
    var droppedFrames: Int {
        guard let ctx = mpvCtx else { return 0 }
        return Int(lib.getString(ctx, "frame-drop-count") ?? "0") ?? 0
    }

    // ── Warp pipeline (gyroflow-style per-row matrix) ────────
    private var stabFBO:    GLuint = 0     // intermediate FBO (mpv → here)
    private var stabTex:    GLuint = 0     // color texture attached to stabFBO
    private var stabW:      GLsizei = 0
    private var stabH:      GLsizei = 0
    private var warpProg:   GLuint = 0     // GLSL program
    private var warpVBO:    GLuint = 0     // fullscreen quad VBO
    private var matTexId:   GLuint = 0     // per-row matrix texture (width=3, height=videoH, RGBA32F)
    private var matTexH:    Int    = 0     // 目前 matTex 的高度（= videoHeight）
    // uniforms
    private var uTex:       GLint = -1
    private var uMatTex:    GLint = -1
    private var uVideoSize: GLint = -1
    private var uMatCount:  GLint = -1
    private var uFIn:       GLint = -1
    private var uCIn:       GLint = -1
    var gyroCore: GyroCore?            // non-nil → real-time warp active

    // 保留 NSString 確保 utf8String 指標在 render context 建立期間有效
    private let kOpenGL = "opengl" as NSString

    override init() {
        super.init()
        guard lib.ok else { return }
        // isAsynchronous = true：CAOpenGLLayer 在專屬 rendering thread 以 vsync 驅動 draw()
        // 主執行緒完全不參與 render，與 Spectrum 同步的修正。
        isAsynchronous = true
        setupGL()
        setupMPV()
    }
    required init?(coder: NSCoder) { fatalError() }

    // ─── OpenGL Pixel Format & Context ───────────────────

    private func setupGL() {
        // 嘗試 64-bit float（PQ HDR 精確輸出需要）
        // Apple Silicon (M 系列) 通常不支援，會 fallback 到 8-bit
        let floatAttrs: [CGLPixelFormatAttribute] = [
            kCGLPFADoubleBuffer,
            kCGLPFAAccelerated,
            kCGLPFAColorSize,  _CGLPixelFormatAttribute(rawValue: 64),
            kCGLPFAColorFloat,
            _CGLPixelFormatAttribute(rawValue: 0)
        ]
        var pf: CGLPixelFormatObj?
        var n = GLint(0)

        if CGLChoosePixelFormat(floatAttrs, &pf, &n) == kCGLNoError, let pf {
            print("[GL] ✅ Float framebuffer (64-bit RGBA) — 真正 HDR 精度")
            isFloat = true
            cglPF = pf
            contentsFormat = .RGBA16Float
            // HLG 直接輸出：使用 itur_2100_HLG colorspace
            // macOS 套用 HLG OOTF，根據顯示器能力自動縮放亮度
            colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        } else {
            print("[GL] ⚠️  Float framebuffer 不可用 (Apple Silicon 通常如此)")
            print("[GL]    Fallback 到 8-bit 標準格式，套用 HLG colorspace")
            let stdAttrs: [CGLPixelFormatAttribute] = [
                kCGLPFADoubleBuffer,
                kCGLPFAAccelerated,
                _CGLPixelFormatAttribute(rawValue: 0)
            ]
            CGLChoosePixelFormat(stdAttrs, &pf, &n)
            cglPF = pf
            colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        }

        // ★ 告知 macOS 此 layer 要顯示 EDR 內容
        wantsExtendedDynamicRangeContent = true

        if let pf = cglPF {
            CGLCreateContext(pf, nil, &cglCtx)
            print("[GL] CGL context created (isFloat=\(isFloat))")
        }

        setupWarpPipeline()
    }

    // ─── Warp Pipeline（gyroflow 方式：per-row matrix texture）──

    private func setupWarpPipeline() {
        guard let cglCtx else { return }
        CGLSetCurrentContext(cglCtx)

        // ── Vertex shader（不變）──
        let vsSrc = """
#version 120
attribute vec2 pos;
varying vec2 uv;
void main() {
    uv = pos * 0.5 + 0.5;
    gl_Position = vec4(pos, 0.0, 1.0);
}
"""
        // ── Fragment shader（gyroflow-core pipeline + IBIS/OIS）───────────────
        // matTex：width=4, height=videoH, GL_RGBA32F
        //   texel(0,y) = [m00, m01, m02, sx]   (matrix row 0 + IBIS shift x)
        //   texel(1,y) = [m10, m11, m12, sy]   (matrix row 1 + IBIS shift y)
        //   texel(2,y) = [m20, m21, m22, ra]   (matrix row 2 + IBIS rotation angle)
        //   texel(3,y) = [ox,  oy,  0,   0]    (OIS offset)
        //
        // Pipeline（同 gyroflow wgpu_undistort.wgsl rotate_and_distort()）：
        //   (_x,_y,_w) = mat3 × (out_x, out_y, 1)
        //   uv = fIn × (_x/_w, _y/_w)       ← perspective divide (distort_point identity for Sony)
        //   uv = IBIS_rotate(-ra) × uv - (sx,sy) + (ox,oy)   ← IBIS/OIS correction
        //   src = uv + cIn
        let fsSrc = """
#version 120
varying vec2 uv;
uniform sampler2D tex;       // mpv 渲染的原始幀
uniform sampler2D matTex;    // per-row 矩陣（width=4, height=matCount, RGBA32F）
uniform vec2  videoSize;     // 視訊解析度（e.g. 3840, 2160）
uniform float matCount;      // 矩陣列數（= videoHeight）
uniform vec2  fIn;           // 焦距像素 (fx, fy)
uniform vec2  cIn;           // 主點 (cx, cy)
// rotate_and_distort: 3×3 matrix × out_px → perspective divide → fIn × → IBIS → + cIn
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
    // IBIS correction (matches gyroflow rotate_and_distort lines 391-398)
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
    // mpv FLIP_Y=1：uv.y=0 是畫面底部，轉換到 image 座標（y=0 在頂部）
    vec2 out_px = vec2(uv.x * videoSize.x, (1.0 - uv.y) * videoSize.y);
    // Two-pass RS row indexing (matches gyroflow undistort_coord lines 501-521):
    // Pass 1: use middle matrix to estimate source row
    float sy = clamp(out_px.y, 0.0, matCount - 1.0);
    if (matCount > 1.0) {
        float midTexY = (floor(matCount * 0.5) + 0.5) / matCount;
        vec2 midPt = rotate_and_distort(out_px, midTexY);
        if (midPt.x > -99998.0) {
            sy = clamp(floor(0.5 + midPt.y), 0.0, matCount - 1.0);
        }
    }
    // Pass 2: use source-row matrix for final transform
    float texY = (sy + 0.5) / matCount;
    vec2 src_px = rotate_and_distort(out_px, texY);
    if (src_px.x < -99998.0) { gl_FragColor = vec4(0.0,0.0,0.0,1.0); return; }
    // 轉回 GL UV（y 反轉）
    vec2 src = vec2(src_px.x / videoSize.x, 1.0 - src_px.y / videoSize.y);
    if (any(lessThan(src, vec2(0.0))) || any(greaterThan(src, vec2(1.0)))) {
        gl_FragColor = vec4(0.0,0.0,0.0,1.0);
    } else {
        gl_FragColor = texture2D(tex, src);
    }
}
"""
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
        print("[Warp] ✅ gyroflow shader compiled (uMatTex=\(uMatTex) uVideoSize=\(uVideoSize))")

        // ── Fullscreen quad VBO ──
        var verts: [Float] = [-1,-1, 1,-1, -1,1, 1,1]
        glGenBuffers(1, &warpVBO)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), warpVBO)
        verts.withUnsafeMutableBytes { ptr in
            glBufferData(GLenum(GL_ARRAY_BUFFER), GLsizeiptr(ptr.count),
                         ptr.baseAddress, GLenum(GL_STATIC_DRAW))
        }
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), 0)

        // ── Per-row matrix texture（RGBA32F，width=3，height 在 draw() 動態設定）──
        glGenTextures(1, &matTexId)
        glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_NEAREST))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_NEAREST))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLint(GL_CLAMP_TO_EDGE))
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        // ── Intermediate FBO（尺寸在 draw() 動態設定）──
        glGenFramebuffers(1, &stabFBO)
        glGenTextures(1, &stabTex)
        glBindTexture(GLenum(GL_TEXTURE_2D), stabTex)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLint(GL_CLAMP_TO_EDGE))
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        print("[Warp] ✅ FBO + VBO + matTex ready")
    }

    private func compileShader(_ type: GLenum, _ src: String) -> GLuint {
        let sh = glCreateShader(type)
        src.withCString { ptr in
            var p: UnsafePointer<GLchar>? = ptr
            glShaderSource(sh, 1, &p, nil)
        }
        glCompileShader(sh)
        var ok = GLint(0)
        glGetShaderiv(sh, GLenum(GL_COMPILE_STATUS), &ok)
        if ok != GLint(GL_TRUE) {
            var buf = [GLchar](repeating: 0, count: 512)
            glGetShaderInfoLog(sh, 512, nil, &buf)
            print("[Warp] ❌ Shader compile: \(String(cString: buf))")
            glDeleteShader(sh); return 0
        }
        return sh
    }

    // ─── mpv 初始化 ─────────────────────────────────────

    private func setupMPV() {
        guard let ctx = lib.create?() else { return }
        mpvCtx = ctx

        // 基本選項
        lib.set(ctx, "vo", "libmpv")
        lib.set(ctx, "hwdec", "videotoolbox")    // DV 實驗：強制 FFmpeg software decode，讀 HLG base layer，忽略 DV RPU
        lib.set(ctx, "log-file", "/tmp/testmpv.log")
        lib.set(ctx, "msg-level", "all=v")

        // 靜態圖片：顯示不結束
        lib.set(ctx, "image-display-duration", "inf")

        // video-sync=display-resample：微調影片速度匹配顯示器刷新率，
        // 減少 time-pos 抖動（預設 audio 模式下 time-pos 有 ±幾 ms 波動）。
        lib.set(ctx, "video-sync", "display-resample")

        // ══ IINA 風格 HLG/HDR 三大關鍵選項 ══

        // 1. hdr-compute-peak=no
        //    不讓 mpv 從 metadata 自動估算 content peak。
        //    預設 auto 會讀到 HLG metadata peak ≈ 1000 nit，
        //    導致 reference white (100 nit) 只有 10% → 畫面極暗。
        lib.set(ctx, "hdr-compute-peak", "no")

        // 2. target-trc=hlg
        //    直接輸出 HLG（不轉 PQ）。
        //    mpv 保留 HLG 轉移函數，macOS 透過 itur_2100_HLG colorspace 套用系統 OOTF。
        //    ★ 避免 HLG→PQ 轉換時 OOTF 重疊導致顏色過飽和。
        lib.set(ctx, "target-trc", "hlg")

        // 3. target-prim=bt.2020
        //    Sony HLG 使用 BT.2020 色域，明確指定確保顏色正確。
        lib.set(ctx, "target-prim", "bt.2020")

        // 4. target-peak（HLG 模式）
        //    HLG 直接輸出時 peak 設 1000 nit（BT.2100 HLG 定義的 reference display）
        //    macOS 再根據實際顯示器能力套用 OOTF 縮放。
        lib.set(ctx, "target-peak", "1000")

        let edrPotential = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let edrCurrent   = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0

        print("[mpv] ─── 初始化設定 ─────────────────────")
        print("[mpv]   target-trc   = hlg  (直接 HLG，不轉 PQ)")
        print("[mpv]   target-prim  = bt.2020")
        print("[mpv]   target-peak  = 1000 nit  (BT.2100 HLG reference display)")
        print("[mpv]   EDR potential = \(String(format: "%.2f", edrPotential))x")
        print("[mpv]   EDR current   = \(String(format: "%.2f", edrCurrent))x")
        print("[mpv] ─────────────────────────────────────")

        guard lib.initialize?(ctx) == 0 else {
            print("[mpv] ❌ mpv_initialize failed"); return
        }

        // 觀察影片 / 圖片參數（for logging）
        lib.observe?(ctx, 1, "video-params/gamma",     FMT_STRING)
        lib.observe?(ctx, 2, "video-params/primaries",  FMT_STRING)
        lib.observe?(ctx, 3, "video-params/sig-peak",   FMT_STRING)
        lib.observe?(ctx, 4, "video-codec",             FMT_STRING)
        lib.observe?(ctx, 5, "video-format",            FMT_STRING)

        setupRenderContext(ctx: ctx)
        setupDisplayLink()
        startEventThread()
    }

    // ─── mpv Render Context (OpenGL) ────────────────────

    private func setupRenderContext(ctx: OpaquePointer) {
        guard let cglCtx, let rcCreate = lib.rcCreate, let rcSetCb = lib.rcSetCb else { return }

        CGLSetCurrentContext(cglCtx)

        var initParams = OGLInit(get_proc_address: glProcAddr, get_proc_address_ctx: nil)
        // ADVANCED_CONTROL=0：讓 mpv 管理自己的顯示時序（較簡單）
        // ADVANCED_CONTROL=1：由渲染端管理，需配合 mpv_render_context_update()
        var advanced: Int32 = 0

        withUnsafeMutablePointer(to: &initParams) { initPtr in
        withUnsafeMutablePointer(to: &advanced)   { advPtr  in
            var params: [RParam] = [
                RParam(RC_API_TYPE, UnsafeMutableRawPointer(mutating: kOpenGL.utf8String!)),
                RParam(RC_OGL_INIT, UnsafeMutableRawPointer(initPtr)),
                RParam(RC_ADVANCED, UnsafeMutableRawPointer(advPtr)),
                RParam()
            ]
            var rc: OpaquePointer?
            let err = withUnsafeMutablePointer(to: &rc) { rcPtr in
                params.withUnsafeMutableBufferPointer { buf in
                    // rcCreate 使用 RawPointer 簽名規避 ObjC 橋接限制
                    rcCreate(
                        UnsafeMutableRawPointer(rcPtr),
                        ctx,
                        UnsafeMutableRawPointer(buf.baseAddress!)
                    )
                }
            }
            guard err == 0, let rc else {
                print("[mpv] ❌ Render context create failed: \(err)"); return
            }
            renderCtx = rc
            print("[mpv] ✅ Render context created")

            // isAsynchronous = true：draw() 在 CAOpenGLLayer 的專屬 rendering thread 執行。
            // callback 只需標記 hasPendingFrame + 喚醒 layer，不再 dispatch to main。
            // setNeedsDisplay() 是 thread-safe，可從任意執行緒呼叫。
            let selfRef = Unmanaged.passUnretained(self).toOpaque()
            rcSetCb(rc, { ptr in
                guard let ptr else { return }
                let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(ptr).takeUnretainedValue()
                // ⚠️ callback 中禁止呼叫任何 mpv API（會死鎖）。
                // 只記錄時間戳，讓 draw() 用 elapsed time 補償 vsync 延遲。
                layer.callbackTime = CACurrentMediaTime()
                layer.hasPendingFrame = true
                layer.setNeedsDisplay()
            }, selfRef)
        }}
    }

    // ─── CVDisplayLink (swap report) ────────────────────

    private func setupDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { print("[DL] ❌ CVDisplayLink 建立失敗"); return }
        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, ctx -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(ctx).takeUnretainedValue()
            guard let rc = layer.renderCtx, let fn = lib.rcSwap else {
                return kCVReturnSuccess
            }
            fn(rc)
            return kCVReturnSuccess
        }, selfRef)
        CVDisplayLinkStart(dl)
        displayLink = dl
        print("[DL] ✅ CVDisplayLink started (swap report)")
    }

    // ─── mpv 事件執行緒 ─────────────────────────────────

    private func startEventThread() {
        Thread.detachNewThread { [weak self] in
            guard let self, let ctx = self.mpvCtx, let waitFn = lib.waitEvent else { return }
            print("[mpv] Event thread started")
            while true {
                // waitFn 回傳 RawPointer，轉型為 MPVEvent 指標
                let evRaw = waitFn(ctx, -1)
                let ev = evRaw.assumingMemoryBound(to: MPVEvent.self)
                switch ev.pointee.event_id {
                case EV_SHUTDOWN:
                    print("[mpv] Shutdown"); return
                case EV_FILE_LOADED:
                    print("[mpv] ─── File loaded ───")
                    self.logVideoParams()
                    // 依實際 gamma 動態設定色彩管線（DV="pq"、HLG="hlg"、SDR=其他）
                    if let ctx = self.mpvCtx {
                        let gamma = lib.getString(ctx, "video-params/gamma")    ?? ""
                        let prim  = lib.getString(ctx, "video-params/primaries") ?? "bt.2020"
                        self.applyColorMode(gamma: gamma, primaries: prim)
                    }
                case EV_END_FILE:
                    if let data = ev.pointee.data {
                        let ef = data.assumingMemoryBound(to: MPVEndFile.self)
                        if ef.pointee.reason == END_ERROR {
                            print("[mpv] ❌ End file ERROR: code=\(ef.pointee.error)")
                        } else {
                            print("[mpv] End file: reason=\(ef.pointee.reason)")
                        }
                    }
                case EV_VIDEO_RECONFIG:
                    print("[mpv] ─── Video Reconfig ───")
                    self.logVideoParams()
                    if let ctx = self.mpvCtx {
                        let gamma = lib.getString(ctx, "video-params/gamma")    ?? ""
                        let prim  = lib.getString(ctx, "video-params/primaries") ?? "bt.2020"
                        self.applyColorMode(gamma: gamma, primaries: prim)
                    }
                case EV_PROP_CHANGE:
                    if let propRaw = ev.pointee.data {
                        let prop = propRaw.assumingMemoryBound(to: MPVEventProp.self)
                        let pname = prop.pointee.name.map { String(cString: $0) } ?? "?"
                        if prop.pointee.format == FMT_STRING,
                           let valPtr = prop.pointee.data?.assumingMemoryBound(to: Optional<UnsafePointer<CChar>>.self),
                           let cStr = valPtr.pointee {
                            print("[mpv]   prop: \(pname) = \(String(cString: cStr))")
                        }
                    }
                default: break
                }
            }
        }
    }

    private func logVideoParams() {
        guard let ctx = mpvCtx else { return }
        let gamma  = lib.getString(ctx, "video-params/gamma")    ?? "?"
        let prim   = lib.getString(ctx, "video-params/primaries") ?? "?"
        let peak   = lib.getString(ctx, "video-params/sig-peak")  ?? "?"
        let hwdec  = lib.getString(ctx, "hwdec-current")          ?? "?"
        let codec  = lib.getString(ctx, "video-codec")            ?? "?"
        let fmt    = lib.getString(ctx, "video-format")           ?? "?"
        let w      = lib.getString(ctx, "width")                  ?? "?"
        let h      = lib.getString(ctx, "height")                 ?? "?"
        let csName = colorspace?.name.map { $0 as String } ?? "nil"
        print("[mpv] ─── Video/Image Params ──────────────")
        print("[mpv]   codec      = \(codec)")
        print("[mpv]   format     = \(fmt)  \(w)x\(h)")
        print("[mpv]   gamma      = \(gamma)")
        print("[mpv]   primaries  = \(prim)")
        print("[mpv]   sig-peak   = \(peak)")
        print("[mpv]   hwdec      = \(hwdec)")
        print("[mpv]   GL isFloat = \(isFloat)")
        print("[mpv]   colorspace = \(csName)")
        print("[mpv] ──────────────────────────────────────")
    }

    // ─── 依 video-params/gamma 動態選色彩管線 ────────────
    //
    // IINA 的做法：讀 mpv 回報的 gamma（非容器 metadata），
    // 依此設定 CALayer colorspace 與 mpv target-trc。
    //
    // DV P8.4：mpv 回報 gamma="pq"（VideoToolbox 以 PQ 解碼）
    // HLG：gamma="hlg"；SDR：gamma="srgb" / "bt.709" / 其他
    //
    // 呼叫端可在任意執行緒；CALayer 的 colorspace 更新透過 main dispatch。
    func applyColorMode(gamma: String, primaries: String) {
        guard let ctx = mpvCtx else { return }

        let newColorspace: CGColorSpace
        let trcLabel: String

        // 讀取顯示器實際 HDR 峰值（近似值）
        // macOS EDR 1.0 = SDR 參考白點 ≈ 203 nit
        let edrPotential = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let displayPeakNit = Int(203.0 * edrPotential)  // e.g. MBP XDR 7.88× ≈ 1600 nit

        switch gamma {
        case "pq":
            // PQ / Dolby Vision P8.4：
            // CAOpenGLLayer + itur_2100_PQ は PQ EOTF を正しく適用しない可能性
            // （float 0.75 が 75% EDR linear = 1500nit と解釈される）
            // → mpv で PQ→HLG 変換して出力し、動作確認済みの HLG pipeline を使う
            lib.set(ctx, "icc-profile-auto", "no")
            lib.set(ctx, "target-trc",       "hlg")
            lib.set(ctx, "target-prim",      "bt.2020")
            lib.set(ctx, "target-peak",      "1000")
            lib.set(ctx, "hdr-compute-peak", "no")
            lib.set(ctx, "tone-mapping",     "auto")
            newColorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
            trcLabel = "pq(DV) → HLG 変換  peak=1000nit"
        case "hlg":
            // HLG（Sony、Apple ProRes HLG 等）：走 HLG pipeline
            lib.set(ctx, "icc-profile-auto", "no")
            lib.set(ctx, "target-trc",       "hlg")
            lib.set(ctx, "target-prim",      "bt.2020")
            lib.set(ctx, "target-peak",      "1000")
            lib.set(ctx, "hdr-compute-peak", "no")
            lib.set(ctx, "tone-mapping",     "auto")
            newColorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
            trcLabel = "hlg → CALayer itur_2100_HLG  peak=1000nit"
        default:
            // SDR（srgb / bt.709 / unknown）
            lib.set(ctx, "icc-profile-auto", "yes")
            lib.set(ctx, "target-trc",       "auto")
            lib.set(ctx, "target-prim",      "auto")
            lib.set(ctx, "target-peak",      "auto")
            lib.set(ctx, "hdr-compute-peak", "auto")
            lib.set(ctx, "tone-mapping",     "auto")
            newColorspace = CGColorSpace(name: CGColorSpace.sRGB)!
            trcLabel = "\(gamma) → CALayer sRGB"
        }

        print("[mpv] applyColorMode: gamma=\(gamma) prim=\(primaries) → \(trcLabel)")
        hasPendingFrame = true
        DispatchQueue.main.async { [weak self] in
            self?.colorspace = newColorspace
            self?.setNeedsDisplay()
        }
    }

    // ─── 穩定化資料 ─────────────────────────────────────

    func loadGyroCore(_ server: GyroCore?) {
        gyroCore = server
        lastGyroFrameIdx = nil   // 重置單調保護
    }

    // ─── 載入檔案 ────────────────────────────────────────

    func loadFile(_ path: String) {
        guard let ctx = mpvCtx, let cmdFn = lib.command else { return }
        print("[mpv] Loading: \(path)")
        "loadfile".withCString { loadPtr in
            path.withCString { pathPtr in
                var args: [UnsafePointer<CChar>?] = [loadPtr, pathPtr, nil]
                _ = cmdFn(ctx, &args)
            }
        }
    }

    // ─── 暫停 / 繼續 ─────────────────────────────────────

    func setPause(_ paused: Bool) {
        guard let ctx = mpvCtx, let cmdFn = lib.command else { return }
        let val = paused ? "yes" : "no"
        "set".withCString { setPtr in
            "pause".withCString { pausePtr in
                val.withCString { valPtr in
                    var args: [UnsafePointer<CChar>?] = [setPtr, pausePtr, valPtr, nil]
                    _ = cmdFn(ctx, &args)
                }
            }
        }
    }

    func togglePause() {
        guard let ctx = mpvCtx, let cmdFn = lib.command else { return }
        "cycle".withCString { cyclePtr in
            "pause".withCString { pausePtr in
                var args: [UnsafePointer<CChar>?] = [cyclePtr, pausePtr, nil]
                _ = cmdFn(ctx, &args)
            }
        }
    }

    // ─── 跳轉 ───────────────────────────────────────────

    func seek(seconds: Int) {
        guard let ctx = mpvCtx, let cmdFn = lib.command else { return }
        let val = String(seconds)
        "seek".withCString { seekPtr in
            val.withCString { valPtr in
                var args: [UnsafePointer<CChar>?] = [seekPtr, valPtr, nil]
                _ = cmdFn(ctx, &args)
            }
        }
    }

    func seek(_ seconds: Double, absolute: Bool) {
        guard let ctx = mpvCtx, let cmdFn = lib.command else { return }
        let val = String(seconds)
        let flag = absolute ? "absolute" : "relative"
        "seek".withCString { seekPtr in
            val.withCString { valPtr in
                flag.withCString { flagPtr in
                    var args: [UnsafePointer<CChar>?] = [seekPtr, valPtr, flagPtr, nil]
                    _ = cmdFn(ctx, &args)
                }
            }
        }
    }

    // ─── 逐幀步進 ────────────────────────────────────────

    func frameStep() {
        guard let ctx = mpvCtx, let cmdFn = lib.command else { return }
        "frame-step".withCString { ptr in
            var args: [UnsafePointer<CChar>?] = [ptr, nil]
            _ = cmdFn(ctx, &args)
        }
    }

    func frameBackStep() {
        guard let ctx = mpvCtx, let cmdFn = lib.command else { return }
        "frame-back-step".withCString { ptr in
            var args: [UnsafePointer<CChar>?] = [ptr, nil]
            _ = cmdFn(ctx, &args)
        }
    }

    var currentTimeSec: Double {
        guard let ctx = mpvCtx else { return 0 }
        return Double(lib.getString(ctx, "time-pos") ?? "0") ?? 0
    }

    // ─── CAOpenGLLayer 覆寫 ──────────────────────────────

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
        // hasPendingFrame 只在 mpv 有新幀時為 true，避免暫停時以 120Hz 重繪靜態畫面
        renderCtx != nil && hasPendingFrame
    }

    override func draw(inCGLContext ctx: CGLContextObj,
                       pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval,
                       displayTime ts: UnsafePointer<CVTimeStamp>?) {
        hasPendingFrame = false   // 消費 pending flag，在 render 前清除
        guard let rc = renderCtx, let renderFn = lib.rcRender, let swapFn = lib.rcSwap else {
            print("[GL] draw() 提早返回：renderCtx=\(renderCtx != nil)")
            return
        }

        // CGLLockContext：確保多執行緒時 OpenGL context 使用安全
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }

        // IINA 方式：用 GL_VIEWPORT 取得實際 FBO 尺寸（比 layer.bounds 可靠）
        var dims = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)
        let w = dims[2] > 0 ? dims[2] : 1
        let h = dims[3] > 0 ? dims[3] : 1

        var displayFBO = GLint(0)
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &displayFBO)

        frameCount += 1
        if frameCount == 1 || frameCount % 60 == 0 {
            let fetchMs = gyroCore?.lastFetchMs ?? 0
            let fetchStr = gyroCore?.isReady == true
                ? String(format: "  gyroFetch=%.3fms", fetchMs)
                : ""
            print("[GL] draw() #\(frameCount): w=\(w) h=\(h) fbo=\(displayFBO) float=\(isFloat)\(fetchStr)")
        }

        // ── 同步計算當前幀矩陣（~0.5ms，直接在 render thread 呼叫）──────────
        // time-pos 由 audio clock 驅動，有微小抖動（±幾 ms），可能導致 frame index
        // 在 N 和 N+1 之間來回跳動 → 矩陣切換 → 畫面抖。
        // 修正：正常播放時 frame index 只進不退（單調遞增），消除抖動。
        // seek 時 fi 大幅變化（|delta| > 2），允許回退並重置 lastGyroFrameIdx。
        var currentMatrix: [Float]? = nil
        var gyroFrameIdx = 0
        if let core = gyroCore, core.isReady, let mpvCtx {
            let timeSec = Double(lib.getString(mpvCtx, "time-pos") ?? "0") ?? 0
            // time-pos 是音頻驅動的連續時鐘，draw() 執行時已比 callback（幀就緒）
            // 晚了一個 vsync 週期，導致 time-pos 超前。扣除 vsync 延遲以對齊正確的幀。
            let vsyncDelay = callbackTime > 0 ? CACurrentMediaTime() - callbackTime : 0
            let adjustedTime = max(0, timeSec - vsyncDelay)
            var fi = max(0, min(Int((adjustedTime * core.gyroFps).rounded()),
                                core.frameCount - 1))
            // 手動微調（, / . 鍵）
            let syncOffset = (NSApp.delegate as? AppDelegate)?.gyroFrameSync ?? 0
            fi = max(0, min(fi + syncOffset, core.frameCount - 1))
            // 單調遞增保護：小幅回退（|delta| <= 2）時鉗位到上一幀
            if let lastFi = lastGyroFrameIdx {
                let delta = fi - lastFi
                if delta < 0 && delta >= -2 {
                    fi = lastFi  // 抑制抖動
                }
                // delta < -2（seek）或 delta > 0（前進）都允許
            }
            lastGyroFrameIdx = fi
            currentMatrix = core.computeMatrix(frameIdx: fi)
            gyroFrameIdx  = fi
        }

        let hasStab = currentMatrix != nil && warpProg != 0

        // 穩定化時 mpv 渲染到影片原始解析度的 FBO，warp 在全解析度執行後才 downsample
        let vidW: GLsizei = hasStab ? GLsizei(gyroCore!.gyroVideoW) : w
        let vidH: GLsizei = hasStab ? GLsizei(gyroCore!.gyroVideoH) : h

        if hasStab && (stabW != vidW || stabH != vidH) {
            stabW = vidW; stabH = vidH
            glBindTexture(GLenum(GL_TEXTURE_2D), stabTex)
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA),
                         vidW, vidH, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), stabFBO)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                   GLenum(GL_TEXTURE_2D), stabTex, 0)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(displayFBO))
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            print("[Warp] stabFBO resized to \(vidW)×\(vidH) (video native resolution)")
        }

        let mpvTargetFBO = hasStab ? GLint(stabFBO) : displayFBO
        var fbo   = OGLFBO(fbo: mpvTargetFBO, w: vidW, h: vidH, internal_format: 0)
        var flipY = Int32(1)
        var depth = Int32(isFloat ? 16 : 8)

        withUnsafeMutablePointer(to: &fbo)   { fboPtr  in
        withUnsafeMutablePointer(to: &flipY) { flipPtr in
        withUnsafeMutablePointer(to: &depth) { depthPtr in
            var params: [RParam] = [
                RParam(RC_OGL_FBO, UnsafeMutableRawPointer(fboPtr)),
                RParam(RC_FLIP_Y,  UnsafeMutableRawPointer(flipPtr)),
                RParam(RC_DEPTH,   UnsafeMutableRawPointer(depthPtr)),
                RParam()
            ]
            let err = params.withUnsafeMutableBufferPointer { buf in
                renderFn(rc, UnsafeMutableRawPointer(buf.baseAddress!))
            }
            if err != 0 { print("[GL] mpv_render_context_render error: \(err)") }
        }}}

        // ── Pass 2：gyroflow per-row warp ──────────────────
        if hasStab, let server = gyroCore, let matrices = currentMatrix {
            let vH = Int(server.gyroVideoH)
            let vW = server.gyroVideoW

            // 若 matTex 尺寸改變，重新配置
            if matTexH != vH {
                matTexH = vH
                glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0,
                             0x8814,   // GL_RGBA32F (OpenGL 3.0)
                             4, GLsizei(vH), 0,
                             GLenum(GL_RGBA), GLenum(GL_FLOAT), nil)
                glBindTexture(GLenum(GL_TEXTURE_2D), 0)
                print("[Warp] matTex resized to 4×\(vH) RGBA32F")
            }

            // 矩陣就緒：上傳並執行 warp
            glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
            matrices.withUnsafeBytes { ptr in
                glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0,
                                0, 0, 4, GLsizei(vH),
                                GLenum(GL_RGBA), GLenum(GL_FLOAT),
                                ptr.baseAddress)
            }
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)

            // 切回 display FBO
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(displayFBO))
            glViewport(0, 0, w, h)
            glUseProgram(warpProg)

            // texture unit 0 = mpv 幀，texture unit 1 = 矩陣
            glActiveTexture(GLenum(GL_TEXTURE0))
            glBindTexture(GLenum(GL_TEXTURE_2D), stabTex)
            glUniform1i(uTex, 0)

            glActiveTexture(GLenum(GL_TEXTURE1))
            glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
            glUniform1i(uMatTex, 1)

            // 視訊尺寸
            glUniform2f(uVideoSize, vW, server.gyroVideoH)
            glUniform1f(uMatCount,  Float(vH))

            // gyrocore kernel params
            glUniform2f(uFIn, server.gyroFx, server.gyroFy)
            glUniform2f(uCIn, server.gyroCx, server.gyroCy)

            if frameCount <= 60 && frameCount % 10 == 0 {
                let ts = Double(lib.getString(mpvCtx!, "time-pos") ?? "?") ?? 0
                let vd = callbackTime > 0 ? CACurrentMediaTime() - callbackTime : 0
                print(String(format: "[GL] draw#%d → fi=%d  tp=%.4f  adj=%.4f  vsyncD=%.1fms",
                             frameCount, gyroFrameIdx, ts, ts - vd, vd * 1000))
            }

            // Draw fullscreen quad
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), warpVBO)
            glEnableVertexAttribArray(0)
            glVertexAttribPointer(0, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 8, nil)
            glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
            glDisableVertexAttribArray(0)
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), 0)

            glActiveTexture(GLenum(GL_TEXTURE1))
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            glActiveTexture(GLenum(GL_TEXTURE0))
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            glUseProgram(0)
        }

        // Frame timing measurement
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
                }
            }
        }
        lastFrameTime = now

        // ── Stability metric（連續幀像素差，越低越穩）──
        // 讀取畫面中央 64×36 縮圖，計算 MAE。全在 render thread 內，不需跨執行緒鎖。
        let tw = GLsizei(64), th = GLsizei(36)
        let tx = max(0, (w - tw) / 2), ty = max(0, (h - th) / 2)
        var thumb = [UInt8](repeating: 0, count: Int(tw * th * 4))
        thumb.withUnsafeMutableBytes { ptr in
            glReadPixels(tx, ty, tw, th, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), ptr.baseAddress)
        }
        if hasPrevThumb {
            var sum: Float = 0
            for i in 0 ..< thumb.count {
                sum += abs(Float(thumb[i]) - Float(prevThumb[i]))
            }
            stabilityScore = sum / Float(thumb.count)
        }
        prevThumb    = thumb
        hasPrevThumb = true
    }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
        if let rc  = renderCtx { lib.rcFree?(rc) }
        if let ctx = mpvCtx    { lib.destroy?(ctx) }
    }
}

// ════════════════════════════════════════════════════════
// MARK: - MPVView
// ════════════════════════════════════════════════════════

class MPVView: NSView {
    private let mpvLayer = MPVOpenGLLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // ★ IINA VideoView.swift:73 就有這行
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

    func load(path: String) { mpvLayer.loadFile(path) }
    func seek(_ seconds: Int) { mpvLayer.seek(seconds: seconds) }
    func seek(_ seconds: Double, absolute: Bool) { mpvLayer.seek(seconds, absolute: absolute) }
    func setPause(_ paused: Bool) { mpvLayer.setPause(paused) }
    func togglePause() { mpvLayer.togglePause() }
    func frameStep() { mpvLayer.frameStep() }
    func frameBackStep() { mpvLayer.frameBackStep() }
    var currentTimeSec: Double { mpvLayer.currentTimeSec }
    func loadGyroCore(_ server: GyroCore?) { mpvLayer.loadGyroCore(server) }
    func resetGyroFrameIdx() { mpvLayer.lastGyroFrameIdx = nil }

    var renderFPS: Double      { mpvLayer.renderFPS      }
    var renderCV: Double       { mpvLayer.renderCV       }
    var videoFPS: Double       { mpvLayer.videoFPS       }
    var droppedFrames: Int     { mpvLayer.droppedFrames  }
    var stabilityScore: Float  { mpvLayer.stabilityScore }
}

// ════════════════════════════════════════════════════════
// MARK: - StabilizationManager
// ════════════════════════════════════════════════════════

class StabilizationManager {
    private var process: Process?
    private(set) var isRendering = false

    static let gyroflowPath = "/Applications/Gyroflow.app/Contents/MacOS/gyroflow"

    /// 根據輸入路徑回傳預設的穩定化輸出路徑
    static func stabilizedPath(for inputPath: String) -> String {
        let url = URL(fileURLWithPath: inputPath)
        let base = url.deletingPathExtension().path
        let ext  = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        return "\(base)_stabilized.\(ext)"
    }

    func startRender(
        inputPath: String,
        onProgress: @escaping (_ fraction: Double, _ current: Int, _ total: Int, _ etaStr: String) -> Void,
        onDone:     @escaping (_ path: String) -> Void,
        onError:    @escaping (_ msg: String) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: Self.gyroflowPath) else {
            onError("gyroflow not found at \(Self.gyroflowPath)")
            return
        }
        let outPath = Self.stabilizedPath(for: inputPath)
        isRendering = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.gyroflowPath)
        proc.arguments = [
            inputPath,
            "-t", "_stabilized",
            "-f",
            "--stdout-progress",
            "-r", "apple m",
            "-p", "{ 'codec': 'H.265/HEVC', 'bitrate': 150, 'use_gpu': true, 'audio': true }"
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe  // gyroflow 把 progress 混在 stderr

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for rawLine in text.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                // Log 全部輸出，方便分析 gyroflow 的 crop/zoom 資訊格式
                print("[gyroflow] \(line)")
                guard line.contains("Rendering progress:") else { continue }
                // 格式: "[id] Rendering progress: X/Y frames (P%) ETA Zs"
                var pct: Double = 0
                var curFrame = 0, totFrame = 0
                var etaStr = ""

                // 解析 "X/Y frames"
                if let progRange = line.range(of: "Rendering progress: "),
                   let parenIdx  = line.range(of: " (") {
                    let between = String(line[progRange.upperBound..<parenIdx.lowerBound])
                    let parts = between.split(separator: "/")
                    if parts.count == 2 {
                        curFrame = Int(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0
                        totFrame = Int(parts[1].split(separator: " ").first ?? "") ?? 0
                    }
                }

                // 解析百分比
                if let open = line.firstIndex(of: "("),
                   let pctEnd = line[open...].firstIndex(of: "%") {
                    let pctStr = String(line[line.index(after: open)..<pctEnd])
                    pct = (Double(pctStr) ?? 0) / 100.0
                }

                // 解析 ETA
                if let etaRange = line.range(of: "ETA ") {
                    let after = line[etaRange.upperBound...]
                    if let sIdx = after.firstIndex(of: "s") {
                        let raw = Double(String(after[..<sIdx])) ?? 0
                        etaStr = raw < 60 ? "\(Int(raw))s" : "\(Int(raw/60))m\(Int(raw)%60)s"
                    }
                }

                DispatchQueue.main.async { onProgress(pct, curFrame, totFrame, etaStr) }
            }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.isRendering = false
                if p.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: outPath) {
                    onDone(outPath)
                } else {
                    onError("gyroflow exited with status \(p.terminationStatus)")
                }
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            isRendering = false
            onError("Failed to launch gyroflow: \(error)")
        }
    }

    func cancel() {
        guard let proc = process else { return }
        let pid = proc.processIdentifier
        proc.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        proc.terminate()
        if pid > 0 { kill(pid, SIGKILL) }   // 確保即使 gyroflow 忽略 SIGTERM 也會結束
        process = nil
        isRendering = false
    }
}

// ════════════════════════════════════════════════════════
// MARK: - AppDelegate
// ════════════════════════════════════════════════════════

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var mpvView: MPVView!
    var statsLabel: NSTextField!
    var statsTimer: Timer?

    // ── Stabilization state ──────────────────────────────
    var originalPath: String?        // 目前播放的原始檔路徑
    var stabilizedPath: String?      // Phase 1：穩定化 MP4 路徑
    var isShowingStabilized = false  // Phase 1：目前顯示穩定化版本？
    var gyroCore: GyroCore?      // Phase 2：即時 gyrocore 穩定化（nil = 關閉）
    var gyroOffsetMs: Double = 0.0  // Gyro-video sync offset (ms)
    var gyroSmoothness: Double = 0.5  // 平滑度 (0.01–3.0)
    var gyroRSEnabled: Bool = true    // Rolling shutter 修正
    var gyroFrameSync: Int = 0       // Frame sync offset (+/- frames, 即時微調用)
    var stabManager = StabilizationManager()
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard lib.load() else {
            let a = NSAlert()
            a.messageText = "libmpv not found"
            a.informativeText = "Install IINA from https://iina.io"
            a.runModal()
            NSApplication.shared.terminate(nil)
            return
        }

        window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "testmpv — HLG Video / Image Test"
        window.backgroundColor = .black
        window.minSize = NSSize(width: 320, height: 180)

        mpvView = MPVView(frame: window.contentView!.bounds)
        mpvView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(mpvView)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // ── Stats overlay (top-right) ──────────────────────────────
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        container.layer?.cornerRadius = 5
        container.translatesAutoresizingMaskIntoConstraints = false

        statsLabel = NSTextField(labelWithString: "–")
        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        statsLabel.isBezeled = false
        statsLabel.drawsBackground = false
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.alignment = .right

        container.addSubview(statsLabel)
        window.contentView!.addSubview(container)

        NSLayoutConstraint.activate([
            statsLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            statsLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            statsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            container.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 8),
            container.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -8),
        ])

        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fps     = self.mpvView.renderFPS
            let cv      = self.mpvView.renderCV
            let vfps    = self.mpvView.videoFPS
            let dropped = self.mpvView.droppedFrames

            let dotColor: NSColor = cv < 0.05 ? .systemGreen : cv < 0.15 ? .systemYellow : .systemRed
            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            ]
            let dotAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: fps > 0 ? dotColor : NSColor.gray,
            ]

            let score   = self.mpvView.stabilityScore

            var tail = " \(String(format: "%.1f", fps))"
            if vfps > 0 { tail += "/\(String(format: "%.0f", vfps))" }
            tail += " fps  CV \(String(format: "%.3f", cv))"
            if dropped > 0 { tail += "  ↓\(dropped)" }
            if score >= 0  { tail += "  Δ\(String(format: "%.1f", score))" }

            let str = NSMutableAttributedString(string: "●", attributes: dotAttrs)
            str.append(NSAttributedString(string: tail, attributes: baseAttrs))
            self.statsLabel.attributedStringValue = str
        }
        // ──────────────────────────────────────────────────────────

        // ── 鍵盤快捷鍵 ────────────────────────────────────────
        // S (1)      : Phase 1：切換原始↔穩定化（若無則觸發 gyroflow 渲染）
        // R (15)     : gyro 穩定化 on/off
        // T (17)     : 切換 Rolling Shutter 修正
        // [ (33)     : 降低平滑度 (-0.1)
        // ] (30)     : 提高平滑度 (+0.1)
        // ↑ (126)   : offset +5ms（Shift: +1ms）
        // ↓ (125)   : offset -5ms（Shift: -1ms）
        // ← (123)   : 倒退 5 秒
        // → (124)   : 快進 5 秒
        // Space (49) : 暫停/繼續
        // Q (12)     : 離開
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 1:   self.handleStabilizeKey(); return nil  // S：Phase 1 切換
            case 15:                                         // R：切換 gyro 穩定化 on/off
                if self.gyroCore != nil {
                    self.gyroCore?.stop()
                    self.gyroCore = nil
                    self.mpvView.loadGyroCore(nil)
                    self.updateTitle()
                } else if let path = self.originalPath {
                    self.startGyroGeneration(for: path)
                }
                return nil
            case 49:  self.mpvView.togglePause(); return nil // Space
            case 123: self.mpvView.seek(-5);      return nil // ←
            case 124: self.mpvView.seek(5);       return nil // →
            case 126:                                         // ↑：offset 調整
                let step = event.modifierFlags.contains(.shift) ? 1.0 : 5.0
                self.gyroOffsetMs += step
                print("[gyro] offset = \(self.gyroOffsetMs)ms  (step=\(step))")
                if let path = self.originalPath { self.restartGyro(for: path) }
                return nil
            case 125:                                         // ↓：offset 調整
                let step = event.modifierFlags.contains(.shift) ? 1.0 : 5.0
                self.gyroOffsetMs -= step
                print("[gyro] offset = \(self.gyroOffsetMs)ms  (step=\(step))")
                if let path = self.originalPath { self.restartGyro(for: path) }
                return nil
            case 17:                                         // T：切換 Rolling Shutter 修正
                self.gyroRSEnabled.toggle()
                print("[gyro] RS correction: \(self.gyroRSEnabled ? "ON" : "OFF")")
                if let path = self.originalPath, self.gyroCore != nil {
                    self.restartGyro(for: path)
                }
                return nil
            case 33:                                         // [：降低平滑度
                self.gyroSmoothness = max(0.01, self.gyroSmoothness - 0.1)
                print(String(format: "[gyro] smoothness = %.2f", self.gyroSmoothness))
                if let path = self.originalPath, self.gyroCore != nil {
                    self.restartGyro(for: path)
                }
                return nil
            case 30:                                         // ]：提高平滑度
                self.gyroSmoothness = min(3.0, self.gyroSmoothness + 0.1)
                print(String(format: "[gyro] smoothness = %.2f", self.gyroSmoothness))
                if let path = self.originalPath, self.gyroCore != nil {
                    self.restartGyro(for: path)
                }
                return nil
            case 43:                                         // ,：frame sync -1
                self.gyroFrameSync -= 1
                print("[gyro] frameSync = \(self.gyroFrameSync)")
                self.mpvView.resetGyroFrameIdx()  // 重置單調保護
                self.updateTitle()
                return nil
            case 47:                                         // .：frame sync +1
                self.gyroFrameSync += 1
                print("[gyro] frameSync = \(self.gyroFrameSync)")
                self.mpvView.resetGyroFrameIdx()
                self.updateTitle()
                return nil
            case 12:  NSApplication.shared.terminate(nil); return nil // Q
            default:  return event
            }
        }

        if CommandLine.arguments.count > 1 {
            let path = CommandLine.arguments[1]
            originalPath = path
            mpvView.load(path: path)
            startGyroGeneration(for: path)
            updateTitle()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openFile() }
        }
    }

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Video / Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            stabManager.cancel()
            originalPath = url.path
            stabilizedPath = nil
            isShowingStabilized = false
            gyroCore?.stop(); gyroCore = nil
            mpvView.loadGyroCore(nil)
            mpvView.load(path: url.path)
            startGyroGeneration(for: url.path)
            updateTitle()
        }
    }

    // ── gyro 即時穩定化 ──────────────────────────────────────────

    /// .gyroflow ファイル探索（レンズキャリブレーション用）
    private func findGyroflowFile(for videoPath: String) -> String? {
        let url = URL(fileURLWithPath: videoPath)
        let candidates = [
            url.deletingPathExtension().path + ".gyroflow",          // C0206.gyroflow
            url.deletingLastPathComponent().appendingPathComponent("default.gyroflow").path,
            NSHomeDirectory() + "/my_photo/default.gyroflow",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func startGyroGeneration(for videoPath: String) {
        let fps: Double
        if let track = AVURLAsset(url: URL(fileURLWithPath: videoPath))
                       .tracks(withMediaType: .video).first {
            fps = Double(track.nominalFrameRate)
        } else { fps = 30.0 }
        let readout  = GyroCore.readoutMs(for: fps)
        let lensPath = findGyroflowFile(for: videoPath)

        // 暫停 mpv，避免 gyrocore 初始化期間顯示未穩定化畫面
        mpvView.setPause(true)

        let server = GyroCore()
        gyroCore = server
        updateTitle()

        let effReadout = gyroRSEnabled ? readout : 0.0
        server.start(
            videoPath: videoPath, lensPath: lensPath, readoutMs: effReadout,
            smoothness: gyroSmoothness, gyroOffsetMs: gyroOffsetMs,
            onReady: { [weak self] in
                guard let self, self.gyroCore === server else { return }
                self.mpvView.loadGyroCore(server)
                // Seek 回開頭確保第一幀就是穩定化的，然後恢復播放
                self.mpvView.seek(0, absolute: true)
                self.mpvView.setPause(false)
                print("[gyro] ✅ 穩定化啟動")
                self.updateTitle()
            },
            onError: { [weak self] msg in
                print("[gyro] ❌ \(msg)")
                if self?.gyroCore === server { self?.gyroCore = nil }
                // 載入失敗也要恢復播放
                self?.mpvView.setPause(false)
                self?.updateTitle()
            }
        )
    }

    /// 重新啟動 gyro（offset 變更時使用）
    private func restartGyro(for videoPath: String) {
        gyroCore?.stop()
        gyroCore = nil
        mpvView.loadGyroCore(nil)
        startGyroGeneration(for: videoPath)
    }

    // ── 按 S 時的邏輯（Phase 1：切換原始↔gyroflow 穩定化 MP4）──
    private func handleStabilizeKey() {
        guard let origPath = originalPath else {
            print("[phase1] 尚未開啟影片"); return
        }

        // 渲染中：忽略
        if stabManager.isRendering {
            print("[phase1] gyroflow 渲染中，請稍候…"); return
        }

        // 目前播放穩定化版本 → 切回原始
        if isShowingStabilized {
            isShowingStabilized = false
            mpvView.load(path: origPath)
            updateTitle()
            print("[phase1] 切回原始影片")
            return
        }

        // 有現成的穩定化檔案 → 直接播放
        let stabPath = StabilizationManager.stabilizedPath(for: origPath)
        if FileManager.default.fileExists(atPath: stabPath) {
            stabilizedPath = stabPath
            isShowingStabilized = true
            mpvView.load(path: stabPath)
            updateTitle()
            print("[phase1] 播放穩定化影片: \(stabPath)")
            return
        }

        // 無現成檔案 → 呼叫 gyroflow 渲染
        updateTitle(status: "gyroflow 渲染中…")
        print("[phase1] 啟動 gyroflow 渲染，輸出: \(stabPath)")
        stabManager.startRender(
            inputPath: origPath,
            onProgress: { [weak self] fraction, cur, total, eta in
                let pct = Int(fraction * 100)
                self?.updateTitle(status: "渲染 \(pct)% (\(cur)/\(total)) ETA \(eta)")
            },
            onDone: { [weak self] path in
                guard let self else { return }
                self.stabilizedPath = path
                self.isShowingStabilized = true
                self.mpvView.load(path: path)
                self.updateTitle()
                print("[phase1] ✅ 渲染完成，播放穩定化影片: \(path)")
            },
            onError: { [weak self] msg in
                self?.updateTitle()
                print("[phase1] ❌ 渲染失敗: \(msg)")
            }
        )
    }

    // ── 視窗標題更新 ──────────────────────────────────────
    private func updateTitle(status: String? = nil) {
        let name = originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "testmpv"
        if let s = status {
            window.title = "testmpv — \(s)"
        } else if stabManager.isRendering {
            window.title = "\(name)  [渲染中…]"
        } else if let srv = gyroCore {
            let syncStr = gyroFrameSync != 0 ? "  sync=\(gyroFrameSync > 0 ? "+" : "")\(gyroFrameSync)f" : ""
            let params = String(format: "smooth=%.2f  RS=%@  offset=%dms",
                                gyroSmoothness, gyroRSEnabled ? "ON" : "OFF", Int(gyroOffsetMs)) + syncStr
            window.title = srv.isReady
                ? "\(name)  [gyrocore  \(params)]"
                : "\(name)  [gyrocore 初始化中…]"
        } else if isShowingStabilized {
            window.title = "\(name)  [Phase 1]  (S=切回原始  R=載入 gyro)"
        } else {
            let hasStab = originalPath.map { FileManager.default.fileExists(
                atPath: StabilizationManager.stabilizedPath(for: $0)) } ?? false
            window.title = hasStab
                ? "\(name)  (S=Phase1  R=gyro穩定)"
                : "\(name)  (S=gyroflow渲染  R=gyro穩定)"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        gyroCore?.stop()
        stabManager.cancel()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// ════════════════════════════════════════════════════════
// MARK: - Entry Point
// ════════════════════════════════════════════════════════

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Quit testmpv",
                            action: #selector(NSApplication.terminate(_:)),
                            keyEquivalent: "q"))
appItem.submenu = appMenu
let fileItem = NSMenuItem()
mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(NSMenuItem(title: "Open…",
                             action: #selector(AppDelegate.openFile),
                             keyEquivalent: "o"))
fileItem.submenu = fileMenu
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
