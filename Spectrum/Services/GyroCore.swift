import Darwin
import Foundation
import QuartzCore  // CACurrentMediaTime

// MARK: - GyroCore
//
// Gyroflow-core stabilization matrix engine (one-shot API).
// Loads libgyrocore_c.dylib via dlopen.

final class GyroCore: @unchecked Sendable {

    // ── C function pointer types ──────────────────────────────────────────────
    private typealias FnLoad           = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias FnCancelLoad     = @convention(c) () -> Void
    private typealias FnLoadProgress   = @convention(c) () -> Double
    private typealias FnGetParams      = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias FnGetFrame    = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnGetFrameTs  = @convention(c) (UnsafeMutableRawPointer, Double, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnGetLens     = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    private typealias FnFree        = @convention(c) (UnsafeMutableRawPointer) -> Void

    // ── Public metadata (set after loadCore completes, read-only thereafter) ──
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
    /// Lens profile filename used for loading (empty = none / auto).
    private(set) var lensProfileName: String = ""

    // ── isReady (readyLock guards cross-thread read/write) ─────────────────
    private var _isReady  = false
    private let readyLock = NSLock()
    var isReady: Bool {
        readyLock.lock(); defer { readyLock.unlock() }; return _isReady
    }

    // ── coreLock guards concurrency between computeMatrix and stop() ───────
    private let coreLock = NSLock()

    // ── Internal state ────────────────────────────────────────────────────────
    // ioQueue is only used for gyrocore_load initialization (blocks ~0.3s)
    private let ioQueue   = DispatchQueue(label: "com.spectrum.gyrocore.init",
                                          qos: .userInteractive)
    private var libHandle:   UnsafeMutableRawPointer?
    private var coreHandle:  UnsafeMutableRawPointer?
    private var fnLoad:          FnLoad?
    private var fnCancelLoad:    FnCancelLoad?
    private var fnLoadProgress:  FnLoadProgress?
    private var fnGetParams:     FnGetParams?
    private var fnGetFrame:    FnGetFrame?
    private var fnGetFrameTs:  FnGetFrameTs?
    private var fnGetLens:     FnGetLens?
    private var fnFree:        FnFree?

    /// Duration of the most recent gyrocore_get_frame FFI call (ms)
    private(set) var lastFetchMs: Double = 0


    // ── Pre-allocated buffers (size fixed after loadCore) ──────────────────
    private var rawBuf:  [Float] = []   // rowCount × 14 + 8 (per-frame params appended)
    private var matsBuf: [Float] = []   // vH × 16
    private var cachedFrameIdx: Int = -1
    // Per-frame lens params (updated each computeMatrix call)
    private(set) var frameFx: Float = 0
    private(set) var frameFy: Float = 0
    private(set) var frameCx: Float = 0
    private(set) var frameCy: Float = 0
    private(set) var frameK: [Float] = [0, 0, 0, 0]
    private(set) var frameFov: Float = 1.0
    /// FOV range over recent frames (for adaptive zoom breathing diagnosis).
    private(set) var fovMin: Float = 1.0
    private(set) var fovMax: Float = 1.0
    private var fovHistory: [Float] = []
    /// Lens correction amount from config (matches gyroflow-core's auto-zoom).
    private(set) var lensCorrectionAmount: Float = 1.0

    // ── dylib search paths ────────────────────────────────────────────────────

    /// Search for libgyrocore_c.dylib in order.
    private static let searchPaths: [String] = {
        var paths: [String] = []
        // 1. App bundle Resources/lib/ — distribution / sandbox-safe path
        if let resPath = Bundle.main.resourcePath {
            paths.append("\(resPath)/lib/libgyrocore_c.dylib")
        }
        // 2. gyro-wrapper build — Rust crate build artifact within this repo
        if let srcRoot = Bundle.main.infoDictionary?["SOURCE_ROOT"] as? String {
            paths.append("\(srcRoot)/gyro-wrapper/target/release/libgyrocore_c.dylib")
        }
        // Also try relative to the executable (dev builds)
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let repoRoot = URL(fileURLWithPath: execDir).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        paths.append("\(repoRoot)/gyro-wrapper/target/release/libgyrocore_c.dylib")
        // 3. gyroflow workspace target — directly from Rust build output
        paths.append("\(NSHomeDirectory())/gyroflow/target/release/libgyrocore_c.dylib")
        return paths
    }()

    static var dylibPath: String? {
        searchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether the dylib can be found
    static var dylibFound: Bool { dylibPath != nil }

    /// Estimate Rolling Shutter readout time (ms) based on video FPS
    static func readoutMs(for fps: Double) -> Double {
        if fps >= 100 { return 8.0 }
        if fps >= 50  { return 15.0 }
        return 20.0
    }

    deinit {
        // Safety net: if stop() was never called (e.g. onError path sets
        // activeGyroCore = nil without calling stop()), clean up resources.
        if coreHandle != nil || libHandle != nil {
            if let handle = coreHandle, let fn = fnFree { fn(handle) }
            coreHandle = nil
            if let lib = libHandle { dlclose(lib) }
            libHandle = nil
        }
    }

    // ── Load dylib and run gyrocore_load in background ────────────────────────

    func start(videoPath: String,
               lensPath:  String? = nil,
               config:    GyroConfig = GyroConfig(),
               onReady:   @Sendable @escaping () -> Void,
               onError:   @Sendable @escaping (String) -> Void) {
        guard let dylibPath = Self.dylibPath else {
            onError("libgyrocore_c.dylib not found")
            return
        }
        guard let lib = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL) else {
            onError("dlopen failed: \(String(cString: dlerror()))  (\(dylibPath))")
            return
        }
        libHandle = lib

        guard let s1 = dlsym(lib, "gyrocore_load"),
              let s2 = dlsym(lib, "gyrocore_get_params"),
              let s3 = dlsym(lib, "gyrocore_get_frame"),
              let s4 = dlsym(lib, "gyrocore_free") else {
            dlclose(lib); libHandle = nil
            onError("dlsym failed: gyrocore_* symbols not found")
            return
        }
        fnLoad      = unsafeBitCast(s1, to: FnLoad.self)
        fnGetParams = unsafeBitCast(s2, to: FnGetParams.self)
        fnGetFrame  = unsafeBitCast(s3, to: FnGetFrame.self)
        fnFree      = unsafeBitCast(s4, to: FnFree.self)
        // Optional: cancellation + progress support (added in newer dylib builds)
        if let sCancel = dlsym(lib, "gyrocore_cancel_load") {
            fnCancelLoad = unsafeBitCast(sCancel, to: FnCancelLoad.self)
        }
        if let sProg = dlsym(lib, "gyrocore_load_progress") {
            fnLoadProgress = unsafeBitCast(sProg, to: FnLoadProgress.self)
        }
        // Optional: timestamp-based frame query (eliminates frame-index quantization error)
        if let s5ts = dlsym(lib, "gyrocore_get_frame_at_ts") {
            fnGetFrameTs = unsafeBitCast(s5ts, to: FnGetFrameTs.self)
        }
        // Optional: lens info query (may be absent in older dylib builds)
        if let s5 = dlsym(lib, "gyrocore_get_lens_info") {
            fnGetLens = unsafeBitCast(s5, to: FnGetLens.self)
        }

        ioQueue.async { [weak self] in
            self?.loadCore(videoPath: videoPath, lensPath: lensPath, config: config,
                           onReady: onReady, onError: onError)
        }
    }

    /// Current gyro-data parse progress: 0.0–1.0 while loading, -1.0 when idle/done.
    var loadProgress: Double { fnLoadProgress?() ?? -1.0 }

    // MARK: - Private

    /// Runs on ioQueue: calls gyrocore_load (blocks ~0.3s) -> reads params -> marks ready
    private func loadCore(videoPath: String,
                          lensPath:  String?,
                          config:    GyroConfig,
                          onReady:   @Sendable @escaping () -> Void,
                          onError:   @Sendable @escaping (String) -> Void) {
        guard let fn = fnLoad else { DispatchQueue.main.async { onError("loadCore: fnLoad missing") }; return }

        let lensDesc = lensPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
        lensProfileName = lensDesc
        let configJSON: String
        do {
            let data = try JSONEncoder().encode(config)
            configJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            configJSON = "{}"
        }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let pretty = String(data: try enc.encode(config), encoding: .utf8) ?? "{}"
            Log.gyro.debug("Loading \(URL(fileURLWithPath: videoPath).lastPathComponent, privacy: .public)  lens=\(lensDesc, privacy: .public)\nconfig:\n\(pretty, privacy: .public)")
        } catch {
            Log.gyro.debug("Loading \(URL(fileURLWithPath: videoPath).lastPathComponent, privacy: .public)  lens=\(lensDesc, privacy: .public)  config=\(configJSON, privacy: .public)")
        }
        let handle: UnsafeMutableRawPointer?
        if let lp = lensPath {
            handle = videoPath.withCString { vp in lp.withCString { lpp in configJSON.withCString { cj in fn(vp, lpp, cj) } } }
        } else {
            handle = videoPath.withCString { vp in configJSON.withCString { cj in fn(vp, nil, cj) } }
        }
        guard let handle else {
            Log.gyro.warning("[gyro] gyrocore_load returned nil for \(URL(fileURLWithPath: videoPath).lastPathComponent, privacy: .public) — no embedded gyro data or unsupported format")
            DispatchQueue.main.async { onError("gyrocore_load failed (no gyro data?)") }
            return
        }
        coreHandle = handle

        // Read 96-byte params blob
        var buf = Data(count: 96)
        let rc = buf.withUnsafeMutableBytes { ptr in
            fnGetParams?(handle, ptr.baseAddress!) ?? -1
        }
        guard rc == 0 else { DispatchQueue.main.async { onError("gyrocore_get_params failed") }; return }

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
        Log.gyro.debug("distortion_model=\(self.distortionModel) k=[\(self.distortionK[0]),\(self.distortionK[1]),\(self.distortionK[2]),\(self.distortionK[3])] r_limit=\(self.rLimit)")

        // Store lens correction amount so the shader can match gyroflow-core's pipeline.
        lensCorrectionAmount = Float(config.lensCorrectionAmount)

        // Query lens profile name from gyroflow-core
        if let fn = fnGetLens, let h = coreHandle {
            var lbuf = [UInt8](repeating: 0, count: 256)
            let len = fn(h, &lbuf, 256)
            if len > 0, let str = String(bytes: lbuf.prefix(Int(len)), encoding: .utf8) {
                lensProfileName = str
            }
        }
        Log.gyro.debug("lens_profile: \(self.lensProfileName, privacy: .public)")

        // Pre-allocate per-frame buffers to avoid allocation in render loop
        rawBuf  = [Float](repeating: 0, count: rowCount * 14 + 9)
        matsBuf = [Float](repeating: 0, count: Int(gyroVideoH) * 16)
        cachedFrameIdx = -1

        guard frameCount > 0 else {
            Log.gyro.warning("gyrocore_load succeeded but frameCount=0 — no usable gyro data")
            if let handle = coreHandle, let fn = fnFree { fn(handle) }
            coreHandle = nil
            DispatchQueue.main.async { onError("No gyro data (0 frames)") }
            return
        }

        readyLock.lock(); _isReady = true; readyLock.unlock()
        Log.gyro.info("Ready: \(self.frameCount) frames x \(self.rowCount) rows  f=[\(self.gyroFx),\(self.gyroFy)]  c=[\(self.gyroCx),\(self.gyroCy)]  \(Int(self.gyroVideoW))x\(Int(self.gyroVideoH))@\(String(format:"%.3f",self.gyroFps))fps")
        DispatchQueue.main.async { onReady() }
    }

    // MARK: - Per-frame matrix (synchronous, ~0.5ms)

    /// Synchronously compute matrices for frameIdx, expanded to vH x 16 floats (RGBA32F texture format, width=4).
    /// Each row = 4 texels: [mat3x3 + IBIS sx/sy/ra + OIS ox/oy]
    /// Called from render thread; coreLock guards concurrency with stop().
    ///
    /// Returns (matsBuf, changed) -- `changed` is false when frameIdx matches the previous call,
    /// so the caller can skip texture upload. matsBuf points to an internal buffer, valid until the next call.
    func computeMatrix(frameIdx: Int) -> (UnsafeBufferPointer<Float>, Bool)? {
        guard isReady else { return nil }
        coreLock.lock(); defer { coreLock.unlock() }
        guard let handle = coreHandle, let fn = fnGetFrame else { return nil }

        // Cache hit — same frame, reuse existing matsBuf
        if frameIdx == cachedFrameIdx {
            lastFetchMs = 0
            return matsBuf.withUnsafeBufferPointer { ($0, false) }
        }

        let expectedLen = rowCount * 14 + 9  // matrices + per-frame params (f,c,k,fov)
        let t0 = CACurrentMediaTime()
        let result = rawBuf.withUnsafeMutableBufferPointer {
            fn(handle, UInt32(frameIdx), $0.baseAddress!)
        }
        lastFetchMs = (CACurrentMediaTime() - t0) * 1000
        guard result == Int32(expectedLen) else {
            Log.gyro.error("[gyro] computeMatrix frameIdx=\(frameIdx): expected \(expectedLen) floats but got \(result) — ABI mismatch?")
            return nil
        }

        // Extract per-frame lens params (appended after matrices)
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

        // Track FOV range over recent frames (rolling window of 120 samples)
        fovHistory.append(frameFov)
        if fovHistory.count > 120 { fovHistory.removeFirst() }
        fovMin = fovHistory.min() ?? frameFov
        fovMax = fovHistory.max() ?? frameFov

        // Expand rowCount x 14 -> vH x 16 floats (matTex width=4, RGBA32F)
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
        cachedFrameIdx = frameIdx
        return matsBuf.withUnsafeBufferPointer { ($0, true) }
    }

    // MARK: - Per-frame matrix at timestamp (continuous, no quantization)

    /// Like computeMatrix but takes a continuous timestamp (seconds) instead of a
    /// discrete frame index. This eliminates the ~8ms quantization error from
    /// frame-index rounding, improving rolling-shutter correction accuracy.
    ///
    /// Falls back to computeMatrix(frameIdx:) if the timestamp-based FFI is unavailable.
    func computeMatrixAtTime(timeSec: Double) -> (UnsafeBufferPointer<Float>, Bool)? {
        guard isReady else { return nil }
        coreLock.lock(); defer { coreLock.unlock() }
        guard let handle = coreHandle else { return nil }

        // Compute frame index for cache/repeat detection
        let fi = max(0, min(Int((timeSec * gyroFps).rounded()), frameCount - 1))

        // Cache hit — same frame, reuse existing matsBuf
        if fi == cachedFrameIdx {
            lastFetchMs = 0
            return matsBuf.withUnsafeBufferPointer { ($0, false) }
        }

        // Prefer timestamp-based API; fall back to frame-index API
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
        guard result == Int32(expectedLen) else {
            Log.gyro.error("[gyro] computeMatrixAtTime ts=\(String(format:"%.3f",timeSec))s: expected \(expectedLen) floats but got \(result) — ABI mismatch?")
            return nil
        }

        // Extract per-frame lens params (appended after matrices)
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

        // Track FOV range over recent frames (rolling window of 120 samples)
        fovHistory.append(frameFov)
        if fovHistory.count > 120 { fovHistory.removeFirst() }
        fovMin = fovHistory.min() ?? frameFov
        fovMax = fovHistory.max() ?? frameFov

        // Expand rowCount x 14 -> vH x 16 floats (matTex width=4, RGBA32F)
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

    // MARK: - Stop

    func stop() {
        Log.debug(Log.gyro, "[gyro] stop() — cancelling & scheduling cleanup")
        readyLock.lock(); _isReady = false; readyLock.unlock()
        // Signal the in-progress gyrocore_load() to abort as soon as possible.
        fnCancelLoad?()
        // Dispatch cleanup onto ioQueue so it runs AFTER loadCore finishes naturally.
        // Using [self] keeps GyroCore alive until the block finishes — no blocking on caller.
        ioQueue.async { [self] in
            coreLock.lock()
            if let handle = coreHandle, let fn = fnFree { fn(handle) }
            coreHandle = nil
            coreLock.unlock()
            if let lib = libHandle { dlclose(lib) }
            libHandle = nil
            Log.debug(Log.gyro, "[gyro] cleanup done")
        }
    }
}

extension GyroCore: GyroCoreProvider {}
