// testmpv — Sony HLG 亮度 + 靜態圖片測試 App (MDK backend)
//
// Build: bash build.sh
// Run:   ./testmpv /path/to/sony-hlg.mp4
//        ./testmpv /path/to/photo.HIF

import Cocoa
import OpenGL.GL3
import CoreVideo
import Darwin
import AVFoundation

// 關閉 stdout buffering，確保 print() 在 process 被 kill 前就寫出
setbuf(stdout, nil)

// ── Display peak nits（IINA 方式：讀 CoreDisplay private API）──────────
func displayPeakNits() -> Int {
    typealias FnCreateInfo = @convention(c) (UInt32) -> CFDictionary?
    guard let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
          let sym = dlsym(cd, "CoreDisplay_DisplayCreateInfoDictionary") else { return 400 }
    let fn = unsafeBitCast(sym, to: FnCreateInfo.self)
    let displayId = CGMainDisplayID()
    guard let dict = fn(displayId) as? [String: Any] else { return 400 }
    if let v = dict["NonReferencePeakHDRLuminance"] as? Int { return v }  // Apple Silicon
    if let v = dict["DisplayBacklight"] as? Int { return v }              // Intel
    return 400
}

// ════════════════════════════════════════════════════════
// MARK: - Stabilization Data
// ════════════════════════════════════════════════════════

struct GyroConfig: Codable {
    var readoutMs:            Double = 0
    var smooth:               Double = 0
    var gyroOffsetMs:         Double = 0
    var integrationMethod:    Int?   = nil    // nil=auto
    var imuOrientation:       String? = nil   // nil=auto
    var fov:                  Double = 1.0
    var lensCorrectionAmount: Double = 1.0
    var zoomingMethod:        Int    = 1      // 0=None 1=Dynamic 2=Static
    var zoomingAlgorithm:     Int    = 1      // 0=GaussianFilter 1=EnvelopeFollower
    var adaptiveZoom:         Double = 4.0
    var maxZoom:              Double = 130.0
    var maxZoomIterations:    Int    = 5
    var useGravityVectors:    Bool   = false
    var videoSpeed:           Double = 1.0
    var horizonLockEnabled:   Bool   = false
    var horizonLockAmount:    Double = 1.0
    var horizonLockRoll:      Double = 0
    var perAxis:              Bool   = false
    var smoothnessPitch:      Double = 0
    var smoothnessYaw:        Double = 0
    var smoothnessRoll:       Double = 0
    var lensDbDir:            String? = nil

    enum CodingKeys: String, CodingKey {
        case readoutMs            = "readout_ms"
        case smooth
        case gyroOffsetMs         = "gyro_offset_ms"
        case integrationMethod    = "integration_method"
        case imuOrientation       = "imu_orientation"
        case fov
        case lensCorrectionAmount = "lens_correction_amount"
        case zoomingMethod        = "zooming_method"
        case zoomingAlgorithm     = "zooming_algorithm"
        case adaptiveZoom         = "adaptive_zoom"
        case maxZoom              = "max_zoom"
        case maxZoomIterations    = "max_zoom_iterations"
        case useGravityVectors    = "use_gravity_vectors"
        case videoSpeed           = "video_speed"
        case horizonLockEnabled   = "horizon_lock_enabled"
        case horizonLockAmount    = "horizon_lock_amount"
        case horizonLockRoll      = "horizon_lock_roll"
        case perAxis              = "per_axis"
        case smoothnessPitch      = "smoothness_pitch"
        case smoothnessYaw        = "smoothness_yaw"
        case smoothnessRoll       = "smoothness_roll"
        case lensDbDir            = "lens_db_dir"
    }
}

// GyroCore: in-process gyroflow-core 矩陣計算
// 用 dlopen 載入 libgyrocore_c.dylib，無 subprocess
class GyroCore {
    // ── C function pointer types (matches Spectrum/Services/GyroCore.swift) ──
    private typealias FnLoad      = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias FnGetParams = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias FnGetFrame  = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnGetFrameTs = @convention(c) (UnsafeMutableRawPointer, Double, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnFree      = @convention(c) (UnsafeMutableRawPointer) -> Void

    // ── Public metadata ─────────────────────────────────────────────────────
    private(set) var frameCount:  Int    = 0
    private(set) var rowCount:    Int    = 1
    private(set) var gyroFx:      Float  = 0
    private(set) var gyroFy:      Float  = 0
    private(set) var gyroCx:      Float  = 0
    private(set) var gyroCy:      Float  = 0
    private(set) var gyroVideoW:  Float  = 0
    private(set) var gyroVideoH:  Float  = 0
    private(set) var gyroFps:     Double = 30
    // Distortion parameters (from gyroflow-core KernelParams)
    private(set) var distortionK: [Float] = [Float](repeating: 0, count: 12)
    private(set) var distortionModel: Int32 = 0   // 0=None 1=OpenCVFisheye 3=Poly3 4=Poly5 7=Sony
    private(set) var rLimit:      Float  = 0
    // Per-frame lens params (updated each computeMatrix call)
    private(set) var frameFx: Float = 0
    private(set) var frameFy: Float = 0
    private(set) var frameCx: Float = 0
    private(set) var frameCy: Float = 0
    private(set) var frameK: [Float] = [0, 0, 0, 0]
    private(set) var frameFov: Float = 1.0
    private(set) var fovMin: Float = 1.0
    private(set) var fovMax: Float = 1.0
    private(set) var lensCorrectionAmount: Float = 1.0

    private var _isReady  = false
    private let readyLock = NSLock()
    var isReady: Bool {
        readyLock.lock(); defer { readyLock.unlock() }; return _isReady
    }

    private let coreLock   = NSLock()

    private let ioQueue    = DispatchQueue(label: "gyrocore.init", qos: .userInteractive)
    private var libHandle:  UnsafeMutableRawPointer?
    private var coreHandle: UnsafeMutableRawPointer?
    private var fnLoad:      FnLoad?
    private var fnGetParams: FnGetParams?
    private var fnGetFrame:  FnGetFrame?
    private var fnGetFrameTs: FnGetFrameTs?
    private var fnFree:      FnFree?

    /// 最近一次 computeMatrix 的耗時（ms）
    private(set) var lastFetchMs: Double = 0

    // Pre-allocated buffers
    private var rawBuf:  [Float] = []
    private var matsBuf: [Float] = []
    private var cachedFrameIdx: Int = -1
    private var fovHistory: [Float] = []

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

    func start(videoPath: String, lensPath: String? = nil,
               config: GyroConfig = GyroConfig(),
               onReady: @escaping () -> Void,
               onError: @escaping (String) -> Void) {
        let path = Self.dylibPath
        guard let lib = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            onError("dlopen failed: \(String(cString: dlerror()))"); return
        }
        libHandle = lib

        guard let s1 = dlsym(lib, "gyrocore_load"),
              let s2 = dlsym(lib, "gyrocore_get_params"),
              let s3 = dlsym(lib, "gyrocore_get_frame"),
              let s4 = dlsym(lib, "gyrocore_free") else {
            onError("dlsym failed: gyrocore symbols not found"); return
        }
        fnLoad      = unsafeBitCast(s1, to: FnLoad.self)
        fnGetParams = unsafeBitCast(s2, to: FnGetParams.self)
        fnGetFrame  = unsafeBitCast(s3, to: FnGetFrame.self)
        fnFree      = unsafeBitCast(s4, to: FnFree.self)
        // Optional: timestamp-based frame query
        if let s5 = dlsym(lib, "gyrocore_get_frame_at_ts") {
            fnGetFrameTs = unsafeBitCast(s5, to: FnGetFrameTs.self)
        }

        ioQueue.async { [weak self] in
            self?.loadCore(videoPath: videoPath, lensPath: lensPath, config: config,
                           onReady: onReady, onError: onError)
        }
    }

    private func loadCore(videoPath: String, lensPath: String?, config: GyroConfig,
                          onReady: @escaping () -> Void,
                          onError: @escaping (String) -> Void) {
        guard let fn = fnLoad else { onError("No load fn"); return }

        let configJSON: String
        do {
            configJSON = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? "{}"
        } catch {
            configJSON = "{}"
        }

        let lensDesc = lensPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
        print("[gyro] Loading \(URL(fileURLWithPath: videoPath).lastPathComponent)  lens=\(lensDesc)  config=\(configJSON)")
        let handle: UnsafeMutableRawPointer?
        if let lp = lensPath {
            handle = videoPath.withCString { vp in lp.withCString { lpp in configJSON.withCString { cj in fn(vp, lpp, cj) } } }
        } else {
            handle = videoPath.withCString { vp in configJSON.withCString { cj in fn(vp, nil, cj) } }
        }
        guard let handle else { onError("gyrocore_load failed"); return }
        coreHandle = handle

        // Read 96-byte params blob (matches Spectrum)
        var buf = Data(count: 96)
        let rc = buf.withUnsafeMutableBytes { ptr in
            fnGetParams?(handle, ptr.baseAddress!) ?? -1
        }
        guard rc == 0 else { onError("gyrocore_get_params failed"); return }

        frameCount = Int(buf.withUnsafeBytes { $0.load(fromByteOffset:  0, as: UInt32.self) })
        rowCount   = Int(buf.withUnsafeBytes { $0.load(fromByteOffset:  4, as: UInt32.self) })
        gyroVideoW = Float(buf.withUnsafeBytes { $0.load(fromByteOffset:  8, as: UInt32.self) })
        gyroVideoH = Float(buf.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
        gyroFps    = buf.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Float64.self) }
        gyroFx     = buf.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Float32.self) }
        gyroFy     = buf.withUnsafeBytes { $0.load(fromByteOffset: 28, as: Float32.self) }
        gyroCx     = buf.withUnsafeBytes { $0.load(fromByteOffset: 32, as: Float32.self) }
        gyroCy     = buf.withUnsafeBytes { $0.load(fromByteOffset: 36, as: Float32.self) }
        // Distortion parameters (bytes 40..96)
        buf.withUnsafeBytes { ptr in
            for i in 0..<12 {
                distortionK[i] = ptr.load(fromByteOffset: 40 + i * 4, as: Float32.self)
            }
        }
        distortionModel = buf.withUnsafeBytes { $0.load(fromByteOffset: 88, as: Int32.self) }
        rLimit          = buf.withUnsafeBytes { $0.load(fromByteOffset: 92, as: Float32.self) }
        lensCorrectionAmount = Float(config.lensCorrectionAmount)
        print("[gyro] distortion_model=\(distortionModel) k=[\(distortionK[0]),\(distortionK[1]),\(distortionK[2]),\(distortionK[3])] r_limit=\(rLimit)")

        // Pre-allocate per-frame buffers
        rawBuf  = [Float](repeating: 0, count: rowCount * 14 + 9)
        matsBuf = [Float](repeating: 0, count: Int(gyroVideoH) * 16)
        cachedFrameIdx = -1

        readyLock.lock(); _isReady = true; readyLock.unlock()
        print(String(format: "[gyro] Ready: %d frames x %d rows  f=[%.1f,%.1f]  c=[%.1f,%.1f]  %dx%d@%.3ffps",
                     frameCount, rowCount, gyroFx, gyroFy, gyroCx, gyroCy,
                     Int(gyroVideoW), Int(gyroVideoH), gyroFps))
        DispatchQueue.main.async { onReady() }
    }

    // MARK: - Per-frame matrix at timestamp (matches Spectrum)

    /// Compute matrices using continuous timestamp (no frame-index quantization).
    /// Returns (UnsafeBufferPointer<Float>, changed) or nil.
    func computeMatrixAtTime(timeSec: Double) -> (UnsafeBufferPointer<Float>, Bool)? {
        guard isReady else { return nil }
        coreLock.lock(); defer { coreLock.unlock() }
        guard let handle = coreHandle else { return nil }

        let fi = max(0, min(Int((timeSec * gyroFps).rounded()), frameCount - 1))

        if fi == cachedFrameIdx {
            lastFetchMs = 0
            return matsBuf.withUnsafeBufferPointer { ($0, false) }
        }

        let expectedLen = rowCount * 14 + 9
        let t0 = CACurrentMediaTime()
        let result: Int32
        if let fnTs = fnGetFrameTs {
            result = rawBuf.withUnsafeMutableBufferPointer {
                fnTs(handle, timeSec, $0.baseAddress!)
            }
        } else if let fn = fnGetFrame {
            result = rawBuf.withUnsafeMutableBufferPointer {
                fn(handle, UInt32(fi), $0.baseAddress!)
            }
        } else {
            return nil
        }
        lastFetchMs = (CACurrentMediaTime() - t0) * 1000
        guard result == Int32(expectedLen) else { return nil }

        // Extract per-frame lens params
        let pfBase = rowCount * 14
        frameFx = rawBuf[pfBase]
        frameFy = rawBuf[pfBase + 1]
        frameCx = rawBuf[pfBase + 2]
        frameCy = rawBuf[pfBase + 3]
        frameK[0] = rawBuf[pfBase + 4]
        frameK[1] = rawBuf[pfBase + 5]
        frameK[2] = rawBuf[pfBase + 6]
        frameK[3] = rawBuf[pfBase + 7]
        frameFov = rawBuf[pfBase + 8]

        fovHistory.append(frameFov)
        if fovHistory.count > 120 { fovHistory.removeFirst() }
        fovMin = fovHistory.min() ?? frameFov
        fovMax = fovHistory.max() ?? frameFov

        // Expand rowCount x 14 -> vH x 16 floats
        let vH = Int(gyroVideoH)
        rawBuf.withUnsafeBufferPointer { raw in
        matsBuf.withUnsafeMutableBufferPointer { mats in
            let rp = raw.baseAddress!
            let mp = mats.baseAddress!
            let rc = rowCount
            for y in 0..<vH {
                let r = rc == 1 ? 0 : min(y &* rc / max(vH, 1), rc &- 1)
                let sp = rp + r &* 14
                let dp = mp + y &* 16
                dp[0]  = sp[0]; dp[1]  = sp[1]; dp[2]  = sp[2]; dp[3]  = sp[9]
                dp[4]  = sp[3]; dp[5]  = sp[4]; dp[6]  = sp[5]; dp[7]  = sp[10]
                dp[8]  = sp[6]; dp[9]  = sp[7]; dp[10] = sp[8]; dp[11] = sp[11]
                dp[12] = sp[12]; dp[13] = sp[13]; dp[14] = 0; dp[15] = 0
            }
        }}
        cachedFrameIdx = fi
        return matsBuf.withUnsafeBufferPointer { ($0, true) }
    }

    func stop() {
        readyLock.lock(); _isReady = false; readyLock.unlock()
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
// MARK: - GyroCoreProvider Protocol
// ════════════════════════════════════════════════════════

protocol GyroCoreProvider: AnyObject {
    var isReady: Bool { get }
    var gyroVideoW: Float { get }
    var gyroVideoH: Float { get }
    var gyroFps: Double { get }
    var frameCount: Int { get }
    func computeMatrixAtTime(timeSec: Double) -> (UnsafeBufferPointer<Float>, Bool)?
    var frameFx: Float { get }
    var frameFy: Float { get }
    var frameCx: Float { get }
    var frameCy: Float { get }
    var frameK: [Float] { get }
    var distortionK: [Float] { get }
    var distortionModel: Int32 { get }
    var rLimit: Float { get }
    var frameFov: Float { get }
    var lensCorrectionAmount: Float { get }
    var lastFetchMs: Double { get }
    func stop()
}

extension GyroCore: GyroCoreProvider {}

// ════════════════════════════════════════════════════════
// MARK: - GyroFlowCore (incremental gyroflow API)
// ════════════════════════════════════════════════════════

class GyroFlowCore: GyroCoreProvider {
    private typealias FnCreate     = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias FnLoadVideo  = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Int32
    private typealias FnLoadLens   = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Int32
    private typealias FnSetParam   = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, Double) -> Int32
    private typealias FnSetParamS  = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    private typealias FnRecompute  = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias FnGetFrame   = @convention(c) (UnsafeMutableRawPointer, Double, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnGetParams  = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias FnFree       = @convention(c) (UnsafeMutableRawPointer) -> Void

    private(set) var frameCount:  Int    = 0
    private(set) var rowCount:    Int    = 1
    private(set) var gyroFx:      Float  = 0
    private(set) var gyroFy:      Float  = 0
    private(set) var gyroCx:      Float  = 0
    private(set) var gyroCy:      Float  = 0
    private(set) var gyroVideoW:  Float  = 0
    private(set) var gyroVideoH:  Float  = 0
    private(set) var gyroFps:     Double = 30
    private(set) var distortionK: [Float] = [Float](repeating: 0, count: 12)
    private(set) var distortionModel: Int32 = 0
    private(set) var rLimit:      Float  = 0
    private(set) var frameFx: Float = 0
    private(set) var frameFy: Float = 0
    private(set) var frameCx: Float = 0
    private(set) var frameCy: Float = 0
    private(set) var frameK: [Float] = [0, 0, 0, 0]
    private(set) var frameFov: Float = 1.0
    private(set) var lensCorrectionAmount: Float = 1.0
    private(set) var lastFetchMs: Double = 0

    private var _isReady = false
    private let readyLock = NSLock()
    var isReady: Bool { readyLock.lock(); defer { readyLock.unlock() }; return _isReady }

    private let coreLock = NSLock()
    private let ioQueue = DispatchQueue(label: "gyroflow.io", qos: .userInitiated)
    private var libHandle: UnsafeMutableRawPointer?
    private var coreHandle: UnsafeMutableRawPointer?
    private var fnCreate:     FnCreate?
    private var fnLoadVideo:  FnLoadVideo?
    private var fnLoadLens:   FnLoadLens?
    private var fnSetParam:   FnSetParam?
    private var fnSetParamS:  FnSetParamS?
    private var fnRecompute:  FnRecompute?
    private var fnGetFrame:   FnGetFrame?
    private var fnGetParams:  FnGetParams?
    private var fnFree:       FnFree?
    private var matBuf: [Float] = []
    private var matsBuf: [Float] = []
    private var cachedFrameIdx: Int = -1

    func start(videoPath: String, lensPath: String? = nil,
               config: GyroConfig = GyroConfig(),
               onReady: @escaping () -> Void,
               onError: @escaping (String) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let path = GyroCore.dylibPath
            self.libHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            guard let lib = self.libHandle else {
                DispatchQueue.main.async { onError("dlopen failed: \(String(cString: dlerror()))") }
                return
            }
            self.fnCreate    = dlsym(lib, "gyroflow_create").map    { unsafeBitCast($0, to: FnCreate.self) }
            self.fnLoadVideo = dlsym(lib, "gyroflow_load_video").map { unsafeBitCast($0, to: FnLoadVideo.self) }
            self.fnLoadLens  = dlsym(lib, "gyroflow_load_lens").map  { unsafeBitCast($0, to: FnLoadLens.self) }
            self.fnSetParam  = dlsym(lib, "gyroflow_set_param").map  { unsafeBitCast($0, to: FnSetParam.self) }
            self.fnSetParamS = dlsym(lib, "gyroflow_set_param_str").map { unsafeBitCast($0, to: FnSetParamS.self) }
            self.fnRecompute = dlsym(lib, "gyroflow_recompute").map  { unsafeBitCast($0, to: FnRecompute.self) }
            self.fnGetFrame  = dlsym(lib, "gyroflow_get_frame").map  { unsafeBitCast($0, to: FnGetFrame.self) }
            self.fnGetParams = dlsym(lib, "gyroflow_get_params").map { unsafeBitCast($0, to: FnGetParams.self) }
            self.fnFree      = dlsym(lib, "gyroflow_free").map       { unsafeBitCast($0, to: FnFree.self) }

            guard let fnCreate = self.fnCreate else {
                DispatchQueue.main.async { onError("gyroflow_create not found") }
                return
            }
            let handle: UnsafeMutableRawPointer?
            if let dir = config.lensDbDir {
                handle = dir.withCString { fnCreate($0) }
            } else {
                handle = fnCreate(nil)
            }
            guard let handle else {
                DispatchQueue.main.async { onError("gyroflow_create returned NULL") }
                return
            }
            self.coreHandle = handle

            let rc1 = videoPath.withCString { self.fnLoadVideo?(handle, $0) ?? -1 }
            guard rc1 == 0 else {
                DispatchQueue.main.async { onError("gyroflow_load_video failed") }
                return
            }
            if let lensPath, let fn = self.fnLoadLens {
                let _ = lensPath.withCString { fn(handle, $0) }
            }
            self.applyConfig(config, handle: handle)
            let rc3 = self.fnRecompute?(handle) ?? -1
            guard rc3 == 0 else {
                DispatchQueue.main.async { onError("gyroflow_recompute failed") }
                return
            }
            self.readParams(handle)
            let total = self.rowCount * 14 + 9
            self.matBuf = [Float](repeating: 0, count: total)
            self.matsBuf = [Float](repeating: 0, count: Int(self.gyroVideoH) * 16)
            self.lensCorrectionAmount = Float(config.lensCorrectionAmount)
            self.readyLock.lock(); self._isReady = true; self.readyLock.unlock()
            print(String(format: "[gyroflow] Ready: %d frames x %d rows  %.0fx%.0f@%.3ffps",
                         self.frameCount, self.rowCount, self.gyroVideoW, self.gyroVideoH, self.gyroFps))
            DispatchQueue.main.async { onReady() }
        }
    }

    private func applyConfig(_ config: GyroConfig, handle: UnsafeMutableRawPointer) {
        guard let fn = fnSetParam else { return }
        let smooth = config.smooth > 0 ? config.smooth : 0.5
        "smoothness".withCString { _ = fn(handle, $0, smooth) }
        "fov".withCString                  { _ = fn(handle, $0, config.fov) }
        "lens_correction_amount".withCString { _ = fn(handle, $0, config.lensCorrectionAmount) }
        "adaptive_zoom".withCString        { _ = fn(handle, $0, config.adaptiveZoom) }
        "max_zoom".withCString             { _ = fn(handle, $0, config.maxZoom) }
        "zooming_method".withCString       { _ = fn(handle, $0, Double(config.zoomingMethod)) }
        "frame_readout_time".withCString   { _ = fn(handle, $0, config.readoutMs) }
        "video_speed".withCString          { _ = fn(handle, $0, config.videoSpeed) }
        "gyro_offset".withCString          { _ = fn(handle, $0, config.gyroOffsetMs) }
        if config.horizonLockEnabled {
            "horizon_lock_amount".withCString { _ = fn(handle, $0, config.horizonLockAmount) }
            "horizon_lock_roll".withCString   { _ = fn(handle, $0, config.horizonLockRoll) }
        }
        if config.useGravityVectors {
            "use_gravity_vectors".withCString { _ = fn(handle, $0, 1.0) }
        }
    }

    private func readParams(_ handle: UnsafeMutableRawPointer) {
        guard let fn = fnGetParams else { return }
        var buf = [UInt8](repeating: 0, count: 96)
        buf.withUnsafeMutableBytes { ptr in _ = fn(handle, ptr.baseAddress!) }
        buf.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            frameCount = Int(base.load(fromByteOffset: 0, as: UInt32.self))
            rowCount   = Int(base.load(fromByteOffset: 4, as: UInt32.self))
            gyroVideoW = Float(base.load(fromByteOffset: 8, as: UInt32.self))
            gyroVideoH = Float(base.load(fromByteOffset: 12, as: UInt32.self))
            gyroFps    = base.load(fromByteOffset: 16, as: Float64.self)
            gyroFx     = base.load(fromByteOffset: 24, as: Float.self)
            gyroFy     = base.load(fromByteOffset: 28, as: Float.self)
            gyroCx     = base.load(fromByteOffset: 32, as: Float.self)
            gyroCy     = base.load(fromByteOffset: 36, as: Float.self)
            for i in 0..<12 {
                distortionK[i] = base.load(fromByteOffset: 40 + i * 4, as: Float.self)
            }
            distortionModel = base.load(fromByteOffset: 88, as: Int32.self)
            rLimit          = base.load(fromByteOffset: 92, as: Float.self)
        }
    }

    func computeMatrixAtTime(timeSec: Double) -> (UnsafeBufferPointer<Float>, Bool)? {
        coreLock.lock(); defer { coreLock.unlock() }
        guard let handle = coreHandle, let fn = fnGetFrame, _isReady else { return nil }
        let fi = max(0, min(Int((timeSec * gyroFps).rounded()), frameCount - 1))
        if fi == cachedFrameIdx {
            lastFetchMs = 0
            return matsBuf.withUnsafeBufferPointer { ($0, false) }
        }
        let t0 = CACurrentMediaTime()
        let total = rowCount * 14 + 9
        if matBuf.count != total { matBuf = [Float](repeating: 0, count: total) }
        let rc = matBuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            fn(handle, timeSec, ptr.baseAddress!)
        }
        guard rc > 0 else { return nil }
        let pfBase = rowCount * 14
        frameFx  = matBuf[pfBase]
        frameFy  = matBuf[pfBase + 1]
        frameCx  = matBuf[pfBase + 2]
        frameCy  = matBuf[pfBase + 3]
        frameK   = [matBuf[pfBase + 4], matBuf[pfBase + 5], matBuf[pfBase + 6], matBuf[pfBase + 7]]
        frameFov = matBuf[pfBase + 8]
        lastFetchMs = (CACurrentMediaTime() - t0) * 1000.0
        // Expand rowCount x 14 -> vH x 16
        let vH = Int(gyroVideoH)
        if matsBuf.count != vH * 16 { matsBuf = [Float](repeating: 0, count: vH * 16) }
        matBuf.withUnsafeBufferPointer { raw in
        matsBuf.withUnsafeMutableBufferPointer { mats in
            let rp = raw.baseAddress!
            let mp = mats.baseAddress!
            let rc = rowCount
            for y in 0..<vH {
                let r = rc == 1 ? 0 : min(y &* rc / max(vH, 1), rc &- 1)
                let sp = rp + r &* 14
                let dp = mp + y &* 16
                dp[0]  = sp[0]; dp[1]  = sp[1]; dp[2]  = sp[2]; dp[3]  = sp[9]
                dp[4]  = sp[3]; dp[5]  = sp[4]; dp[6]  = sp[5]; dp[7]  = sp[10]
                dp[8]  = sp[6]; dp[9]  = sp[7]; dp[10] = sp[8]; dp[11] = sp[11]
                dp[12] = sp[12]; dp[13] = sp[13]; dp[14] = 0; dp[15] = 0
            }
        }}
        cachedFrameIdx = fi
        return matsBuf.withUnsafeBufferPointer { ($0, true) }
    }

    func stop() {
        readyLock.lock(); _isReady = false; readyLock.unlock()
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
// MARK: - LibMDK
// ════════════════════════════════════════════════════════

private class LibMDK {
    static let shared = LibMDK()
    private var h: UnsafeMutableRawPointer?
    private(set) var ok = false

    func load() -> Bool {
        let paths = [
            "/Applications/Gyroflow.app/Contents/Frameworks/mdk.framework/Versions/A/mdk",
            "/opt/homebrew/lib/mdk.framework/mdk",
            "/usr/local/lib/mdk.framework/mdk",
        ]
        for p in paths {
            h = dlopen(p, RTLD_LAZY | RTLD_GLOBAL)
            if h != nil { print("[mdk] ✅ Loaded: \(p)"); break }
        }
        guard h != nil else {
            print("[mdk] ❌ mdk not found")
            return false
        }
        let ver = MDK_version()
        print("[mdk] version: \((ver >> 16) & 0xFF).\((ver >> 8) & 0xFF).\(ver & 0xFF)")
        ok = true
        return true
    }
}
private let mdkLib = LibMDK.shared

// ════════════════════════════════════════════════════════
// MARK: - MPVOpenGLLayer
// ════════════════════════════════════════════════════════

class MPVOpenGLLayer: CAOpenGLLayer {

    private var cglPF:     CGLPixelFormatObj?
    private var cglCtx:    CGLContextObj?
    private(set) var isFloat = false

    // MDK 有新 frame 時由 callback 設為 true；draw() 開頭清除。
    var hasPendingFrame = false

    // ── MDK backend state ────────────────────────────────
    private var mdkAPI: UnsafePointer<mdkPlayerAPI>?
    private var mdkGLAPI = mdkGLRenderAPI()
    private var mdkReady = false
    private var mdkMuted = true
    private var mdkDuration: Double = 0  // seconds
    /// Timestamp (seconds) of the last frame rendered by MDK's renderVideo()
    private var mdkRenderedTime: Double = 0

    // ── Detected video info (set once in prepare callback) ──
    private(set) var videoWidth: Int = 0
    private(set) var videoHeight: Int = 0
    private(set) var videoCodec: String = "-"
    private(set) var videoFormatName: String = "-"
    private(set) var detectedColorSpace: String = "-"
    private(set) var detectedDoviProfile: Int = 0

    // ── Colorspace cycling ─────────────────────────────────
    private static let mdkColorSpaces: [(MDK_ColorSpace, String)] = [
        (MDK_ColorSpace_BT709,                   "BT.709"),
        (MDK_ColorSpace_BT2100_PQ,               "PQ"),
        (MDK_ColorSpace_BT2100_HLG,              "HLG"),
        (MDK_ColorSpace_scRGB,                   "scRGB"),
        (MDK_ColorSpace_ExtendedLinearDisplayP3,  "ExtLinP3"),
        (MDK_ColorSpace_ExtendedSRGB,             "ExtSRGB"),
        (MDK_ColorSpace_ExtendedLinearSRGB,       "ExtLinSRGB"),
    ]
    private static let layerColorSpaces: [(CFString, String)] = [
        (CGColorSpace.sRGB,                "sRGB"),
        (CGColorSpace.itur_2100_PQ,        "PQ"),
        (CGColorSpace.itur_2100_HLG,       "HLG"),
        (CGColorSpace.displayP3,           "Display P3"),
        (CGColorSpace.extendedSRGB,        "Ext sRGB"),
        (CGColorSpace.extendedLinearSRGB,  "Ext Lin sRGB"),
        (CGColorSpace.linearSRGB,          "Lin sRGB"),
    ]
    var mdkCSIndex = 1   // start at PQ
    var layerCSIndex = 1 // start at PQ
    var mdkCSLabel = "PQ"
    var layerCSLabel = "PQ"

    func cycleMDKColorSpace() {
        guard let api = mdkAPI, let obj = api.pointee.object else { return }
        mdkCSIndex = (mdkCSIndex + 1) % Self.mdkColorSpaces.count
        let (cs, label) = Self.mdkColorSpaces[mdkCSIndex]
        api.pointee.setColorSpace(obj, cs, nil)
        mdkCSLabel = label
        print("[color] MDK → \(label)")
    }

    func cycleCALayerColorSpace() {
        layerCSIndex = (layerCSIndex + 1) % Self.layerColorSpaces.count
        let (name, label) = Self.layerColorSpaces[layerCSIndex]
        colorspace = CGColorSpace(name: name)
        let needsEDR = (name != CGColorSpace.sRGB && name != CGColorSpace.linearSRGB)
        wantsExtendedDynamicRangeContent = needsEDR
        layerCSLabel = label
        print("[color] CALayer → \(label)  EDR=\(needsEDR)")
    }

    static func colorSpaceLabel(_ cs: MDK_ColorSpace, dovi: Int) -> String {
        if dovi > 0 { return "DV P\(dovi)" }
        switch cs {
        case MDK_ColorSpace_BT709:                  return "BT.709"
        case MDK_ColorSpace_BT2100_PQ:               return "PQ"
        case MDK_ColorSpace_BT2100_HLG:              return "HLG"
        case MDK_ColorSpace_scRGB:                   return "scRGB"
        case MDK_ColorSpace_ExtendedLinearDisplayP3:  return "ExtLinP3"
        case MDK_ColorSpace_ExtendedSRGB:             return "ExtSRGB"
        case MDK_ColorSpace_ExtendedLinearSRGB:       return "ExtLinSRGB"
        default:                                      return "Unknown(\(cs.rawValue))"
        }
    }

    // update callback 觸發時間
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
        guard let api = mdkAPI else { return 0 }
        let obj = api.pointee.object!
        guard let info = api.pointee.mediaInfo(obj), info.pointee.nb_video > 0 else { return 0 }
        var codec = mdkVideoCodecParameters()
        MDK_VideoStreamCodecParameters(&info.pointee.video[0], &codec)
        return Double(codec.frame_rate)
    }
    var droppedFrames: Int { 0 }

    // ── Warp pipeline (gyroflow-style per-row matrix) ────────
    private var stabFBO:    GLuint = 0     // intermediate FBO (mpv → here)
    private var stabTex:    GLuint = 0     // color texture attached to stabFBO
    private var stabW:      GLsizei = 0
    private var stabH:      GLsizei = 0
    private var warpProg:   GLuint = 0     // GLSL program
    private var warpVAO:    GLuint = 0     // VAO (Core profile 必須)
    private var warpVBO:    GLuint = 0     // fullscreen quad VBO
    private var useCoreProfile = false      // GL 3.2 Core vs Legacy
    private var matTexId:   GLuint = 0     // per-row matrix texture (width=3, height=videoH, RGBA32F)
    private var matTexH:    Int    = 0     // 目前 matTex 的高度（= videoHeight）
    // uniforms
    private var uTex:       GLint = -1
    private var uMatTex:    GLint = -1
    private var uVideoSize: GLint = -1
    private var uMatCount:  GLint = -1
    private var uFIn:       GLint = -1
    private var uCIn:       GLint = -1
    private var uDistK:     GLint = -1
    private var uDistModel: GLint = -1
    private var uRLimit:    GLint = -1
    private var uFrameFov:  GLint = -1
    private var uLensCorr:  GLint = -1
    var activeGyro: GyroCoreProvider?   // non-nil → real-time warp active

    override init() {
        super.init()
        isAsynchronous = true
        setupGL()
        if mdkLib.ok { setupMDK() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // ─── OpenGL Pixel Format & Context ───────────────────

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
            // 基礎屬性：Profile + Accelerated + DoubleBuffer
            let glBase: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(ver.rawValue),
                kCGLPFAAccelerated,
                kCGLPFADoubleBuffer
            ]
            // 組合：基礎 + 10-bit float + 可選屬性（漸進式 fallback）
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
        colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)

        // ★ 告知 macOS 此 layer 要顯示 EDR 內容
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

    // ─── Warp Pipeline（gyroflow 方式：per-row matrix texture）──

    private func setupWarpPipeline() {
        guard let cglCtx else { return }
        CGLSetCurrentContext(cglCtx)

        // ── Shader 版本根據 GL profile 選擇 ──
        // Core 3.2: #version 150 (in/out, texture(), 需要 VAO)
        // Legacy:   #version 120 (attribute/varying, texture2D, gl_FragColor)
        let vsSrc: String
        let fsSrc: String

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
            // (Matches Spectrum/Views/Detail/MPVPlayerView.swift exactly)
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
        float t2 = theta*theta; float t4 = t2*t2; float t6 = t4*t2; float t8 = t4*t4;
        float theta_d = theta * (1.0 + distK[0].x*t2 + distK[0].y*t4 + distK[0].z*t6 + distK[0].w*t8);
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        return pos * scale;
    }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta*theta; float t3 = t2*theta; float t4 = t2*t2; float t5 = t4*theta; float t6 = t3*t3;
        float theta_d = distK[0].x*theta + distK[0].y*t2 + distK[0].z*t3 + distK[0].w*t4 + distK[1].x*t5 + distK[1].y*t6;
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
    src = clamp(src, vec2(0.0), vec2(1.0));
    fragColor = texture(tex, src);
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
            // Legacy fallback (rarely used on Apple Silicon)
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
vec2 distort_point(float x, float y, float w) {
    vec2 pos = vec2(x, y) / w;
    if (distModel == 0) return pos;
    float r = length(pos);
    if (rLimit > 0.0 && r > rLimit) return vec2(-99999.0);
    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta*theta; float t4 = t2*t2; float t6 = t4*t2; float t8 = t4*t4;
        float theta_d = theta * (1.0 + distK[0].x*t2 + distK[0].y*t4 + distK[0].z*t6 + distK[0].w*t8);
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        return pos * scale;
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
        uDistK     = glGetUniformLocation(warpProg, "distK")
        uDistModel = glGetUniformLocation(warpProg, "distModel")
        uRLimit    = glGetUniformLocation(warpProg, "rLimit")
        uFrameFov  = glGetUniformLocation(warpProg, "frameFov")
        uLensCorr  = glGetUniformLocation(warpProg, "lensCorr")
        let profile = useCoreProfile ? "GL 3.2 Core (#version 150)" : "Legacy (#version 120)"
        print("[Warp] ✅ gyroflow shader compiled (\(profile), uMatTex=\(uMatTex) uVideoSize=\(uVideoSize))")

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

    // ─── MDK 初始化 ───────────────────────────────────────

    private func setupMDK() {
        guard mdkLib.ok else { return }
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
        mdkGLAPI.fbo = -1  // will be set per draw call

        // Render callback: signal new frame
        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        api.pointee.setRenderCallback(obj, mdkRenderCallback(cb: { _, opaque in
            guard let opaque else { return }
            let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(opaque).takeUnretainedValue()
            layer.callbackTime = CACurrentMediaTime()
            layer.hasPendingFrame = true
            layer.setNeedsDisplay()
        }, opaque: selfRef))

        // Default PQ output for HDR
        api.pointee.setColorSpace(obj, MDK_ColorSpace_BT2100_PQ, nil)

        print("[mdk] ✅ Player initialized")
    }

    // ─── 穩定化資料 ─────────────────────────────────────

    func loadGyroCore(_ server: GyroCoreProvider?) {
        activeGyro = server
        lastGyroFrameIdx = nil   // 重置單調保護
    }

    // ─── 載入檔案 ────────────────────────────────────────

    func loadFile(_ path: String) {
        guard let api = mdkAPI else { return }
            let obj = api.pointee.object!
        print("[mdk] Loading: \(path)")
        mdkReady = false
        api.pointee.setMedia(obj, path)

        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        api.pointee.prepare(obj, 0, mdkPrepareCallback(cb: { position, boost, opaque in
            guard let opaque else { return true }
            let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(opaque).takeUnretainedValue()
            guard position >= 0 else {
                print("[mdk] ❌ prepare failed: position=\(position)")
                return false
            }
            // Read media info for duration and color space
            if let api = layer.mdkAPI, let rawObj = api.pointee.object,
               let info = api.pointee.mediaInfo(rawObj) {
                layer.mdkDuration = Double(info.pointee.duration) / 1000.0
                if info.pointee.nb_video > 0 {
                    var codec = mdkVideoCodecParameters()
                    MDK_VideoStreamCodecParameters(&info.pointee.video[0], &codec)
                    let cs = codec.color_space
                    let doviProfile = codec.dovi_profile
                    // Store detected info
                    layer.videoWidth = Int(codec.width)
                    layer.videoHeight = Int(codec.height)
                    layer.videoCodec = codec.codec.map { String(cString: $0) } ?? "-"
                    layer.videoFormatName = codec.format_name.map { String(cString: $0) } ?? "-"
                    layer.detectedDoviProfile = Int(doviProfile)
                    layer.detectedColorSpace = MPVOpenGLLayer.colorSpaceLabel(cs, dovi: Int(doviProfile))
                    print("[mdk] Media: duration=\(layer.mdkDuration)s  color_space=\(cs.rawValue)  dovi_profile=\(doviProfile)")

                    // DV P8.4 (Apple) → PQ;  HLG → HLG;  Other → PQ
                    if cs == MDK_ColorSpace_BT2100_HLG && doviProfile != 8 {
                        // HLG content: MDK output HLG, CALayer use HLG
                        api.pointee.setColorSpace(rawObj, MDK_ColorSpace_BT2100_HLG, nil)
                        layer.mdkCSLabel = "HLG"; layer.mdkCSIndex = 6
                        print("[mdk] Colorspace: HLG → HLG")
                        DispatchQueue.main.async {
                            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                            layer.wantsExtendedDynamicRangeContent = true
                            layer.layerCSLabel = "HLG"; layer.layerCSIndex = 2
                        }
                    } else {
                        // DV P8.4, PQ, or other: MDK output PQ, CALayer use PQ
                        api.pointee.setColorSpace(rawObj, MDK_ColorSpace_BT2100_PQ, nil)
                        layer.mdkCSLabel = "PQ"; layer.mdkCSIndex = 1
                        print("[mdk] Colorspace: \(doviProfile == 8 ? "DV P8.4" : "default") → PQ")
                        DispatchQueue.main.async {
                            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                            layer.wantsExtendedDynamicRangeContent = true
                            layer.layerCSLabel = "PQ"; layer.layerCSIndex = 1
                        }
                    }
                }
            }
            layer.mdkReady = true
            print("[mdk] ✅ Prepared, position=\(position)")
            return true
        }, opaque: selfRef), MDK_SeekFlag_FromStart)

        api.pointee.setState(obj, MDK_State_Playing)
    }

    // ─── 播放控制 ────────────────────────────────────

    func setPause(_ paused: Bool) {
        guard let api = mdkAPI else { return }
            let obj = api.pointee.object!
        api.pointee.setState(obj, paused ? MDK_State_Paused : MDK_State_Playing)
    }

    func togglePause() {
        guard let api = mdkAPI else { return }
            let obj = api.pointee.object!
        let current = api.pointee.state(obj)
        api.pointee.setState(obj, current == MDK_State_Playing ? MDK_State_Paused : MDK_State_Playing)
    }

    func toggleMute() {
        guard let api = mdkAPI else { return }
            let obj = api.pointee.object!
        mdkMuted.toggle()
        api.pointee.setMute(obj, mdkMuted)
    }

    func seek(seconds: Int) {
        guard let api = mdkAPI else { return }
            let obj = api.pointee.object!
        let ms = Int64(seconds) * 1000
        _ = api.pointee.seekWithFlags(obj, ms, MDK_SeekFlag(rawValue: MDK_SeekFlag_FromNow.rawValue | MDK_SeekFlag_KeyFrame.rawValue),
                                      mdkSeekCallback(cb: nil, opaque: nil))
    }

    func seek(_ seconds: Double, absolute: Bool) {
        guard let api = mdkAPI else { return }
            let obj = api.pointee.object!
        let ms = Int64(seconds * 1000)
        let flags: MDK_SeekFlag = absolute
            ? MDK_SeekFlag(rawValue: MDK_SeekFlag_FromStart.rawValue | MDK_SeekFlag_KeyFrame.rawValue)
            : MDK_SeekFlag(rawValue: MDK_SeekFlag_FromNow.rawValue | MDK_SeekFlag_KeyFrame.rawValue)
        _ = api.pointee.seekWithFlags(obj, ms, flags, mdkSeekCallback(cb: nil, opaque: nil))
    }

    func frameStep() {
        guard let api = mdkAPI else { return }
            let obj = api.pointee.object!
        _ = api.pointee.seekWithFlags(obj, 1,
            MDK_SeekFlag(rawValue: MDK_SeekFlag_FromNow.rawValue | MDK_SeekFlag_Frame.rawValue),
            mdkSeekCallback(cb: nil, opaque: nil))
    }

    func frameBackStep() {
        guard let api = mdkAPI else { return }
            let obj = api.pointee.object!
        _ = api.pointee.seekWithFlags(obj, -1,
            MDK_SeekFlag(rawValue: MDK_SeekFlag_FromNow.rawValue | MDK_SeekFlag_Frame.rawValue),
            mdkSeekCallback(cb: nil, opaque: nil))
    }

    var currentTimeSec: Double {
        guard let api = mdkAPI else { return 0 }
            let obj = api.pointee.object!
        return Double(api.pointee.position(obj)) / 1000.0
    }

    var isEOFReached: Bool {
        guard let api = mdkAPI else { return false }
        let obj = api.pointee.object!
        return api.pointee.mediaStatus(obj).rawValue & MDK_MediaStatus_End.rawValue != 0
    }

    // ─── CAOpenGLLayer 覆寫 ──────────────────────────────

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        cglPF ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        cglCtx ?? super.copyCGLContext(forPixelFormat: pf)
    }

    private var lastDrawnSize: CGSize = .zero

    override func canDraw(inCGLContext ctx: CGLContextObj,
                          pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval,
                          displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        guard mdkAPI != nil, mdkReady else { return false }
        if bounds.size != lastDrawnSize { return true }
        return hasPendingFrame
    }

    override func draw(inCGLContext ctx: CGLContextObj,
                       pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval,
                       displayTime ts: UnsafePointer<CVTimeStamp>?) {
        hasPendingFrame = false
        guard mdkAPI != nil, mdkReady else { return }

        // CGLLockContext：確保多執行緒時 OpenGL context 使用安全
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }

        lastDrawnSize = bounds.size

        // ── EOF 偵測：暫停並 seek 回開頭，避免 MDK 顯示浮水印 ──
        if isEOFReached {
            setPause(true)
            seek(0, absolute: true)
            return
        }

        // IINA 方式：用 GL_VIEWPORT 取得實際 FBO 尺寸（比 layer.bounds 可靠）
        var dims = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)
        let w = dims[2] > 0 ? dims[2] : 1
        let h = dims[3] > 0 ? dims[3] : 1

        var displayFBO = GLint(0)
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &displayFBO)

        frameCount += 1
        if frameCount == 1 || frameCount % 60 == 0 {
            let fetchMs = activeGyro?.lastFetchMs ?? 0
            let fetchStr = activeGyro?.isReady == true
                ? String(format: "  gyroFetch=%.3fms", fetchMs)
                : ""
            print("[GL] draw() #\(frameCount): w=\(w) h=\(h) fbo=\(displayFBO) float=\(isFloat)\(fetchStr)")
        }

        // ── Determine stabilization state (before Pass 1, so we know the target FBO) ──
        let wantStab = activeGyro?.isReady == true && warpProg != 0

        // 穩定化時渲染到影片原始解析度的 FBO，warp 在全解析度執行後才 downsample
        let vidW: GLsizei = wantStab ? GLsizei(activeGyro!.gyroVideoW) : w
        let vidH: GLsizei = wantStab ? GLsizei(activeGyro!.gyroVideoH) : h

        if wantStab && (stabW != vidW || stabH != vidH) {
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

        // ── Pass 1：MDK video decode → FBO ──────────────────────────────
        guard let api = mdkAPI else { return }
        let obj = api.pointee.object!
        let targetFBO = wantStab ? Int32(stabFBO) : displayFBO
        mdkGLAPI.fbo = targetFBO
        withUnsafeMutablePointer(to: &mdkGLAPI) { glPtr in
            api.pointee.setRenderAPI(obj, OpaquePointer(glPtr), nil)
        }
        api.pointee.setVideoSurfaceSize(obj, Int32(vidW), Int32(vidH), nil)
        let ts = api.pointee.renderVideo(obj, nil)
        if ts >= 0 { mdkRenderedTime = ts }

        // ── Gyro matrix computation (AFTER Pass 1 so MDK frame time is available) ──
        var gyroResult: (UnsafeBufferPointer<Float>, Bool)? = nil
        var gyroFrameRepeated = false
        if wantStab, let core = activeGyro, core.isReady {
            // MDK: renderVideo() returned exact frame timestamp — no delay compensation
            let renderTime = max(0, mdkRenderedTime)
            // Frame index for repeat detection only (not passed to gyroflow-core)
            var fi = max(0, min(Int((renderTime * core.gyroFps).rounded()),
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
            }

            if fi == lastGyroFrameIdx {
                // 同一影片幀（120Hz draw 60fps 內容）→ 重用已有 stabFBO + matTex
                gyroFrameRepeated = true
            } else {
                lastGyroFrameIdx = fi
                // Use timestamp-based API for accurate RS correction (no quantization)
                gyroResult = core.computeMatrixAtTime(timeSec: renderTime)
            }
        }

        let hasStab = (gyroResult != nil || gyroFrameRepeated) && wantStab

        // ── Pass 2：gyroflow per-row warp ──────────────────
        if hasStab, let server = activeGyro {
            let vH = Int(server.gyroVideoH)
            let vW = server.gyroVideoW

            // 新幀：上傳矩陣；repeated 幀：重用已有的 matTex
            if let (matBuf, _) = gyroResult {
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

                // 矩陣就緒：上傳
                glBindTexture(GLenum(GL_TEXTURE_2D), matTexId)
                glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0,
                                0, 0, 4, GLsizei(vH),
                                GLenum(GL_RGBA), GLenum(GL_FLOAT),
                                matBuf.baseAddress)
                glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            }

            // 切回 display FBO，執行 warp（新幀和 repeated 幀都需要）
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

            // Per-frame f, c (may change due to adaptive zoom or per-frame lens telemetry)
            glUniform2f(uFIn, server.frameFx, server.frameFy)
            glUniform2f(uCIn, server.frameCx, server.frameCy)
            // Per-frame distortion k[0..3] + static k[4..11] (merged into 3 × vec4)
            var mergedK: [Float] = [Float](repeating: 0, count: 12)
            mergedK[0] = server.frameK[0]
            mergedK[1] = server.frameK[1]
            mergedK[2] = server.frameK[2]
            mergedK[3] = server.frameK[3]
            for i in 4..<12 { mergedK[i] = server.distortionK[i] }
            mergedK.withUnsafeBufferPointer { kPtr in
                glUniform4fv(uDistK, 3, kPtr.baseAddress)
            }
            glUniform1i(uDistModel, server.distortionModel)
            glUniform1f(uRLimit, server.rLimit)
            glUniform1f(uFrameFov, server.frameFov)
            glUniform1f(uLensCorr, server.lensCorrectionAmount)

            if frameCount <= 300 && frameCount % 30 == 0 {
                let fpsStr = renderFPS > 0 ? String(format: "%.1ffps", renderFPS) : "?"
                let fiStr = lastGyroFrameIdx.map { String($0) } ?? "nil"
                let timeInfo = String(format: "frameTime=%.4f", mdkRenderedTime)
                print(String(format: "[GL] draw#%d  %@  %@  fi=%@  fov=%.3f  %@",
                             frameCount, timeInfo,
                             gyroFrameRepeated ? "rep" : "NEW",
                             fiStr,
                             server.frameFov, fpsStr))
            }

            // Draw fullscreen quad (VAO 包含 VBO 綁定 + attrib 設定)
            glBindVertexArray(warpVAO)
            glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
            glBindVertexArray(0)

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
        if mdkAPI != nil { var apiPtr = mdkAPI; mdkPlayerAPI_delete(&apiPtr) }
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
    func toggleMute() { mpvLayer.toggleMute() }
    func frameStep() { mpvLayer.frameStep() }
    func frameBackStep() { mpvLayer.frameBackStep() }
    var currentTimeSec: Double { mpvLayer.currentTimeSec }
    func loadGyroCore(_ server: GyroCoreProvider?) { mpvLayer.loadGyroCore(server) }
    func resetGyroFrameIdx() { mpvLayer.lastGyroFrameIdx = nil }

    var renderFPS: Double      { mpvLayer.renderFPS      }
    var renderCV: Double       { mpvLayer.renderCV       }
    var videoFPS: Double       { mpvLayer.videoFPS       }
    var droppedFrames: Int     { mpvLayer.droppedFrames  }
    var stabilityScore: Float  { mpvLayer.stabilityScore }
    var isFloat: Bool          { mpvLayer.isFloat        }

    func cycleMDKColorSpace() { mpvLayer.cycleMDKColorSpace() }
    func cycleCALayerColorSpace() { mpvLayer.cycleCALayerColorSpace() }
    var mdkCSLabel: String { mpvLayer.mdkCSLabel }
    var layerCSLabel: String { mpvLayer.layerCSLabel }

    // Video info pass-throughs
    var videoWidth: Int       { mpvLayer.videoWidth }
    var videoHeight: Int      { mpvLayer.videoHeight }
    var videoCodec: String    { mpvLayer.videoCodec }
    var videoFormatName: String { mpvLayer.videoFormatName }
    var detectedColorSpace: String { mpvLayer.detectedColorSpace }
    var detectedDoviProfile: Int   { mpvLayer.detectedDoviProfile }
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
    var infoLabel: NSTextField!
    var statsTimer: Timer?

    // ── Stabilization state ──────────────────────────────
    var originalPath: String?        // 目前播放的原始檔路徑
    var stabilizedPath: String?      // Phase 1：穩定化 MP4 路徑
    var isShowingStabilized = false  // Phase 1：目前顯示穩定化版本？
    var activeGyro: GyroCoreProvider?  // Phase 2：即時 gyrocore 穩定化（nil = 關閉）
    var gyroMethod: String = "spectrum" // "spectrum" or "gyroflow"
    var gyroOffsetMs: Double = 0.0  // Gyro-video sync offset (ms)
    var gyroSmoothness: Double = 0.5  // 平滑度 (0.01–3.0)
    var gyroRSEnabled: Bool = true    // Rolling shutter 修正
    var gyroFrameSync: Int = 0       // Frame sync offset (+/- frames, 即時微調用)
    var frameDelayFrames: Double = 1.0  // Render pipeline latency (frames)
    var stabManager = StabilizationManager()
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard mdkLib.load() else {
            let a = NSAlert()
            a.messageText = "MDK not found"
            a.informativeText = "Install Gyroflow.app (contains mdk.framework)"
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

        // ── Video info badge (top-left) ──────────────────────────
        let infoContainer = NSView()
        infoContainer.wantsLayer = true
        infoContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        infoContainer.layer?.cornerRadius = 5
        infoContainer.translatesAutoresizingMaskIntoConstraints = false

        infoLabel = NSTextField(labelWithString: "–")
        infoLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        infoLabel.isBezeled = false
        infoLabel.drawsBackground = false
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.maximumNumberOfLines = 0

        infoContainer.addSubview(infoLabel)
        window.contentView!.addSubview(infoContainer)

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: infoContainer.topAnchor, constant: 5),
            infoLabel.bottomAnchor.constraint(equalTo: infoContainer.bottomAnchor, constant: -5),
            infoLabel.leadingAnchor.constraint(equalTo: infoContainer.leadingAnchor, constant: 8),
            infoLabel.trailingAnchor.constraint(equalTo: infoContainer.trailingAnchor, constant: -8),
            infoContainer.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 8),
            infoContainer.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 8),
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

            // Video info badge
            let v = self.mpvView!
            var lines: [String] = []
            if v.videoWidth > 0 {
                lines.append("\(v.videoWidth)×\(v.videoHeight)")
            }
            if v.videoCodec != "-" { lines.append(v.videoCodec) }
            if v.videoFormatName != "-" { lines.append(v.videoFormatName) }
            lines.append("Detected: \(v.detectedColorSpace)")
            lines.append("MDK: \(v.mdkCSLabel)  Layer: \(v.layerCSLabel)")
            self.infoLabel.stringValue = lines.joined(separator: "\n")
        }
        // ──────────────────────────────────────────────────────────

        // ── 鍵盤快捷鍵 ────────────────────────────────────────
        // 5 (23)     : cycle MDK colorspace
        // 6 (22)     : cycle CALayer colorspace
        // M (46)     : toggle mute
        // S (1)      : Phase 1：切換原始↔穩定化（若無則觸發 gyroflow 渲染）
        // R (15)     : gyro 穩定化 on/off
        // T (17)     : 切換 Rolling Shutter 修正
        // [ (33)     : 降低平滑度 (-0.1)
        // ] (30)     : 提高平滑度 (+0.1)
        // ↑ (126)   : offset +5ms（Shift: +1ms）
        // ↓ (125)   : offset -5ms（Shift: -1ms）
        // - (27)     : frame delay -0.25（Shift: -0.05）
        // = (24)     : frame delay +0.25（Shift: +0.05）
        // ← (123)   : 倒退 5 秒
        // → (124)   : 快進 5 秒
        // Space (49) : 暫停/繼續
        // Q (12)     : 離開
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 46:  self.mpvView.toggleMute(); return nil   // M：toggle mute
            case 1:   self.handleStabilizeKey(); return nil  // S：Phase 1 切換
            case 15:                                         // R：切換 gyro 穩定化 on/off
                if self.activeGyro != nil {
                    self.activeGyro?.stop()
                    self.activeGyro = nil
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
                if let path = self.originalPath, self.activeGyro != nil {
                    self.restartGyro(for: path)
                }
                return nil
            case 33:                                         // [：降低平滑度
                self.gyroSmoothness = max(0.01, self.gyroSmoothness - 0.1)
                print(String(format: "[gyro] smoothness = %.2f", self.gyroSmoothness))
                if let path = self.originalPath, self.activeGyro != nil {
                    self.restartGyro(for: path)
                }
                return nil
            case 30:                                         // ]：提高平滑度
                self.gyroSmoothness = min(3.0, self.gyroSmoothness + 0.1)
                print(String(format: "[gyro] smoothness = %.2f", self.gyroSmoothness))
                if let path = self.originalPath, self.activeGyro != nil {
                    self.restartGyro(for: path)
                }
                return nil
            case 27:                                         // -：frame delay -
                let step = event.modifierFlags.contains(.shift) ? 0.05 : 0.25
                self.frameDelayFrames -= step
                print(String(format: "[gyro] frameDelay = %.2f frames", self.frameDelayFrames))
                self.updateTitle()
                return nil
            case 24:                                         // =：frame delay +
                let step = event.modifierFlags.contains(.shift) ? 0.05 : 0.25
                self.frameDelayFrames += step
                print(String(format: "[gyro] frameDelay = %.2f frames", self.frameDelayFrames))
                self.updateTitle()
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
            case 23:                                         // 5：cycle MDK colorspace
                self.mpvView.cycleMDKColorSpace()
                self.updateTitle()
                return nil
            case 22:                                         // 6：cycle CALayer colorspace
                self.mpvView.cycleCALayerColorSpace()
                self.updateTitle()
                return nil
            case 5:                                          // G：切換 gyro method
                self.gyroMethod = self.gyroMethod == "spectrum" ? "gyroflow" : "spectrum"
                print("[gyro] method = \(self.gyroMethod)")
                if let path = self.originalPath, self.activeGyro != nil {
                    self.restartGyro(for: path)
                }
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
            activeGyro?.stop(); activeGyro = nil
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

        var cfg = GyroConfig()
        cfg.readoutMs = gyroRSEnabled ? readout : 0.0
        cfg.smooth = gyroSmoothness
        cfg.gyroOffsetMs = gyroOffsetMs
        cfg.lensDbDir = "/Applications/Gyroflow.app/Contents/Resources"

        let onReady: (GyroCoreProvider) -> Void = { [weak self] server in
            guard let self, self.activeGyro === server else { return }
            self.mpvView.loadGyroCore(server)
            self.mpvView.seek(0, absolute: true)
            print("[gyro] ✅ 穩定化啟動 (\(self.gyroMethod))")
            self.updateTitle()
        }
        let onError: (GyroCoreProvider, String) -> Void = { [weak self] server, msg in
            print("[gyro] ❌ \(msg)")
            DispatchQueue.main.async {
                guard let self else { return }
                if self.activeGyro === server { self.activeGyro = nil }
                self.updateTitle()
            }
        }

        if gyroMethod == "gyroflow" {
            let server = GyroFlowCore()
            activeGyro = server
            updateTitle()
            server.start(videoPath: videoPath, lensPath: lensPath, config: cfg,
                         onReady: { onReady(server) },
                         onError: { onError(server, $0) })
        } else {
            let server = GyroCore()
            activeGyro = server
            updateTitle()
            server.start(videoPath: videoPath, lensPath: lensPath, config: cfg,
                         onReady: { onReady(server) },
                         onError: { onError(server, $0) })
        }
    }

    /// 重新啟動 gyro（offset 變更時使用）
    private func restartGyro(for videoPath: String) {
        activeGyro?.stop()
        activeGyro = nil
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
        let depth = mpvView.isFloat ? 16 : 8
        let csStr = "  MDK=\(mpvView.mdkCSLabel) Layer=\(mpvView.layerCSLabel)"
        if let s = status {
            window.title = "testmpv [MDK] — \(s)"
        } else if stabManager.isRendering {
            window.title = "\(name) [MDK] [渲染中…]"
        } else if let srv = activeGyro {
            let syncStr = gyroFrameSync != 0 ? "  sync=\(gyroFrameSync > 0 ? "+" : "")\(gyroFrameSync)f" : ""
            let ptsStr = String(format: "  delay=%.2ff", frameDelayFrames)
            let params = String(format: "smooth=%.2f  RS=%@  offset=%dms",
                                gyroSmoothness, gyroRSEnabled ? "ON" : "OFF", Int(gyroOffsetMs)) + syncStr + ptsStr
            let methodStr = gyroMethod == "gyroflow" ? "gyroflow" : "gyro"
            window.title = srv.isReady
                ? "\(name) [MDK] [\(methodStr) \(params)]  depth=\(depth)\(csStr)"
                : "\(name) [MDK] [\(methodStr) 初始化中…]"
        } else if isShowingStabilized {
            window.title = "\(name) [MDK] [Phase 1]  depth=\(depth)\(csStr)"
        } else {
            window.title = "\(name) [MDK] depth=\(depth)\(csStr)"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activeGyro?.stop()
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
