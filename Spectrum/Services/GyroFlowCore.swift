import Darwin
import Foundation
import QuartzCore  // CACurrentMediaTime

// MARK: - GyroFlowCore (incremental API)
//
// Wraps the gyroflow_* C API that retains the full StabilizationManager,
// allowing parameter changes + recompute (~50ms) without full reload (~300ms).
// The output format is identical to GyroCore — GPU shader needs no changes.

final class GyroFlowCore: @unchecked Sendable {
    // C function pointer types
    private typealias FnCreate     = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias FnLoadVideo  = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Int32
    private typealias FnLoadLens   = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Int32
    private typealias FnSetParam   = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, Double) -> Int32
    private typealias FnSetParamS  = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    private typealias FnRecompute  = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias FnGetFrame   = @convention(c) (UnsafeMutableRawPointer, Double, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnGetParams  = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias FnGetLens    = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    private typealias FnFree       = @convention(c) (UnsafeMutableRawPointer) -> Void

    // Public metadata (same as GyroCore)
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
    private(set) var lensInfo: String = ""
    private(set) var lastFetchMs: Double = 0

    private var readyLock = NSLock()
    private var _isReady = false
    var isReady: Bool { readyLock.lock(); defer { readyLock.unlock() }; return _isReady }

    private var coreLock = NSLock()
    private let ioQueue = DispatchQueue(label: "gyroflow.io", qos: .userInitiated)
    private var libHandle: UnsafeMutableRawPointer?
    private var coreHandle: UnsafeMutableRawPointer?

    // Function pointers
    private var fnCreate:     FnCreate?
    private var fnLoadVideo:  FnLoadVideo?
    private var fnLoadLens:   FnLoadLens?
    private var fnSetParam:   FnSetParam?
    private var fnSetParamS:  FnSetParamS?
    private var fnRecompute:  FnRecompute?
    private var fnGetFrame:   FnGetFrame?
    private var fnGetParams:  FnGetParams?
    private var fnGetLens:    FnGetLens?
    private var fnFree:       FnFree?

    // Pre-allocated buffers
    private var matBuf: [Float] = []       // rawBuf: rowCount × 14 + 9
    private var matsBuf: [Float] = []      // expanded: videoH × 16 (RGBA32F)
    private var cachedFrameIdx: Int = -1

    func start(videoPath: String, lensPath: String?, config: GyroConfig,
               onReady: @Sendable @escaping () -> Void, onError: @Sendable @escaping (String) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            // dlopen
            let searchPaths = [
                Bundle.main.resourcePath.map { "\($0)/lib/libgyrocore_c.dylib" },
                Optional("libgyrocore_c.dylib"),
                Optional("\(NSHomeDirectory())/my_photo/MyPhoto/gyro-wrapper/target/release/libgyrocore_c.dylib"),
                Optional("\(NSHomeDirectory())/gyroflow/target/release/libgyrocore_c.dylib"),
            ].compactMap { $0 }
            for path in searchPaths {
                self.libHandle = dlopen(path, RTLD_LAZY)
                if self.libHandle != nil { break }
            }
            guard let lib = self.libHandle else {
                DispatchQueue.main.async { onError("libgyrocore_c.dylib not found") }
                return
            }
            // dlsym
            self.fnCreate    = dlsym(lib, "gyroflow_create").map    { unsafeBitCast($0, to: FnCreate.self) }
            self.fnLoadVideo = dlsym(lib, "gyroflow_load_video").map { unsafeBitCast($0, to: FnLoadVideo.self) }
            self.fnLoadLens  = dlsym(lib, "gyroflow_load_lens").map  { unsafeBitCast($0, to: FnLoadLens.self) }
            self.fnSetParam  = dlsym(lib, "gyroflow_set_param").map  { unsafeBitCast($0, to: FnSetParam.self) }
            self.fnSetParamS = dlsym(lib, "gyroflow_set_param_str").map { unsafeBitCast($0, to: FnSetParamS.self) }
            self.fnRecompute = dlsym(lib, "gyroflow_recompute").map  { unsafeBitCast($0, to: FnRecompute.self) }
            self.fnGetFrame  = dlsym(lib, "gyroflow_get_frame").map  { unsafeBitCast($0, to: FnGetFrame.self) }
            self.fnGetParams = dlsym(lib, "gyroflow_get_params").map { unsafeBitCast($0, to: FnGetParams.self) }
            self.fnGetLens   = dlsym(lib, "gyroflow_get_lens_info").map { unsafeBitCast($0, to: FnGetLens.self) }
            self.fnFree      = dlsym(lib, "gyroflow_free").map       { unsafeBitCast($0, to: FnFree.self) }

            guard let fnCreate = self.fnCreate else {
                DispatchQueue.main.async { onError("gyroflow_create not found") }
                return
            }
            // Create handle with lens DB dir
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

            // Load video
            let rc1 = videoPath.withCString { self.fnLoadVideo?(handle, $0) ?? -1 }
            guard rc1 == 0 else {
                DispatchQueue.main.async { onError("gyroflow_load_video failed") }
                return
            }

            // Load lens if provided
            if let lensPath, let fn = self.fnLoadLens {
                let _ = lensPath.withCString { fn(handle, $0) }
            }

            // Apply config params
            self.applyConfig(config, handle: handle)

            // Recompute
            let rc3 = self.fnRecompute?(handle) ?? -1
            guard rc3 == 0 else {
                DispatchQueue.main.async { onError("gyroflow_recompute failed") }
                return
            }

            // Read params
            self.readParams(handle)

            guard self.frameCount > 0 else {
                print("[gyroflow] load succeeded but frameCount=0 — no usable gyro data")
                self.fnFree?(handle)
                self.coreHandle = nil
                DispatchQueue.main.async { onError("No gyro data (0 frames)") }
                return
            }

            // Pre-allocate buffers
            let total = self.rowCount * 14 + 9
            self.matBuf = [Float](repeating: 0, count: total)
            self.matsBuf = [Float](repeating: 0, count: Int(self.gyroVideoH) * 16)
            self.cachedFrameIdx = -1

            self.lensCorrectionAmount = Float(config.lensCorrectionAmount)
            self.readyLock.lock(); self._isReady = true; self.readyLock.unlock()
            DispatchQueue.main.async { onReady() }
        }
    }

    private func applyConfig(_ config: GyroConfig, handle: UnsafeMutableRawPointer) {
        guard let fn = fnSetParam else { return }
        let smooth = config.smooth > 0 ? config.smooth : 0.5
        "smoothness".withCString { _ = fn(handle, $0, smooth) }
        if config.perAxis {
            "smoothness_pitch".withCString { _ = fn(handle, $0, config.smoothnessPitch > 0 ? config.smoothnessPitch : smooth) }
            "smoothness_yaw".withCString   { _ = fn(handle, $0, config.smoothnessYaw > 0 ? config.smoothnessYaw : smooth) }
            "smoothness_roll".withCString  { _ = fn(handle, $0, config.smoothnessRoll > 0 ? config.smoothnessRoll : smooth) }
        }
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
        if let orient = config.imuOrientation, !orient.isEmpty, let fnS = fnSetParamS {
            "imu_orientation".withCString { key in orient.withCString { val in _ = fnS(handle, key, val) } }
        }
    }

    private func readParams(_ handle: UnsafeMutableRawPointer) {
        guard let fn = fnGetParams else { return }
        var buf = [UInt8](repeating: 0, count: 96)
        buf.withUnsafeMutableBytes { ptr in
            _ = fn(handle, ptr.baseAddress!)
        }
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
        // Read lens info
        if let fnLens = fnGetLens {
            var infoBuf = [UInt8](repeating: 0, count: 256)
            let len = infoBuf.withUnsafeMutableBufferPointer { fnLens(handle, $0.baseAddress!, 256) }
            if len > 0 { lensInfo = String(bytes: infoBuf[0..<Int(len)], encoding: .utf8) ?? "" }
        }
    }

    // MARK: - Incremental update

    func setParam(_ key: String, _ value: Double) {
        coreLock.lock(); defer { coreLock.unlock() }
        guard let handle = coreHandle, let fn = fnSetParam else { return }
        key.withCString { _ = fn(handle, $0, value) }
    }

    func recompute(completion: (@Sendable () -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.coreLock.lock()
            guard let handle = self.coreHandle, let fn = self.fnRecompute else {
                self.coreLock.unlock()
                return
            }
            let _ = fn(handle)
            self.readParams(handle)
            let total = self.rowCount * 14 + 9
            if self.matBuf.count != total {
                self.matBuf = [Float](repeating: 0, count: total)
            }
            let vH16 = Int(self.gyroVideoH) * 16
            if self.matsBuf.count != vH16 {
                self.matsBuf = [Float](repeating: 0, count: vH16)
            }
            self.cachedFrameIdx = -1   // invalidate cache after recompute
            self.coreLock.unlock()
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    // MARK: - Compute matrix (same interface as GyroCore)

    func computeMatrixAtTime(timeSec: Double) -> (UnsafeBufferPointer<Float>, Bool)? {
        coreLock.lock(); defer { coreLock.unlock() }
        guard let handle = coreHandle, let fn = fnGetFrame, _isReady else { return nil }

        // Cache hit — same frame, reuse existing matsBuf
        let fi = max(0, min(Int((timeSec * gyroFps).rounded()), frameCount - 1))
        if fi == cachedFrameIdx {
            lastFetchMs = 0
            return matsBuf.withUnsafeBufferPointer { ($0, false) }
        }

        let total = rowCount * 14 + 9
        if matBuf.count != total { matBuf = [Float](repeating: 0, count: total) }
        let t0 = CACurrentMediaTime()
        let rc = matBuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            fn(handle, timeSec, ptr.baseAddress!)
        }
        lastFetchMs = (CACurrentMediaTime() - t0) * 1000.0
        guard rc > 0 else { return nil }

        // Extract per-frame params from tail
        let pfBase = rowCount * 14
        frameFx  = matBuf[pfBase]
        frameFy  = matBuf[pfBase + 1]
        frameCx  = matBuf[pfBase + 2]
        frameCy  = matBuf[pfBase + 3]
        frameK   = [matBuf[pfBase + 4], matBuf[pfBase + 5], matBuf[pfBase + 6], matBuf[pfBase + 7]]
        frameFov = matBuf[pfBase + 8]

        // Expand rowCount × 14 → videoH × 16 floats (matTex width=4, RGBA32F)
        let vH = Int(gyroVideoH)
        let vH16 = vH * 16
        if matsBuf.count != vH16 { matsBuf = [Float](repeating: 0, count: vH16) }
        matBuf.withUnsafeBufferPointer { raw in
        matsBuf.withUnsafeMutableBufferPointer { mats in
            let rp = raw.baseAddress!
            let mp = mats.baseAddress!
            let rows = rowCount
            for y in 0..<vH {
                let r = rows == 1 ? 0 : min(y &* rows / max(vH, 1), rows &- 1)
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

extension GyroFlowCore: GyroCoreProvider {}
