import Darwin
import Foundation
import QuartzCore  // CACurrentMediaTime

// MARK: - GyroConfig
/// All configurable parameters for gyroflow-core stabilization.
/// Serialized to JSON and passed to gyrocore_load() via config_json.
struct GyroConfig: Codable {
    var readoutMs:            Double = 0      // RS readout time; 0 = auto from metadata
    var smooth:               Double = 0      // Global smoothness; 0 = default 0.5
    var gyroOffsetMs:         Double = 0      // Gyro-video sync offset
    var integrationMethod:    Int    = 2      // 0=Complementary 1=Complementary2 2=VQF
    var imuOrientation:       String = "YXz"
    var fov:                  Double = 1.0    // FOV scale
    var lensCorrectionAmount: Double = 1.0    // 0.0–1.0
    var zoomingMethod:        Int    = 1      // 0=None 1=EnvelopeFollower
    var adaptiveZoom:         Double = 4.0    // Adaptive zoom window (seconds)
    var maxZoom:              Double = 130.0  // Max zoom percent
    var maxZoomIterations:    Int    = 5
    var useGravityVectors:    Bool   = false
    var videoSpeed:           Double = 1.0
    var horizonLockAmount:    Double = 0      // 0.0–1.0
    var horizonLockRoll:      Double = 0      // Degrees
    var perAxis:              Bool   = false
    var smoothnessPitch:      Double = 0      // 0 = use global
    var smoothnessYaw:        Double = 0
    var smoothnessRoll:       Double = 0

    enum CodingKeys: String, CodingKey {
        case readoutMs            = "readout_ms"
        case smooth
        case gyroOffsetMs         = "gyro_offset_ms"
        case integrationMethod    = "integration_method"
        case imuOrientation       = "imu_orientation"
        case fov
        case lensCorrectionAmount = "lens_correction_amount"
        case zoomingMethod        = "zooming_method"
        case adaptiveZoom         = "adaptive_zoom"
        case maxZoom              = "max_zoom"
        case maxZoomIterations    = "max_zoom_iterations"
        case useGravityVectors    = "use_gravity_vectors"
        case videoSpeed           = "video_speed"
        case horizonLockAmount    = "horizon_lock_amount"
        case horizonLockRoll      = "horizon_lock_roll"
        case perAxis              = "per_axis"
        case smoothnessPitch      = "smoothness_pitch"
        case smoothnessYaw        = "smoothness_yaw"
        case smoothnessRoll       = "smoothness_roll"
    }
}

// MARK: - GyroCore
//
// Gyroflow-core stabilization matrix engine.
// Loads libgyrocore_c.dylib via dlopen — same pattern as LibMPV.

final class GyroCore: @unchecked Sendable {

    // ── C function pointer types ──────────────────────────────────────────────
    private typealias FnLoad      = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias FnGetParams = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias FnGetFrame  = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnFree      = @convention(c) (UnsafeMutableRawPointer) -> Void

    // ── 公開元數據（loadCore 完成後設定，之後唯讀）────────────────────────────
    private(set) var frameCount:  Int    = 0
    private(set) var rowCount:    Int    = 1
    private(set) var gyroFx:      Float  = 0
    private(set) var gyroFy:      Float  = 0
    private(set) var gyroCx:      Float  = 0
    private(set) var gyroCy:      Float  = 0
    private(set) var gyroVideoW:  Float  = 0
    private(set) var gyroVideoH:  Float  = 0
    private(set) var gyroFps:     Double = 30

    // ── isReady（readyLock 保護跨執行緒讀寫）────────────────────────────────
    private var _isReady  = false
    private let readyLock = NSLock()
    var isReady: Bool {
        readyLock.lock(); defer { readyLock.unlock() }; return _isReady
    }

    // ── coreLock 保護 computeMatrix 與 stop() 並發 ──────────────────────────
    private let coreLock = NSLock()

    // ── 內部狀態 ──────────────────────────────────────────────────────────────
    // ioQueue 只用於 gyrocore_load 初始化（阻塞 ~0.3s）
    private let ioQueue   = DispatchQueue(label: "com.spectrum.gyrocore.init",
                                          qos: .userInteractive)
    private var libHandle:   UnsafeMutableRawPointer?
    private var coreHandle:  UnsafeMutableRawPointer?
    private var fnLoad:      FnLoad?
    private var fnGetParams: FnGetParams?
    private var fnGetFrame:  FnGetFrame?
    private var fnFree:      FnFree?

    /// 最近一次 gyrocore_get_frame FFI 的耗時（ms）
    private(set) var lastFetchMs: Double = 0

    // ── Pre-allocated buffers（loadCore 後大小固定）──────────────────────────
    private var rawBuf:  [Float] = []   // rowCount × 14
    private var matsBuf: [Float] = []   // vH × 16
    private var cachedFrameIdx: Int = -1

    // ── dylib 搜尋路徑 ────────────────────────────────────────────────────────

    /// 依序搜尋 libgyrocore_c.dylib；比照 MPVLib 的 dlopen 迴圈。
    private static let searchPaths: [String] = {
        var paths: [String] = []
        // 1. App bundle Resources/lib/ — 分發 / 沙盒安全路徑
        if let resPath = Bundle.main.resourcePath {
            paths.append("\(resPath)/lib/libgyrocore_c.dylib")
        }
        // 2. gyro-wrapper build — 本 repo 內的 Rust crate 建置產物
        if let srcRoot = Bundle.main.infoDictionary?["SOURCE_ROOT"] as? String {
            paths.append("\(srcRoot)/gyro-wrapper/target/release/libgyrocore_c.dylib")
        }
        // Also try relative to the executable (dev builds)
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let repoRoot = URL(fileURLWithPath: execDir).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        paths.append("\(repoRoot)/gyro-wrapper/target/release/libgyrocore_c.dylib")
        // 3. gyroflow workspace target — 直接從 Rust build 取得
        paths.append("\(NSHomeDirectory())/gyroflow/target/release/libgyrocore_c.dylib")
        return paths
    }()

    static var dylibPath: String? {
        searchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// dylib 是否可找到
    static var dylibFound: Bool { dylibPath != nil }

    /// 依影片 FPS 估算 Rolling Shutter readout time (ms)
    static func readoutMs(for fps: Double) -> Double {
        if fps >= 100 { return 8.0 }
        if fps >= 50  { return 15.0 }
        return 20.0
    }

    // ── 載入 dylib 並在背景執行 gyrocore_load ─────────────────────────────────

    func start(videoPath: String,
               lensPath:  String? = nil,
               config:    GyroConfig = GyroConfig(),
               onReady:   @Sendable @escaping () -> Void,
               onError:   @Sendable @escaping (String) -> Void) {
        guard let dylibPath = Self.dylibPath else {
            onError("libgyrocore_c.dylib 找不到")
            return
        }
        guard let lib = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL) else {
            onError("dlopen 失敗：\(String(cString: dlerror()))  (\(dylibPath))")
            return
        }
        libHandle = lib

        guard let s1 = dlsym(lib, "gyrocore_load"),
              let s2 = dlsym(lib, "gyrocore_get_params"),
              let s3 = dlsym(lib, "gyrocore_get_frame"),
              let s4 = dlsym(lib, "gyrocore_free") else {
            dlclose(lib); libHandle = nil
            onError("dlsym 失敗：找不到 gyrocore_* 符號")
            return
        }
        fnLoad      = unsafeBitCast(s1, to: FnLoad.self)
        fnGetParams = unsafeBitCast(s2, to: FnGetParams.self)
        fnGetFrame  = unsafeBitCast(s3, to: FnGetFrame.self)
        fnFree      = unsafeBitCast(s4, to: FnFree.self)

        ioQueue.async { [weak self] in
            self?.loadCore(videoPath: videoPath, lensPath: lensPath, config: config,
                           onReady: onReady, onError: onError)
        }
    }

    // MARK: - Private

    /// ioQueue 上執行：呼叫 gyrocore_load（阻塞 ~0.3s）→ 讀取參數 → 標記 ready
    private func loadCore(videoPath: String,
                          lensPath:  String?,
                          config:    GyroConfig,
                          onReady:   @Sendable @escaping () -> Void,
                          onError:   @Sendable @escaping (String) -> Void) {
        guard let fn = fnLoad else { onError("loadCore: fnLoad missing"); return }

        let lensDesc = lensPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
        let configJSON: String
        do {
            let data = try JSONEncoder().encode(config)
            configJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            configJSON = "{}"
        }
        print("[gyro] 載入 \(URL(fileURLWithPath: videoPath).lastPathComponent)  lens=\(lensDesc)  config=\(configJSON)")
        let handle: UnsafeMutableRawPointer?
        if let lp = lensPath {
            handle = videoPath.withCString { vp in lp.withCString { lpp in configJSON.withCString { cj in fn(vp, lpp, cj) } } }
        } else {
            handle = videoPath.withCString { vp in configJSON.withCString { cj in fn(vp, nil, cj) } }
        }
        guard let handle else { onError("gyrocore_load 失敗（無 gyro 資料？）"); return }
        coreHandle = handle

        // 讀取 40-byte params blob
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

        // Pre-allocate per-frame buffers to avoid allocation in render loop
        rawBuf  = [Float](repeating: 0, count: rowCount * 14)
        matsBuf = [Float](repeating: 0, count: Int(gyroVideoH) * 16)
        cachedFrameIdx = -1

        readyLock.lock(); _isReady = true; readyLock.unlock()
        print(String(format: "[gyro] ✅ Ready: %d 幀×%d 行  f=[%.1f,%.1f]  c=[%.1f,%.1f]  %dx%d@%.3ffps",
                     frameCount, rowCount, gyroFx, gyroFy, gyroCx, gyroCy,
                     Int(gyroVideoW), Int(gyroVideoH), gyroFps))
        DispatchQueue.main.async { onReady() }
    }

    // MARK: - Per-frame matrix (synchronous, ~0.5ms)

    /// 同步計算 frameIdx 的矩陣，展開為 vH×16 floats（RGBA32F texture format, width=4）。
    /// 每行 4 texels: [mat3×3 + IBIS sx/sy/ra + OIS ox/oy]
    /// render thread 呼叫；coreLock 保護與 stop() 的並發。
    ///
    /// Returns (matsBuf, changed) — `changed` 為 false 表示與上次相同 frameIdx，
    /// 呼叫端可跳過 texture upload。matsBuf 指向內部 buffer，下次呼叫前有效。
    func computeMatrix(frameIdx: Int) -> (UnsafeBufferPointer<Float>, Bool)? {
        guard isReady else { return nil }
        coreLock.lock(); defer { coreLock.unlock() }
        guard let handle = coreHandle, let fn = fnGetFrame else { return nil }

        // Cache hit — same frame, reuse existing matsBuf
        if frameIdx == cachedFrameIdx {
            lastFetchMs = 0
            return matsBuf.withUnsafeBufferPointer { ($0, false) }
        }

        let rawLen = rowCount * 14
        let t0 = CACurrentMediaTime()
        let result = rawBuf.withUnsafeMutableBufferPointer {
            fn(handle, UInt32(frameIdx), $0.baseAddress!)
        }
        lastFetchMs = (CACurrentMediaTime() - t0) * 1000
        guard result == Int32(rawLen) else { return nil }

        // 展開 rowCount×14 → vH×16 floats (matTex width=4, RGBA32F)
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

    // MARK: - Stop

    func stop() {
        readyLock.lock(); _isReady = false; readyLock.unlock()
        ioQueue.sync { }   // 等待 loadCore 執行完畢
        coreLock.lock()
        if let handle = coreHandle, let fn = fnFree { fn(handle) }
        coreHandle = nil
        coreLock.unlock()
        if let lib = libHandle { dlclose(lib) }
        libHandle = nil
    }
}
