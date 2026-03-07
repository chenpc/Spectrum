// testavf — AVFoundation + Metal HDR video player test + Gyro stabilization
//
// Pipeline: AVPlayer -> AVPlayerItemVideoOutput -> CVMetalTextureCache -> CAMetalLayer
// Pass 1: CVPixelBuffer (YCbCr 10-bit) -> Metal shader (BT.2020 YCbCr->RGB) -> offscreen RGBA16Float
// Pass 2: Warp shader (gyro stabilization) -> drawable (or direct blit if no gyro)
//
// Build: bash build.sh
// Run:   ./testavf /path/to/video.mp4

import Cocoa
import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import QuartzCore

setbuf(stdout, nil)

// MARK: - Dolby Vision RPU Parser

/// Minimal bitstream reader (MSB-first).
private class BitReader {
    private let data: [UInt8]
    private(set) var pos: Int = 0  // current bit position
    var bitsLeft: Int { data.count * 8 - pos }

    init(_ data: [UInt8]) { self.data = data }

    func read(_ n: Int) -> UInt {
        var v: UInt = 0
        for _ in 0..<n {
            let byteIdx = pos >> 3, bitIdx = 7 - (pos & 7)
            if byteIdx < data.count { v = (v << 1) | UInt((data[byteIdx] >> bitIdx) & 1) }
            pos += 1
        }
        return v
    }
    func bool() -> Bool { read(1) == 1 }
    func signed(_ n: Int) -> Int {
        let v = read(n)
        let sign = 1 << (n - 1)
        return Int(v & UInt(sign - 1)) - ((v & UInt(sign)) != 0 ? sign : 0)
    }
    /// Exp-Golomb unsigned.
    func ue() -> UInt {
        var zeros = 0
        while !bool() && bitsLeft > 0 { zeros += 1 }
        if zeros == 0 { return 0 }
        return (1 << zeros) - 1 + read(zeros)
    }
}

/// Parsed DV RPU Display Management Level 1 metadata.
struct DVRPUL1 {
    var minPQ: UInt = 0   // 12-bit PQ code
    var maxPQ: UInt = 0
    var avgPQ: UInt = 0
    var minNits: Double { pqToNits(Double(minPQ) / 4095.0) }
    var maxNits: Double { pqToNits(Double(maxPQ) / 4095.0) }
    var avgNits: Double { pqToNits(Double(avgPQ) / 4095.0) }
}

/// Parsed DV RPU header + DM metadata.
struct DVRPUInfo {
    var rpuType: UInt = 0
    var rpuFormat: UInt = 0
    var profile: UInt = 0
    var level: UInt = 0
    var blBitDepth: UInt = 0
    var elBitDepth: UInt = 0
    var vdrBitDepth: UInt = 0
    var blFullRange: Bool = false
    var disableResidual: Bool = false
    var dmPresent: Bool = false
    var l1: DVRPUL1?
    var numComponents: Int = 0
    var numPivots: [Int] = []
}

/// PQ code (0..1) to nits.
private func pqToNits(_ pq: Double) -> Double {
    let m1 = 0.1593017578125, m2 = 78.84375
    let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
    let p = pow(pq, 1.0 / m2)
    let v = max(p - c1, 0.0) / (c2 - c3 * p)
    return 10000.0 * pow(v, 1.0 / m1)
}

/// Parse DV RPU data from CVPixelBuffer attachment.
func parseDVRPU(_ data: Data) -> DVRPUInfo? {
    var bytes = [UInt8](data)
    // Strip prefix byte (0x19 for AV1/Apple, 0x7C01 for HEVC NAL)
    if bytes.first == 0x19 { bytes.removeFirst() }
    else if bytes.count >= 2 && bytes[0] == 0x7C && bytes[1] == 0x01 { bytes.removeFirst(2) }

    // RBSP unescape: 0x00 0x00 0x03 → 0x00 0x00
    var unesc = [UInt8]()
    unesc.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        if i + 2 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 3 {
            unesc.append(0); unesc.append(0); i += 3
        } else {
            unesc.append(bytes[i]); i += 1
        }
    }
    // Strip trailing CRC32 (last 4 bytes) + 0x80 end marker
    if unesc.count > 5 { unesc.removeLast(5) }

    // Hex dump first 32 bytes for debugging
    let hexDump = unesc.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
    print("[RPU] hex(\(unesc.count)B): \(hexDump)")

    let br = BitReader(unesc)
    var info = DVRPUInfo()

    // --- RPU header ---
    info.rpuType = br.read(6)
    info.rpuFormat = br.read(11)
    info.profile = br.read(4)
    info.level = br.read(4)
    print("[RPU] @bit\(br.pos): type=\(info.rpuType) fmt=\(info.rpuFormat) profile=\(info.profile) level=\(info.level)")

    let seqPresent = br.bool()
    print("[RPU] @bit\(br.pos): seqPresent=\(seqPresent)")
    if seqPresent {
        let chromaFilter = br.bool()
        let coefDataType = br.read(2)
        print("[RPU] @bit\(br.pos): chromaFilter=\(chromaFilter) coefDataType=\(coefDataType)")
        if coefDataType == 0 {
            let coefDenom = br.ue()
            print("[RPU] @bit\(br.pos): coef_log2_denom=\(coefDenom)")
        }
        if coefDataType == 1 { _ = br.read(4) }
        let normIdc = br.read(2)
        info.blFullRange = br.bool()
        print("[RPU] @bit\(br.pos): normIdc=\(normIdc) blFullRange=\(info.blFullRange)")

        if info.rpuFormat >= 18 {
            info.blBitDepth = br.read(4) + 8
            info.elBitDepth = br.read(4) + 8
            info.vdrBitDepth = br.read(4) + 8
            let spatialResamp = br.bool()
            let reserved = br.read(3)
            let elSpatialResamp = br.bool()
            info.disableResidual = br.bool()
            print("[RPU] @bit\(br.pos): BL=\(info.blBitDepth)bit EL=\(info.elBitDepth)bit VDR=\(info.vdrBitDepth)bit disRes=\(info.disableResidual)")
        }
    }

    info.dmPresent = br.bool()
    let usePrev = br.bool()
    print("[RPU] @bit\(br.pos): dmPresent=\(info.dmPresent) usePrev=\(usePrev)")

    guard !usePrev, br.bitsLeft > 64 else { return info }

    // --- Mapping curves (must parse to skip past them) ---
    let coefLog2DenomLen: Int
    // Re-read coef info — we need it for coefficient sizes
    // Actually we already skipped past it. For type 0, each coefficient is:
    //   signed(coef_log2_denom_length) + unsigned(coef_log2_denom)
    // For simplicity, re-parse from a known position by re-reading the header.
    // Instead, let's use the bit depths to estimate.

    // For profile 8, coefficient_data_type is typically 0.
    // We need to know coef_log2_denom_length to know coefficient bit width.
    // Let's re-parse just the coef info.
    let br2 = BitReader(unesc)
    _ = br2.read(6 + 11 + 4 + 4)  // skip header
    let seq2 = br2.bool()
    var coefDenomLen: UInt = 0
    var coefType: UInt = 0
    if seq2 {
        _ = br2.bool()
        coefType = br2.read(2)
        if coefType == 0 { coefDenomLen = br2.ue() }
    }
    let coefBits = Int(coefDenomLen) + (coefType == 0 ? Int(1 << coefDenomLen) >> 1 : 0)

    // Parse mapping curves for 3 components
    let blBits = Int(info.blBitDepth)
    let mappingBits = blBits  // pivot values are BL bit depth
    for cmp in 0..<3 {
        guard br.bitsLeft > 16 else { break }
        let numPivots = Int(br.ue()) + 2
        info.numPivots.append(numPivots)
        for _ in 0..<numPivots { _ = br.read(blBits) }  // pivot values
        let numMappings = numPivots - 1
        for _ in 0..<numMappings {
            let mappingIdc = br.read(2)
            if mappingIdc == 0 {  // Polynomial
                let polyOrder = Int(br.ue()) + 1
                var linearInterp = false
                if polyOrder == 1 { linearInterp = br.bool() }
                if !linearInterp {
                    for _ in 0...polyOrder {
                        // Read coefficient: signed int part + fractional part
                        if coefType == 0 {
                            _ = br.signed(Int(coefDenomLen) + 1)
                            let fracBits = Int((1 << coefDenomLen) >> 1)
                            if fracBits > 0 { _ = br.read(fracBits) }
                        }
                    }
                }
            } else if mappingIdc == 1 {  // MMR
                let mmrOrder = Int(br.read(2)) + 1
                // constant
                if coefType == 0 {
                    _ = br.signed(Int(coefDenomLen) + 1)
                    let fracBits = Int((1 << coefDenomLen) >> 1)
                    if fracBits > 0 { _ = br.read(fracBits) }
                }
                for _ in 0..<mmrOrder {
                    for _ in 0..<7 {
                        if coefType == 0 {
                            _ = br.signed(Int(coefDenomLen) + 1)
                            let fracBits = Int((1 << coefDenomLen) >> 1)
                            if fracBits > 0 { _ = br.read(fracBits) }
                        }
                    }
                }
            }
        }
        info.numComponents = cmp + 1
    }
    print("[RPU] Parsed \(info.numComponents) component mappings, pivots=\(info.numPivots)")

    // --- NLQ (non-linear quantization) — only if !disable_residual ---
    // For P8.4 disable_residual is typically true, skip.

    // --- DM metadata ---
    guard info.dmPresent, br.bitsLeft > 48 else { return info }

    let affectedDmId = br.ue()
    let currentDmId = br.ue()
    let sceneRefresh = br.ue()
    print("[RPU] DM: affectedId=\(affectedDmId) currentId=\(currentDmId) sceneRefresh=\(sceneRefresh)")

    // Parse ext_metadata blocks
    // num_ext_blocks: ue(v)
    guard br.bitsLeft > 8 else { return info }
    let numExtBlocks = br.ue()
    // byte_align
    let align = br.pos % 8
    if align != 0 { _ = br.read(8 - align) }

    print("[RPU] numExtBlocks=\(numExtBlocks)")

    for blk in 0..<Int(numExtBlocks) {
        guard br.bitsLeft > 16 else { break }
        let extBlockLen = br.ue()  // in bytes
        let extBlockLevel = br.read(8)
        let dataBytes = Int(extBlockLen) - 1  // minus 1 for level byte
        let dataBits = dataBytes * 8

        print("[RPU]   block[\(blk)]: level=\(extBlockLevel) len=\(extBlockLen) dataBits=\(dataBits)")

        if extBlockLevel == 1 && dataBits >= 36 {
            // L1: min_PQ(12), max_PQ(12), avg_PQ(12)
            var l1 = DVRPUL1()
            l1.minPQ = br.read(12)
            l1.maxPQ = br.read(12)
            l1.avgPQ = br.read(12)
            info.l1 = l1
            print(String(format: "[RPU]   L1: minPQ=%d (%.1f nits)  maxPQ=%d (%.1f nits)  avgPQ=%d (%.1f nits)",
                         l1.minPQ, l1.minNits, l1.maxPQ, l1.maxNits, l1.avgPQ, l1.avgNits))
            // skip remaining bits if any
            let remaining = dataBits - 36
            if remaining > 0 { _ = br.read(remaining) }
        } else if extBlockLevel == 2 && dataBits >= 96 {
            // L2: target display
            let targetMaxPQ = br.read(12)
            let targetMinPQ = br.read(12)
            let trimSlope = br.read(12)
            let trimOffset = br.read(12)
            let trimPower = br.read(12)
            let trimChromaWeight = br.read(12)
            let trimSatGain = br.read(12)
            let msWeight = br.read(13) // signed 13-bit
            print(String(format: "[RPU]   L2: targetMax=%d (%.0f nits)  targetMin=%d  slope=%d  offset=%d  power=%d",
                         targetMaxPQ, pqToNits(Double(targetMaxPQ) / 4095.0),
                         targetMinPQ, trimSlope, trimOffset, trimPower))
            let remaining = dataBits - 97
            if remaining > 0 { _ = br.read(remaining) }
        } else if extBlockLevel == 5 && dataBits >= 56 {
            // L5: active area
            let left = br.read(13)
            let right = br.read(13)
            let top = br.read(13)
            let bottom = br.read(13)
            print("[RPU]   L5: activeArea L=\(left) R=\(right) T=\(top) B=\(bottom)")
            let remaining = dataBits - 52
            if remaining > 0 { _ = br.read(remaining) }
        } else if extBlockLevel == 6 && dataBits >= 64 {
            // L6: MaxCLL / MaxFALL
            let maxCLL = br.read(16)
            let maxFALL = br.read(16)
            print("[RPU]   L6: MaxCLL=\(maxCLL) nits  MaxFALL=\(maxFALL) nits")
            let remaining = dataBits - 32
            if remaining > 0 { _ = br.read(remaining) }
        } else {
            // Skip unknown levels
            if dataBits > 0 { _ = br.read(dataBits) }
        }
    }

    return info
}

// MARK: - Display peak nits

func displayPeakNits() -> Int {
    typealias FnCreateInfo = @convention(c) (UInt32) -> CFDictionary?
    guard let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
          let sym = dlsym(cd, "CoreDisplay_DisplayCreateInfoDictionary") else { return 400 }
    let fn = unsafeBitCast(sym, to: FnCreateInfo.self)
    guard let dict = fn(CGMainDisplayID()) as? [String: Any] else { return 400 }
    if let v = dict["NonReferencePeakHDRLuminance"] as? Int { return v }
    if let v = dict["DisplayBacklight"] as? Int { return v }
    return 400
}

// MARK: - Video Info

struct VideoInfo {
    var width: Int = 0
    var height: Int = 0
    var codec: String = "-"
    var fps: Double = 0
    var duration: Double = 0
    var transferFunction: String = "-"
    var colorPrimaries: String = "-"
    var matrix: String = "-"
    var bitDepth: Int = 8
    var fullRange: Bool = false
    var isHDR: Bool = false
    var isHLG: Bool = false
    var isDolbyVision: Bool = false
    var dvProfile: Int = 0
}

func analyzeVideo(asset: AVAsset) -> VideoInfo {
    var info = VideoInfo()
    info.duration = CMTimeGetSeconds(asset.duration)
    guard let track = asset.tracks(withMediaType: .video).first else { return info }
    info.width = Int(track.naturalSize.width)
    info.height = Int(track.naturalSize.height)
    info.fps = Double(track.nominalFrameRate)

    for desc in track.formatDescriptions {
        let fd = desc as! CMFormatDescription
        let fourCC = CMFormatDescriptionGetMediaSubType(fd)
        let chars: [Character] = [
            Character(UnicodeScalar((fourCC >> 24) & 0xFF)!),
            Character(UnicodeScalar((fourCC >> 16) & 0xFF)!),
            Character(UnicodeScalar((fourCC >> 8) & 0xFF)!),
            Character(UnicodeScalar(fourCC & 0xFF)!),
        ]
        info.codec = String(chars)

        // Extract bit depth from format description
        if let bitsPerComponent = CMFormatDescriptionGetExtension(fd,
                extensionKey: "BitsPerComponent" as CFString) {
            info.bitDepth = bitsPerComponent as! Int
        }
        if let fullRange = CMFormatDescriptionGetExtension(fd,
                extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) {
            info.fullRange = (fullRange as! NSNumber).boolValue
        }

        if let exts = CMFormatDescriptionGetExtensions(fd) as? [String: Any] {
            print("[AVF] FormatDescription extensions:")
            for (key, value) in exts.sorted(by: { $0.key < $1.key }) {
                let valStr = "\(value)".prefix(120)
                print("[AVF]   \(key) = \(valStr)")
            }

            let tfKey = kCMFormatDescriptionExtension_TransferFunction as String
            let cpKey = kCMFormatDescriptionExtension_ColorPrimaries as String
            let mxKey = kCMFormatDescriptionExtension_YCbCrMatrix as String

            if let tf = (exts["CVImageBufferTransferFunction"] ?? exts[tfKey]) as? String {
                info.transferFunction = tf
                if tf.contains("HLG") || tf.contains("ARIB") { info.isHLG = true; info.isHDR = true }
                if tf.contains("2084") || tf.contains("PQ") { info.isHDR = true }
            }
            if let cp = (exts["CVImageBufferColorPrimaries"] ?? exts[cpKey]) as? String {
                info.colorPrimaries = cp
            }
            if let mx = (exts["CVImageBufferYCbCrMatrix"] ?? exts[mxKey]) as? String {
                info.matrix = mx
            }

            // Dolby Vision detection
            if let atoms = exts["SampleDescriptionExtensionAtoms"] as? [String: Any] {
                if let dvcC = atoms["dvcC"] as? Data {
                    info.isDolbyVision = true; info.isHDR = true
                    if dvcC.count >= 3 { info.dvProfile = Int(dvcC[2] >> 1); print("[AVF]   DV profile=\(info.dvProfile) (from dvcC)") }
                }
                if let dvvC = atoms["dvvC"] as? Data {
                    info.isDolbyVision = true; info.isHDR = true
                    if dvvC.count >= 3 { info.dvProfile = Int(dvvC[2] >> 1); print("[AVF]   DV profile=\(info.dvProfile) (from dvvC)") }
                }
            }
        }
    }
    return info
}

// ════════════════════════════════════════════════════════
// MARK: - GyroConfig + GyroCore + GyroCoreProvider
// ════════════════════════════════════════════════════════

struct GyroConfig: Codable {
    var readoutMs:            Double = 0
    var smooth:               Double = 0
    var gyroOffsetMs:         Double = 0
    var integrationMethod:    Int?   = nil
    var imuOrientation:       String? = nil
    var fov:                  Double = 1.0
    var lensCorrectionAmount: Double = 1.0
    var zoomingMethod:        Int    = 1
    var zoomingAlgorithm:     Int    = 1
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

class GyroCore: GyroCoreProvider {
    private typealias FnLoad       = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias FnGetParams  = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias FnGetFrame   = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnGetFrameTs = @convention(c) (UnsafeMutableRawPointer, Double, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnFree       = @convention(c) (UnsafeMutableRawPointer) -> Void

    private(set) var frameCount: Int = 0
    private(set) var rowCount: Int = 1
    private(set) var gyroVideoW: Float = 0
    private(set) var gyroVideoH: Float = 0
    private(set) var gyroFps: Double = 30
    private(set) var distortionK: [Float] = [Float](repeating: 0, count: 12)
    private(set) var distortionModel: Int32 = 0
    private(set) var rLimit: Float = 0
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
    private let ioQueue = DispatchQueue(label: "gyrocore.init", qos: .userInteractive)
    private var libHandle: UnsafeMutableRawPointer?
    private var coreHandle: UnsafeMutableRawPointer?
    private var fnLoad: FnLoad?
    private var fnGetParams: FnGetParams?
    private var fnGetFrame: FnGetFrame?
    private var fnGetFrameTs: FnGetFrameTs?
    private var fnFree: FnFree?
    private var rawBuf: [Float] = []
    private var matsBuf: [Float] = []
    private var cachedFrameIdx: Int = -1

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
        if let s5 = dlsym(lib, "gyrocore_get_frame_at_ts") {
            fnGetFrameTs = unsafeBitCast(s5, to: FnGetFrameTs.self)
        }
        ioQueue.async { [weak self] in
            self?.loadCore(videoPath: videoPath, lensPath: lensPath, config: config,
                           onReady: onReady, onError: onError)
        }
    }

    private func loadCore(videoPath: String, lensPath: String?, config: GyroConfig,
                          onReady: @escaping () -> Void, onError: @escaping (String) -> Void) {
        guard let fn = fnLoad else { onError("No load fn"); return }
        let configJSON = (try? String(data: JSONEncoder().encode(config), encoding: .utf8)) ?? "{}"
        print("[gyro] Loading \(URL(fileURLWithPath: videoPath).lastPathComponent)  config=\(configJSON)")
        let handle: UnsafeMutableRawPointer?
        if let lp = lensPath {
            handle = videoPath.withCString { vp in lp.withCString { lpp in configJSON.withCString { cj in fn(vp, lpp, cj) } } }
        } else {
            handle = videoPath.withCString { vp in configJSON.withCString { cj in fn(vp, nil, cj) } }
        }
        guard let handle else { onError("gyrocore_load failed"); return }
        coreHandle = handle

        var buf = Data(count: 96)
        let rc = buf.withUnsafeMutableBytes { ptr in fnGetParams?(handle, ptr.baseAddress!) ?? -1 }
        guard rc == 0 else { onError("gyrocore_get_params failed"); return }

        frameCount = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        rowCount   = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
        gyroVideoW = Float(buf.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) })
        gyroVideoH = Float(buf.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
        gyroFps    = buf.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Float64.self) }
        buf.withUnsafeBytes { ptr in
            for i in 0..<12 { distortionK[i] = ptr.load(fromByteOffset: 40 + i * 4, as: Float32.self) }
        }
        distortionModel = buf.withUnsafeBytes { $0.load(fromByteOffset: 88, as: Int32.self) }
        rLimit          = buf.withUnsafeBytes { $0.load(fromByteOffset: 92, as: Float32.self) }
        lensCorrectionAmount = Float(config.lensCorrectionAmount)
        rawBuf  = [Float](repeating: 0, count: rowCount * 14 + 9)
        matsBuf = [Float](repeating: 0, count: Int(gyroVideoH) * 16)
        cachedFrameIdx = -1
        readyLock.lock(); _isReady = true; readyLock.unlock()
        print(String(format: "[gyro] Ready: %d frames x %d rows  %dx%d@%.3ffps  distModel=%d",
                     frameCount, rowCount, Int(gyroVideoW), Int(gyroVideoH), gyroFps, distortionModel))
        DispatchQueue.main.async { onReady() }
    }

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
            result = rawBuf.withUnsafeMutableBufferPointer { fnTs(handle, timeSec, $0.baseAddress!) }
        } else if let fn = fnGetFrame {
            result = rawBuf.withUnsafeMutableBufferPointer { fn(handle, UInt32(fi), $0.baseAddress!) }
        } else { return nil }
        lastFetchMs = (CACurrentMediaTime() - t0) * 1000
        guard result == Int32(expectedLen) else { return nil }

        let pfBase = rowCount * 14
        frameFx = rawBuf[pfBase]; frameFy = rawBuf[pfBase + 1]
        frameCx = rawBuf[pfBase + 2]; frameCy = rawBuf[pfBase + 3]
        frameK = [rawBuf[pfBase + 4], rawBuf[pfBase + 5], rawBuf[pfBase + 6], rawBuf[pfBase + 7]]
        frameFov = rawBuf[pfBase + 8]

        let vH = Int(gyroVideoH)
        rawBuf.withUnsafeBufferPointer { raw in
        matsBuf.withUnsafeMutableBufferPointer { mats in
            let rp = raw.baseAddress!; let mp = mats.baseAddress!; let rc = rowCount
            for y in 0..<vH {
                let r = rc == 1 ? 0 : min(y &* rc / max(vH, 1), rc &- 1)
                let sp = rp + r &* 14; let dp = mp + y &* 16
                dp[0]=sp[0]; dp[1]=sp[1]; dp[2]=sp[2]; dp[3]=sp[9]
                dp[4]=sp[3]; dp[5]=sp[4]; dp[6]=sp[5]; dp[7]=sp[10]
                dp[8]=sp[6]; dp[9]=sp[7]; dp[10]=sp[8]; dp[11]=sp[11]
                dp[12]=sp[12]; dp[13]=sp[13]; dp[14]=0; dp[15]=0
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

// MARK: - Metal Shaders

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle (3 vertices, no VBO needed)
vertex VertexOut vertexPassthrough(uint vid [[vertex_id]]) {
    VertexOut out;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    out.texCoord = uv;
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return out;
}

// --- Transfer function helpers ---

float3 pqEOTF(float3 N) {
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 Np = pow(max(N, 0.0), float3(1.0 / m2));
    return pow(max(Np - c1, 0.0) / (c2 - c3 * Np), float3(1.0 / m1));
}

float3 pqOETF(float3 L) {
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 Lm = pow(max(L, 0.0), float3(m1));
    return pow((c1 + c2 * Lm) / (1.0 + c3 * Lm), float3(m2));
}

float3 hlgEOTF(float3 E) {
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = (E[i] <= 0.5) ? E[i]*E[i]/3.0 : (exp((E[i]-c)/a)+b)/12.0;
    return r;
}

float3 hlgOETF(float3 L) {
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = (L[i] <= 1.0/12.0) ? sqrt(3.0*L[i]) : a*log(12.0*L[i]-b)+c;
    return r;
}

// --- YCbCr -> RGB fragment shader ---

fragment float4 fragmentYCbCrToRGB(VertexOut in [[stage_in]],
                                    texture2d<float> texY [[texture(0)]],
                                    texture2d<float> texCbCr [[texture(1)]],
                                    constant uint &mode [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    float y  = texY.sample(s, in.texCoord).r;
    float2 cbcr = texCbCr.sample(s, in.texCoord).rg;

    if (mode == 12) return float4(y, y, y, 1.0);
    if (mode == 13) return float4(cbcr.x, cbcr.y, 0.5, 1.0);

    float Y, Cb, Cr;
    bool fullRange = (mode == 1 || mode == 3 || mode == 5 || mode == 7);
    if (fullRange) { Y = y; Cb = cbcr.x - 0.5; Cr = cbcr.y - 0.5; }
    else { Y = (y - 0.06256109) * 1.167808; Cb = (cbcr.x - 0.50048876) * 1.141685; Cr = (cbcr.y - 0.50048876) * 1.141685; }

    float3 rgb;
    if (mode <= 1 || mode >= 6) { rgb.r = Y + 1.4746*Cr; rgb.g = Y - 0.16455*Cb - 0.57135*Cr; rgb.b = Y + 1.8814*Cb; }
    else if (mode <= 3) { rgb.r = Y + 1.5748*Cr; rgb.g = Y - 0.1873*Cb - 0.4681*Cr; rgb.b = Y + 1.8556*Cb; }
    else { rgb.r = Y + 1.402*Cr; rgb.g = Y - 0.3441*Cb - 0.7141*Cr; rgb.b = Y + 1.772*Cb; }

    if (mode == 8) { float3 lin = pqEOTF(clamp(rgb, 0.0, 1.0)); return float4(clamp(hlgOETF(lin * 10.0), 0.0, 1.0), 1.0); }
    if (mode == 9) { float3 lin = hlgEOTF(clamp(rgb, 0.0, 1.0)); return float4(clamp(pqOETF(lin / 10.0), 0.0, 1.0), 1.0); }
    if (mode == 10) { return float4(pqEOTF(clamp(rgb, 0.0, 1.0)), 1.0); }
    if (mode == 11) { return float4(hlgEOTF(clamp(rgb, 0.0, 1.0)), 1.0); }
    if (mode == 6 || mode == 7) return float4(rgb, 1.0);
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// Simple BGRA passthrough
fragment float4 fragmentBGRA(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return float4(tex.sample(s, in.texCoord).rgb, 1.0);
}

// --- Warp shader (gyro stabilization) ---

struct WarpUniforms {
    float2 videoSize;
    float  matCount;
    float2 fIn;
    float2 cIn;
    float4 distK[3];   // k[0..11] as 3 x vec4
    int    distModel;   // 0=None 1=OpenCVFisheye 3=Poly3 4=Poly5 7=Sony
    float  rLimit;
    float  frameFov;
    float  lensCorr;
};

// Lens undistort (Newton-Raphson inverse)
float2 undistort_point(float2 pos, int distModel, constant float4 *distK) {
    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta_d = clamp(length(pos), -1.5707963, 1.5707963);
        float theta = theta_d;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t4 = t2*t2; float t6 = t4*t2; float t8 = t6*t2;
                float theta_fix = (theta*(1.0+distK[0].x*t2+distK[0].y*t4+distK[0].z*t6+distK[0].w*t8) - theta_d)
                                / (1.0+3.0*distK[0].x*t2+5.0*distK[0].y*t4+7.0*distK[0].z*t6+9.0*distK[0].w*t8);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) break;
            }
            float scale = tan(theta) / theta_d;
            if ((theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0)) return float2(0.0);
            return pos * scale;
        }
        return pos;
    }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = float2(1.0);
        float2 p = pos / post_scale;
        float theta_d = length(p); float theta = theta_d;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t3 = t2*theta; float t4 = t2*t2; float t5 = t4*theta;
                float theta_fix = (theta*(distK[0].x+distK[0].y*theta+distK[0].z*t2+distK[0].w*t3+distK[1].x*t4+distK[1].y*t5) - theta_d)
                                / (distK[0].x+2.0*distK[0].y*theta+3.0*distK[0].z*t2+4.0*distK[0].w*t3+5.0*distK[1].x*t4+6.0*distK[1].y*t5);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) break;
            }
            float scale = tan(theta) / theta_d;
            if ((theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0)) return float2(0.0);
            return p * scale;
        }
        return p;
    }
    return pos;
}

// Lens distortion: 3D homogeneous -> 2D distorted normalized coords
float2 distort_point(float x, float y, float w, int distModel, constant float4 *distK, float rLimit) {
    float2 pos = float2(x, y) / w;
    if (distModel == 0) return pos;
    float r = length(pos);
    if (rLimit > 0.0 && r > rLimit) return float2(-99999.0);

    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta*theta; float t4 = t2*t2; float t6 = t4*t2; float t8 = t4*t4;
        float theta_d = theta * (1.0 + distK[0].x*t2 + distK[0].y*t4 + distK[0].z*t6 + distK[0].w*t8);
        return pos * ((r == 0.0) ? 1.0 : theta_d / r);
    }
    if (distModel == 3) { return pos * (distK[0].x * (pos.x*pos.x + pos.y*pos.y) + 1.0); }
    if (distModel == 4) { float r2 = pos.x*pos.x + pos.y*pos.y; return pos * (1.0 + distK[0].x*r2 + distK[0].y*r2*r2); }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta*theta; float t3 = t2*theta; float t4 = t2*t2; float t5 = t4*theta; float t6 = t3*t3;
        float theta_d = distK[0].x*theta + distK[0].y*t2 + distK[0].z*t3 + distK[0].w*t4 + distK[1].x*t5 + distK[1].y*t6;
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        float2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = float2(1.0);
        return pos * scale * post_scale;
    }
    return pos;
}

float2 rotate_and_distort(float2 out_px, float texY, texture2d<float> matTex, constant WarpUniforms &u) {
    constexpr sampler ms(filter::nearest, address::clamp_to_edge);
    float4 m0 = matTex.sample(ms, float2(0.125, texY));
    float4 m1 = matTex.sample(ms, float2(0.375, texY));
    float4 m2 = matTex.sample(ms, float2(0.625, texY));
    float4 m3 = matTex.sample(ms, float2(0.875, texY));

    float _x = m0.r*out_px.x + m0.g*out_px.y + m0.b;
    float _y = m1.r*out_px.x + m1.g*out_px.y + m1.b;
    float _w = m2.r*out_px.x + m2.g*out_px.y + m2.b;
    if (_w <= 0.0) return float2(-99999.0);

    float2 dp = distort_point(_x, _y, _w, u.distModel, u.distK, u.rLimit);
    if (dp.x < -99998.0) return dp;
    float2 pt = u.fIn * dp;

    float sx = m0.a, sy = m1.a, ra = m2.a;
    float ox = m3.r, oy = m3.g;
    if (sx != 0.0 || sy != 0.0 || ra != 0.0 || ox != 0.0 || oy != 0.0) {
        float cos_a = cos(-ra), sin_a = sin(-ra);
        pt = float2(cos_a*pt.x - sin_a*pt.y - sx + ox,
                     sin_a*pt.x + cos_a*pt.y - sy + oy);
    }
    return pt + u.cIn;
}

fragment float4 fragmentWarp(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              texture2d<float> matTex [[texture(1)]],
                              constant WarpUniforms &u [[buffer(0)]]) {
    constexpr sampler ts(filter::linear, address::clamp_to_edge);
    // Metal: texCoord (0,0) = top-left, y=0 = top row of video
    // No Y-flip needed (unlike OpenGL where y=0 = bottom)
    float2 out_px = float2(in.texCoord.x * u.videoSize.x, in.texCoord.y * u.videoSize.y);

    // Lens correction (undistort output coords)
    if (u.distModel != 0 && u.frameFov > 0.0 && u.lensCorr < 1.0) {
        float factor = max(1.0 - u.lensCorr, 0.001);
        float2 out_c = u.videoSize * 0.5;
        float2 out_f = u.fIn / u.frameFov / factor;
        float2 norm  = (out_px - out_c) / out_f;
        float2 corr  = undistort_point(norm, u.distModel, u.distK);
        float2 undist = corr * out_f + out_c;
        out_px = undist * (1.0 - u.lensCorr) + out_px * u.lensCorr;
    }

    float sy = clamp(out_px.y, 0.0, u.matCount - 1.0);
    if (u.matCount > 1.0) {
        float midTexY = (floor(u.matCount * 0.5) + 0.5) / u.matCount;
        float2 midPt = rotate_and_distort(out_px, midTexY, matTex, u);
        if (midPt.x > -99998.0) { sy = clamp(floor(0.5 + midPt.y), 0.0, u.matCount - 1.0); }
    }
    float texY = (sy + 0.5) / u.matCount;
    float2 src_px = rotate_and_distort(out_px, texY, matTex, u);
    if (src_px.x < -99998.0) return float4(0.0, 0.0, 0.0, 1.0);
    // Metal: texture y=0 = top, no flip needed
    float2 src = float2(src_px.x / u.videoSize.x, src_px.y / u.videoSize.y);
    src = clamp(src, float2(0.0), float2(1.0));
    return tex.sample(ts, src);
}
"""

// MARK: - MetalVideoView

class MetalVideoView: NSView {
    private let metalLayer = CAMetalLayer()
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var ycbcrPipeline: MTLRenderPipelineState!
    private var bgraPipeline: MTLRenderPipelineState!
    private var warpPipeline: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!

    // Offscreen render target for Pass 1 (YCbCr->RGB), read by warp shader
    private var offscreenTex: MTLTexture?
    private var offscreenW: Int = 0
    private var offscreenH: Int = 0

    // Gyro stabilization
    private var gyroCore: GyroCore?
    private(set) var gyroEnabled = false
    private(set) var gyroReady = false
    private(set) var gyroLastError: String?
    private(set) var gyroFetchMs: Double = 0
    private var matTex: MTLTexture?
    private var matTexH: Int = 0

    private(set) var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CVDisplayLink?
    private var timeObserver: Any?

    private(set) var videoInfo = VideoInfo()
    private(set) var currentTime: Double = 0
    private(set) var lastPTS: Double = -1
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private var loopObserver: NSObjectProtocol?
    private(set) var renderFPS: Double = 0
    private(set) var frameCount: Int = 0
    private var frameIntervals: [Double] = []
    private var lastFrameTime: CFTimeInterval = 0
    private var currentVideoPath: String?

    // Frame drop/skip tracking
    private var lastRenderedPTS: Double = -1
    private(set) var droppedFrames: Int = 0   // PTS jumped forward > 1.5 frame intervals
    private(set) var repeatedFrames: Int = 0  // displayLink fired but no new pixel buffer
    private var displayLinkFires: Int = 0
    private var lastPixelBuffer: CVPixelBuffer?  // retained for redraw while paused
    private var needsRedraw = false

    // [A] AVFoundation mode: use AVPlayerLayer directly (no Metal shaders)
    private(set) var avfMode = false
    private var avfPlayerLayer: AVPlayerLayer?

    // [4] Pixel format (output from AVPlayerItemVideoOutput)
    private(set) var pixFmtIndex = 0
    private static let pixelFormats: [(OSType, String)] = [
        (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "x420 10bit VideoRange"),
        (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,  "xf20 10bit FullRange"),
        (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,  "420v 8bit VideoRange"),
        (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,   "420f 8bit FullRange"),
        (kCVPixelFormatType_64RGBAHalf,                    "RGhA f16 HDR"),
        (kCVPixelFormatType_32BGRA,                        "BGRA 8bit SDR"),
    ]
    var pixFmtLabel: String { "[\(pixFmtIndex)] \(Self.pixelFormats[pixFmtIndex].1)" }

    // [1] Decode conversion mode (YCbCr→RGB shader)
    private var decodeMode: UInt32 = 0
    private static let decodeModes: [String] = [
        "Video BT.2020", "Full BT.2020", "Video BT.709", "Full BT.709",
        "Video BT.601", "Full BT.601", "Video 2020 NoClamp", "Full 2020 NoClamp",
        "V.2020 PQ->HLG", "V.2020 HLG->PQ", "V.2020 PQ->Linear", "V.2020 HLG->Linear",
        "Passthrough Y", "Passthrough CbCr",
    ]
    var decodeLabel: String { "[\(decodeMode)] \(Self.decodeModes[Int(decodeMode)])" }

    // [2] Layer colorspace (CAMetalLayer output tag)
    private var csIndex = 0
    private static let colorSpaces: [(CFString, String)] = [
        (CGColorSpace.itur_2100_HLG, "HLG"),
        (CGColorSpace.itur_2100_PQ, "PQ"),
        (CGColorSpace.sRGB, "sRGB"),
        (CGColorSpace.displayP3, "Display P3"),
        (CGColorSpace.extendedSRGB, "Ext sRGB"),
        (CGColorSpace.extendedLinearSRGB, "Ext Lin sRGB"),
        (CGColorSpace.linearSRGB, "Lin sRGB"),
        (CGColorSpace.itur_2020, "BT.2020"),
    ]
    var csLabel: String { "[\(csIndex + 1)] \(Self.colorSpaces[csIndex].1)" }

    // [3] EDR toggle
    var edrEnabled: Bool { metalLayer.wantsExtendedDynamicRangeContent }

    override init(frame: NSRect) {
        super.init(frame: frame)
        guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
        device = dev
        commandQueue = dev.makeCommandQueue()!
        print("[Metal] Device: \(dev.name)")

        wantsLayer = true
        metalLayer.device = dev
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer = metalLayer

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        textureCache = cache!

        setupPipelines()
        print("[Metal] Layer: rgba16Float, colorspace=HLG, EDR=true")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        avfPlayerLayer?.frame = bounds
        CATransaction.commit()
    }

    private func setupPipelines() {
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: metalShaderSource, options: nil) }
        catch { fatalError("[Metal] Shader compile failed: \(error)") }

        let ycbcrDesc = MTLRenderPipelineDescriptor()
        ycbcrDesc.vertexFunction = library.makeFunction(name: "vertexPassthrough")
        ycbcrDesc.fragmentFunction = library.makeFunction(name: "fragmentYCbCrToRGB")
        ycbcrDesc.colorAttachments[0].pixelFormat = .rgba16Float
        ycbcrPipeline = try! device.makeRenderPipelineState(descriptor: ycbcrDesc)

        let bgraDesc = MTLRenderPipelineDescriptor()
        bgraDesc.vertexFunction = library.makeFunction(name: "vertexPassthrough")
        bgraDesc.fragmentFunction = library.makeFunction(name: "fragmentBGRA")
        bgraDesc.colorAttachments[0].pixelFormat = .rgba16Float
        bgraPipeline = try! device.makeRenderPipelineState(descriptor: bgraDesc)

        let warpDesc = MTLRenderPipelineDescriptor()
        warpDesc.vertexFunction = library.makeFunction(name: "vertexPassthrough")
        warpDesc.fragmentFunction = library.makeFunction(name: "fragmentWarp")
        warpDesc.colorAttachments[0].pixelFormat = .rgba16Float
        warpPipeline = try! device.makeRenderPipelineState(descriptor: warpDesc)

        print("[Metal] Pipelines ready (YCbCr + BGRA + Warp)")
    }

    // MARK: - Offscreen texture (for warp pass input)

    private func ensureOffscreenTexture(width: Int, height: Int) {
        guard width != offscreenW || height != offscreenH else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                             width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        offscreenTex = device.makeTexture(descriptor: desc)
        offscreenW = width; offscreenH = height
        print("[Metal] Offscreen texture: \(width)x\(height)")
    }

    // MARK: - matTex (gyro matrix texture: 4 x vH, rgba32Float)

    private func ensureMatTex(height: Int) {
        guard height != matTexH else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                             width: 4, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared  // Apple Silicon: shared memory, no sync needed
        matTex = device.makeTexture(descriptor: desc)
        matTexH = height
        print("[Metal] matTex: 4x\(height) rgba32Float (shared)")
    }

    // MARK: - Load video

    func load(path: String) {
        stopDisplayLink()
        stopGyro()
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        if let obs = loopObserver { NotificationCenter.default.removeObserver(obs); loopObserver = nil }
        player?.pause()
        lastPTS = -1; frameCount = 0; lastRenderedPTS = -1
        droppedFrames = 0; repeatedFrames = 0; displayLinkFires = 0
        currentVideoPath = path

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        videoInfo = analyzeVideo(asset: asset)
        duration = videoInfo.duration

        // Clean up AVF layer if active
        disableAVFLayer()
        avfMode = false

        // Auto-select pixel format from file's bit depth + range
        let outputPixelFormat: OSType
        if videoInfo.bitDepth > 8 {
            outputPixelFormat = videoInfo.fullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            pixFmtIndex = videoInfo.fullRange ? 1 : 0
        } else {
            outputPixelFormat = videoInfo.fullRange
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            pixFmtIndex = videoInfo.fullRange ? 3 : 2
        }
        print("[AVF] File: \(videoInfo.bitDepth)bit fullRange=\(videoInfo.fullRange) → \(pixFmtLabel)")

        // Auto-select decode mode from YCbCr matrix + range
        let fr = videoInfo.fullRange
        if videoInfo.matrix.contains("2020") {
            decodeMode = fr ? 1 : 0       // BT.2020 Full/Video
        } else if videoInfo.matrix.contains("601") {
            decodeMode = fr ? 5 : 4       // BT.601 Full/Video
        } else {
            decodeMode = fr ? 3 : 2       // BT.709 Full/Video (default)
        }

        // Auto-select colorspace + EDR
        if videoInfo.isDolbyVision && videoInfo.dvProfile == 8 {
            csIndex = 0
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            metalLayer.wantsExtendedDynamicRangeContent = true
        } else if videoInfo.isHLG {
            csIndex = 0
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            metalLayer.wantsExtendedDynamicRangeContent = true
        } else if videoInfo.isHDR {
            csIndex = 1
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            metalLayer.wantsExtendedDynamicRangeContent = true
        } else {
            csIndex = 2
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.wantsExtendedDynamicRangeContent = false
        }
        print("[Metal] decode=\(decodeLabel), CS=\(csLabel), fmt=\(pixFmtLabel)")

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: outputPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        videoOutput = output

        let item = AVPlayerItem(asset: asset)
        item.add(output)
        playerItem = item

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        player = newPlayer

        let interval = CMTime(value: 1, timescale: 4)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.player?.seek(to: .zero); self?.player?.play() }

        newPlayer.play(); isPlaying = true
        startDisplayLink()
        startGyro()  // Auto-start gyro stabilization

        // DV P8.4: auto-enable AVPlayerLayer (Apple applies RPU internally)
        if videoInfo.isDolbyVision {
            enableAVFLayer()
            avfMode = true
            print("[AVF] DV detected → auto-enabled AVPlayerLayer")
        }

        print("[AVF] Loaded: \(url.lastPathComponent)  \(videoInfo.width)x\(videoInfo.height)@\(String(format:"%.2f",videoInfo.fps))fps")
        print("[AVF]   transfer=\(videoInfo.transferFunction)  isDV=\(videoInfo.isDolbyVision)  layer=\(csLabel)  avfMode=\(avfMode)")
        if let screen = NSScreen.main {
            print("[AVF]   EDR: max=\(screen.maximumExtendedDynamicRangeColorComponentValue)  potential=\(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")
        }
    }

    // MARK: - Gyro

    func toggleGyro() {
        if gyroEnabled { stopGyro() }
        else { startGyro() }
    }

    private func startGyro() {
        guard let path = currentVideoPath else { return }
        stopGyro()
        gyroEnabled = true; gyroReady = false; gyroLastError = nil
        print("[gyro] Starting for \(URL(fileURLWithPath: path).lastPathComponent)")

        var config = GyroConfig()
        config.readoutMs = GyroCore.readoutMs(for: videoInfo.fps)
        // Lens database: gyroflow resources directory containing camera_presets/profiles.cbor.gz
        config.lensDbDir = "/Applications/Gyroflow.app/Contents/Resources"

        let core = GyroCore()
        gyroCore = core
        core.start(videoPath: path, config: config,
            onReady: { [weak self] in
                guard let self, self.gyroCore === core else { return }
                self.gyroReady = true
                print("[gyro] Ready! \(core.frameCount) frames, distModel=\(core.distortionModel)")
            },
            onError: { [weak self] msg in
                guard let self, self.gyroCore === core else { return }
                self.gyroLastError = msg
                self.gyroEnabled = false
                print("[gyro] Error: \(msg)")
            }
        )
    }

    private func stopGyro() {
        gyroCore?.stop()
        gyroCore = nil
        gyroEnabled = false; gyroReady = false
        gyroLastError = nil; gyroFetchMs = 0
    }

    // MARK: - CVDisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        displayLink = dl
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            Unmanaged<MetalVideoView>.fromOpaque(userInfo).takeUnretainedValue().renderFrame()
            return kCVReturnSuccess
        }, selfPtr)
        CVDisplayLinkStart(dl)
    }

    private func stopDisplayLink() {
        if let dl = displayLink { CVDisplayLinkStop(dl); displayLink = nil }
    }

    // MARK: - Render frame

    private func renderFrame() {
        guard let output = videoOutput else { return }
        displayLinkFires += 1
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())

        let pixelBuffer: CVPixelBuffer
        let pts: Double
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            var presentationTime = CMTime.zero
            guard let pb = output.copyPixelBuffer(forItemTime: itemTime,
                                                   itemTimeForDisplay: &presentationTime) else { return }
            pixelBuffer = pb
            pts = CMTimeGetSeconds(presentationTime)
            lastPixelBuffer = pb
            lastPTS = pts
        } else if needsRedraw, let pb = lastPixelBuffer {
            pixelBuffer = pb
            pts = lastPTS
            needsRedraw = false
        } else {
            repeatedFrames += 1
            return
        }

        // Detect frame drops: PTS jumped more than 1.5 frame intervals
        if lastRenderedPTS >= 0 && videoInfo.fps > 0 {
            let expectedInterval = 1.0 / videoInfo.fps
            let actualInterval = pts - lastRenderedPTS
            if actualInterval > expectedInterval * 1.8 {
                let skipped = Int((actualInterval / expectedInterval).rounded()) - 1
                droppedFrames += skipped
            }
        }
        lastRenderedPTS = pts

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        frameCount += 1
        if frameCount == 1 {
            print("[Metal] First frame: \(width)x\(height)  format=0x\(String(format: "%08X", format))  planes=\(planeCount)  PTS=\(String(format:"%.4f",pts))")
            if let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any] {
                print("[Metal] PixelBuffer attachments:")
                for (key, value) in attachments.sorted(by: { $0.key < $1.key }) {
                    print("[Metal]   \(key.replacingOccurrences(of: "CVImageBuffer", with: "")) = \(value)")
                }
                // Auto-set layer colorspace from pixel buffer attachment
                if let tf = attachments["CVImageBufferTransferFunction"] as? String {
                    if tf.contains("HLG") && csIndex != 0 {
                        csIndex = 0; metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                        print("[Metal] Auto-set CS -> HLG (from attachment)")
                    } else if (tf.contains("2084") || tf.contains("PQ")) && csIndex != 1 {
                        csIndex = 1; metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                        print("[Metal] Auto-set CS -> PQ (from attachment)")
                    }
                }
            }
            // For RGB formats: check if AVFoundation applied DV/HDR processing
            if format == kCVPixelFormatType_64RGBAHalf || format == kCVPixelFormatType_32BGRA {
                if let pbCS = CVBufferGetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, nil) {
                    let cs = pbCS.takeUnretainedValue() as! CGColorSpace
                    print("[Metal] RGBOutput colorspace: \(cs.name ?? "unknown" as CFString)")
                }
            }
        }

        // Fetch gyro matrix for this exact PTS
        var hasGyroWarp = false
        if gyroEnabled, gyroReady, let core = gyroCore, core.isReady {
            let vH = Int(core.gyroVideoH)
            ensureMatTex(height: vH)
            if let (buf, changed) = core.computeMatrixAtTime(timeSec: pts) {
                gyroFetchMs = core.lastFetchMs
                // Debug: log first few frames' PTS and matrix diagonal
                if frameCount <= 3 {
                    let midRow = vH / 2
                    let base = midRow * 16
                    print(String(format: "[gyro] frame=%d PTS=%.4f fi=%d changed=%d mat[mid]=[%.4f,%.4f,%.4f | %.4f,%.4f,%.4f | %.4f,%.4f,%.4f]",
                                 frameCount, pts, Int((pts * core.gyroFps).rounded()), changed ? 1 : 0,
                                 buf[base+0], buf[base+1], buf[base+2],
                                 buf[base+4], buf[base+5], buf[base+6],
                                 buf[base+8], buf[base+9], buf[base+10]))
                }
                if changed, let matTex {
                    let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                           size: MTLSize(width: 4, height: vH, depth: 1))
                    matTex.replace(region: region, mipmapLevel: 0,
                                   withBytes: buf.baseAddress!,
                                   bytesPerRow: 4 * 4 * MemoryLayout<Float>.size)
                }
                hasGyroWarp = true
            }
        }

        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        if hasGyroWarp {
            // === Two-pass rendering ===
            // Pass 1: YCbCr -> RGB -> offscreen texture (video resolution)
            ensureOffscreenTexture(width: width, height: height)
            guard let offTex = offscreenTex else { return }

            let pass1Desc = MTLRenderPassDescriptor()
            pass1Desc.colorAttachments[0].texture = offTex
            pass1Desc.colorAttachments[0].loadAction = .dontCare
            pass1Desc.colorAttachments[0].storeAction = .store

            if let enc1 = cmdBuf.makeRenderCommandEncoder(descriptor: pass1Desc) {
                if planeCount >= 2 {
                    let (yFmt, cbcrFmt) = biplanarFormats(for: pixelBuffer)
                    if let texY = makeTexture(from: pixelBuffer, plane: 0, format: yFmt),
                       let texCbCr = makeTexture(from: pixelBuffer, plane: 1, format: cbcrFmt) {
                        enc1.setRenderPipelineState(ycbcrPipeline)
                        enc1.setFragmentTexture(texY, index: 0)
                        enc1.setFragmentTexture(texCbCr, index: 1)
                        var mode = decodeMode
                        enc1.setFragmentBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)
                    }
                } else {
                    let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
                    let texFmt: MTLPixelFormat = (fmt == kCVPixelFormatType_64RGBAHalf) ? .rgba16Float : .bgra8Unorm
                    if let tex = makeTexture(from: pixelBuffer, plane: 0, format: texFmt) {
                        enc1.setRenderPipelineState(bgraPipeline)
                        enc1.setFragmentTexture(tex, index: 0)
                    }
                }
                enc1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc1.endEncoding()
            }

            // Pass 2: Warp shader -> drawable
            let pass2Desc = MTLRenderPassDescriptor()
            pass2Desc.colorAttachments[0].texture = drawable.texture
            pass2Desc.colorAttachments[0].loadAction = .clear
            pass2Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass2Desc.colorAttachments[0].storeAction = .store

            if let enc2 = cmdBuf.makeRenderCommandEncoder(descriptor: pass2Desc) {
                let core = gyroCore!
                let viewport = aspectFitViewport(videoW: width, videoH: height,
                                                  drawableW: Int(drawable.texture.width),
                                                  drawableH: Int(drawable.texture.height))
                enc2.setViewport(viewport)
                enc2.setRenderPipelineState(warpPipeline)
                enc2.setFragmentTexture(offTex, index: 0)
                enc2.setFragmentTexture(matTex, index: 1)

                // Build uniforms
                var uniforms = WarpUniforms()
                uniforms.videoSize = SIMD2<Float>(core.gyroVideoW, core.gyroVideoH)
                uniforms.matCount = core.gyroVideoH
                uniforms.fIn = SIMD2<Float>(core.frameFx, core.frameFy)
                uniforms.cIn = SIMD2<Float>(core.frameCx, core.frameCy)
                // Merge per-frame k[0..3] + static k[4..11]
                var mergedK = [Float](repeating: 0, count: 12)
                for i in 0..<4 { mergedK[i] = core.frameK[i] }
                for i in 4..<12 { mergedK[i] = core.distortionK[i] }
                uniforms.distK.0 = SIMD4<Float>(mergedK[0], mergedK[1], mergedK[2], mergedK[3])
                uniforms.distK.1 = SIMD4<Float>(mergedK[4], mergedK[5], mergedK[6], mergedK[7])
                uniforms.distK.2 = SIMD4<Float>(mergedK[8], mergedK[9], mergedK[10], mergedK[11])
                uniforms.distModel = core.distortionModel
                uniforms.rLimit = core.rLimit
                uniforms.frameFov = core.frameFov
                uniforms.lensCorr = core.lensCorrectionAmount

                if frameCount <= 3 {
                    print(String(format: "[gyro] uniforms: videoSize=%.0fx%.0f matCount=%.0f fIn=[%.1f,%.1f] cIn=[%.1f,%.1f] distModel=%d frameFov=%.4f lensCorr=%.2f",
                                 uniforms.videoSize.x, uniforms.videoSize.y, uniforms.matCount,
                                 uniforms.fIn.x, uniforms.fIn.y, uniforms.cIn.x, uniforms.cIn.y,
                                 uniforms.distModel, uniforms.frameFov, uniforms.lensCorr))
                    print("[gyro] WarpUniforms size=\(MemoryLayout<WarpUniforms>.size) stride=\(MemoryLayout<WarpUniforms>.stride) align=\(MemoryLayout<WarpUniforms>.alignment)")
                }
                enc2.setFragmentBytes(&uniforms, length: MemoryLayout<WarpUniforms>.size, index: 0)
                enc2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc2.endEncoding()
            }
        } else {
            // === Single pass: direct to drawable ===
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = drawable.texture
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            passDesc.colorAttachments[0].storeAction = .store

            if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) {
                let (yFmt2, cbcrFmt2) = biplanarFormats(for: pixelBuffer)
                if planeCount >= 2 {
                    if let texY = makeTexture(from: pixelBuffer, plane: 0, format: yFmt2),
                       let texCbCr = makeTexture(from: pixelBuffer, plane: 1, format: cbcrFmt2) {
                        let viewport = aspectFitViewport(videoW: width, videoH: height,
                                                          drawableW: Int(drawable.texture.width),
                                                          drawableH: Int(drawable.texture.height))
                        encoder.setViewport(viewport)
                        encoder.setRenderPipelineState(ycbcrPipeline)
                        encoder.setFragmentTexture(texY, index: 0)
                        encoder.setFragmentTexture(texCbCr, index: 1)
                        var mode = decodeMode
                        encoder.setFragmentBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                } else {
                    // Single-plane: BGRA (8-bit) or RGhA (float16)
                    let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
                    let texFmt: MTLPixelFormat = (fmt == kCVPixelFormatType_64RGBAHalf) ? .rgba16Float : .bgra8Unorm
                    if let tex = makeTexture(from: pixelBuffer, plane: 0, format: texFmt) {
                        let viewport = aspectFitViewport(videoW: width, videoH: height,
                                                          drawableW: Int(drawable.texture.width),
                                                          drawableH: Int(drawable.texture.height))
                        encoder.setViewport(viewport)
                        encoder.setRenderPipelineState(bgraPipeline)
                        encoder.setFragmentTexture(tex, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                }
                encoder.endEncoding()
            }
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()

        // FPS measurement
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt < 2.0 {
                frameIntervals.append(dt)
                if frameIntervals.count > 60 { frameIntervals.removeFirst() }
                if frameIntervals.count >= 5 {
                    let mean = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                    renderFPS = mean > 0 ? 1.0 / mean : 0
                }
            }
        }
        lastFrameTime = now
    }

    /// Returns (Y format, CbCr format) based on pixel buffer's actual pixel format.
    private func biplanarFormats(for pixelBuffer: CVPixelBuffer) -> (MTLPixelFormat, MTLPixelFormat) {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,    // 420v (8-bit)
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:     // 420f (8-bit)
            return (.r8Unorm, .rg8Unorm)
        default:  // 10-bit (x420, xf20) and others
            return (.r16Unorm, .rg16Unorm)
        }
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MTLTexture? {
        let w: Int, h: Int
        if CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            w = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            h = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        } else {
            w = CVPixelBufferGetWidth(pixelBuffer)
            h = CVPixelBufferGetHeight(pixelBuffer)
        }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer,
                                                                nil, format, w, h, plane, &cvTex)
        guard status == kCVReturnSuccess, let cvTex else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    private func aspectFitViewport(videoW: Int, videoH: Int, drawableW: Int, drawableH: Int) -> MTLViewport {
        let videoAspect = Double(videoW) / Double(videoH)
        let drawableAspect = Double(drawableW) / Double(drawableH)
        let vpW: Double, vpH: Double, vpX: Double, vpY: Double
        if videoAspect > drawableAspect {
            vpW = Double(drawableW); vpH = vpW / videoAspect; vpX = 0; vpY = (Double(drawableH) - vpH) / 2
        } else {
            vpH = Double(drawableH); vpW = vpH * videoAspect; vpX = (Double(drawableW) - vpW) / 2; vpY = 0
        }
        return MTLViewport(originX: vpX, originY: vpY, width: vpW, height: vpH, znear: 0, zfar: 1)
    }

    // MARK: - Controls (A/1/2/3/G: pipeline order)

    // [A] AVFoundation mode: AVPlayerLayer direct rendering
    func toggleAVFMode() {
        avfMode.toggle()
        if avfMode {
            enableAVFLayer()
            print("[A] AVF mode ON — AVPlayerLayer direct")
        } else {
            disableAVFLayer()
            needsRedraw = true
            print("[A] AVF mode OFF — Metal pipeline")
        }
    }

    private func enableAVFLayer() {
        guard let p = player else { return }
        disableAVFLayer()
        let pl = AVPlayerLayer(player: p)
        pl.videoGravity = .resizeAspect
        pl.frame = bounds
        pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        pl.backgroundColor = CGColor.black
        // Add as sublayer on top of metalLayer
        metalLayer.addSublayer(pl)
        avfPlayerLayer = pl
    }

    private func disableAVFLayer() {
        avfPlayerLayer?.removeFromSuperlayer()
        avfPlayerLayer = nil
    }

    // [4] Pixel format — requires re-creating video output
    func cyclePixelFormat() {
        avfMode = false
        pixFmtIndex = (pixFmtIndex + 1) % Self.pixelFormats.count
        let (fmt, _) = Self.pixelFormats[pixFmtIndex]
        // Re-create video output with new pixel format
        guard let item = playerItem, let oldOutput = videoOutput else { return }
        item.remove(oldOutput)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: fmt,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let newOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
        item.add(newOutput)
        videoOutput = newOutput
        lastPixelBuffer = nil
        frameCount = 0  // re-trigger first-frame log
        print("[4] PixFmt -> \(pixFmtLabel)")
    }

    // [1] Decode mode
    func cycleDecodeMode() {
        avfMode = false
        decodeMode = (decodeMode + 1) % UInt32(Self.decodeModes.count)
        needsRedraw = true
        print("[1] Decode -> \(decodeLabel)")
    }

    // [2] Layer colorspace
    func cycleColorspace() {
        avfMode = false
        csIndex = (csIndex + 1) % Self.colorSpaces.count
        let (name, _) = Self.colorSpaces[csIndex]
        metalLayer.colorspace = CGColorSpace(name: name)
        needsRedraw = true
        print("[2] Colorspace -> \(csLabel)")
    }

    // [3] EDR toggle
    func toggleEDR() {
        avfMode = false
        metalLayer.wantsExtendedDynamicRangeContent.toggle()
        needsRedraw = true
        print("[3] EDR -> \(metalLayer.wantsExtendedDynamicRangeContent ? "ON" : "OFF")")
    }

    // [I] Dump pixel buffer info
    func dumpPixelBufferInfo() {
        guard let pb = lastPixelBuffer else { print("[I] No pixel buffer"); return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let fmtChars = [fmt >> 24, fmt >> 16, fmt >> 8, fmt].map { Character(UnicodeScalar($0 & 0xFF)!) }
        let planes = CVPixelBufferGetPlaneCount(pb)
        print("[I] PixelBuffer: \(w)x\(h)  format=\(String(fmtChars)) (0x\(String(format:"%08X",fmt)))  planes=\(planes)")
        if let att = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] {
            for (key, value) in att.sorted(by: { $0.key < $1.key }) {
                if key.contains("DolbyVisionRPUData"), let rpuData = value as? Data {
                    print("[I]   DolbyVisionRPUData = (\(rpuData.count) bytes)")
                    if let info = parseDVRPU(rpuData) {
                        print("[I]     RPU summary: profile=\(info.profile) level=\(info.level) BL=\(info.blBitDepth)bit EL=\(info.elBitDepth)bit")
                        if let l1 = info.l1 {
                            print(String(format: "[I]     L1: min=%.4f max=%.1f avg=%.1f nits",
                                         l1.minNits, l1.maxNits, l1.avgNits))
                        }
                    } else {
                        print("[I]     (RPU parse failed)")
                    }
                } else {
                    print("[I]   \(key.replacingOccurrences(of: "CVImageBuffer", with: "")) = \(value)")
                }
            }
        }
        print("[I] Metal: decode=\(decodeLabel)  CS=\(csLabel)  EDR=\(edrEnabled)")
        if let screen = NSScreen.main {
            print(String(format: "[I] EDR headroom: current=%.2f  potential=%.2f",
                         screen.maximumExtendedDynamicRangeColorComponentValue,
                         screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        }
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if isPlaying { p.pause() }
        else {
            if let item = p.currentItem, CMTimeGetSeconds(item.currentTime()) >= duration - 0.1 { p.seek(to: .zero) }
            p.play()
        }
        isPlaying.toggle()
    }

    func seek(by seconds: Double) {
        guard let p = player else { return }
        let target = max(0, min(currentTime + seconds, duration))
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggleMute() { player?.isMuted.toggle(); print("[AVF] Mute: \(player?.isMuted ?? false)") }
    func frameStep() { player?.pause(); isPlaying = false; player?.currentItem?.step(byCount: 1) }
    func frameBackStep() { player?.pause(); isPlaying = false; player?.currentItem?.step(byCount: -1) }

    deinit {
        stopDisplayLink(); stopGyro()
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
    }
}

// Swift struct matching Metal WarpUniforms
struct WarpUniforms {
    var videoSize: SIMD2<Float> = .zero
    var matCount: Float = 0
    var _pad0: Float = 0
    var fIn: SIMD2<Float> = .zero
    var cIn: SIMD2<Float> = .zero
    var distK: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)
    var distModel: Int32 = 0
    var rLimit: Float = 0
    var frameFov: Float = 0
    var lensCorr: Float = 0
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var playerView: MetalVideoView!
    var statsLabel: NSTextField!
    var infoLabel: NSTextField!
    var statsTimer: Timer?
    var keyMonitor: Any?
    var currentPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "testavf -- Metal HDR + Gyro"
        window.backgroundColor = .black
        window.minSize = NSSize(width: 320, height: 180)

        playerView = MetalVideoView(frame: window.contentView!.bounds)
        playerView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(playerView)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        setupOverlays()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateStats() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handleKey(event) ?? event }

        if CommandLine.arguments.count > 1 {
            let path = CommandLine.arguments[1]
            currentPath = path
            playerView.load(path: path)
            updateTitle()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openFile() }
        }
    }

    private func setupOverlays() {
        let statsContainer = NSView()
        statsContainer.wantsLayer = true
        statsContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        statsContainer.layer?.cornerRadius = 5
        statsContainer.translatesAutoresizingMaskIntoConstraints = false

        statsLabel = NSTextField(labelWithString: "-")
        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        statsLabel.isBezeled = false; statsLabel.drawsBackground = false
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.alignment = .right

        statsContainer.addSubview(statsLabel)
        window.contentView!.addSubview(statsContainer)
        NSLayoutConstraint.activate([
            statsLabel.topAnchor.constraint(equalTo: statsContainer.topAnchor, constant: 5),
            statsLabel.bottomAnchor.constraint(equalTo: statsContainer.bottomAnchor, constant: -5),
            statsLabel.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor, constant: 8),
            statsLabel.trailingAnchor.constraint(equalTo: statsContainer.trailingAnchor, constant: -8),
            statsContainer.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 8),
            statsContainer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -8),
        ])

        let infoContainer = NSView()
        infoContainer.wantsLayer = true
        infoContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        infoContainer.layer?.cornerRadius = 5
        infoContainer.translatesAutoresizingMaskIntoConstraints = false

        infoLabel = NSTextField(labelWithString: "-")
        infoLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        infoLabel.isBezeled = false; infoLabel.drawsBackground = false
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
    }

    private func updateStats() {
        let t = playerView.currentTime, d = playerView.duration
        let fps = playerView.renderFPS, pts = playerView.lastPTS
        let tStr = String(format: "%d:%02d", Int(t)/60, Int(t)%60)
        let dStr = String(format: "%d:%02d", Int(d)/60, Int(d)%60)
        statsLabel.stringValue = "\(playerView.isPlaying ? ">" : "||")  \(tStr)/\(dStr)  \(fps > 0 ? String(format:"%.1f",fps) : "-")fps  PTS=\(pts >= 0 ? String(format:"%.4f",pts) : "-")"

        let v = playerView.videoInfo
        var lines: [String] = []
        if v.width > 0 { lines.append("\(v.width)x\(v.height)  \(String(format:"%.2f",v.fps))fps") }
        let isRGB = playerView.pixFmtIndex >= 4  // RGhA, BGRA
        lines.append("[A] AVF: \(playerView.avfMode ? "ON" : "OFF")")
        lines.append("[4] Fmt:  \(playerView.pixFmtLabel)")
        lines.append("[1] Dec:  \(isRGB ? "(n/a — RGB passthrough)" : playerView.decodeLabel)")
        lines.append("[2] CS:   \(playerView.csLabel)")
        lines.append("[3] EDR:  \(playerView.edrEnabled ? "ON" : "OFF")")
        // [G] Gyro status
        if playerView.gyroEnabled {
            if playerView.gyroReady {
                lines.append("[G] Gyro: ON  \(String(format:"%.1f",playerView.gyroFetchMs))ms")
            } else if let err = playerView.gyroLastError {
                lines.append("[G] Gyro: ERR \(err)")
            } else {
                lines.append("[G] Gyro: loading...")
            }
        } else {
            lines.append("[G] Gyro: OFF")
        }
        // Frame stats
        let drop = playerView.droppedFrames
        let rpt = playerView.repeatedFrames
        let rendered = playerView.frameCount
        lines.append("Frames: \(rendered)  drop:\(drop)  rpt:\(rpt)")
        if let screen = NSScreen.main {
            lines.append(String(format: "EDR: %.1f/%.1f", screen.maximumExtendedDynamicRangeColorComponentValue, screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        }
        infoLabel.stringValue = lines.joined(separator: "\n")
    }

    // Keyboard:
    //   Space: play/pause    M: mute       .<>: frame step
    //   Left/Right: seek     Q: quit
    //   Pipeline order:
    //     A: AVF layer  1: decode  2: colorspace  3: EDR  4: pixfmt  G: gyro  I: info
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Arrow keys and special keys by keyCode
        switch event.keyCode {
        case 49:  playerView.togglePlayPause(); return nil               // Space
        case 123: playerView.seek(by: -5); return nil                    // Left
        case 124: playerView.seek(by: 5); return nil                     // Right
        default: break
        }
        // Character-based keys
        guard let ch = event.charactersIgnoringModifiers?.lowercased() else { return event }
        switch ch {
        case ".":  playerView.frameStep(); return nil
        case ",":  playerView.frameBackStep(); return nil
        case "m":  playerView.toggleMute(); return nil
        case "q":  NSApplication.shared.terminate(nil); return nil
        case "a":  playerView.toggleAVFMode(); updateStats(); return nil
        case "1":  playerView.cycleDecodeMode(); updateStats(); return nil
        case "2":  playerView.cycleColorspace(); updateStats(); return nil
        case "3":  playerView.toggleEDR(); updateStats(); return nil
        case "4":  playerView.cyclePixelFormat(); updateStats(); return nil
        case "g":  playerView.toggleGyro(); updateStats(); return nil
        case "i":  playerView.dumpPixelBufferInfo(); return nil
        default:   return event
        }
    }

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            currentPath = url.path
            playerView.load(path: url.path)
            updateTitle()
        }
    }

    private func updateTitle() {
        let name = currentPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "testavf"
        window.title = "\(name) [Metal]  \(playerView.csLabel)  \(playerView.decodeLabel)"
    }

    func applicationWillTerminate(_ notification: Notification) { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Quit testavf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appItem.submenu = appMenu
let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(NSMenuItem(title: "Open...", action: #selector(AppDelegate.openFile), keyEquivalent: "o"))
fileItem.submenu = fileMenu
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
