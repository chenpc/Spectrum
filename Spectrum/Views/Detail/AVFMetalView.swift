import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Metal
import QuartzCore
import os

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

// MARK: - Video Info

struct AVFVideoInfo {
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
    var dvLevel: Int = 0
    /// Rotation from preferredTransform (0, 90, 180, 270)
    var rotation: Int = 0

    /// Map analyzed flags to Spectrum's VideoHDRType.
    var hdrType: VideoHDRType? {
        if isDolbyVision { return .dolbyVision }
        if isHLG { return .hlg }
        if isHDR { return .hdr10 }
        return nil
    }
}

func analyzeVideo(asset: AVAsset) async -> AVFVideoInfo {
    var info = AVFVideoInfo()
    info.duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
    let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
    guard let track = tracks.first else { return info }
    let size = (try? await track.load(.naturalSize)) ?? .zero
    info.width = Int(size.width)
    info.height = Int(size.height)
    info.fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
    // Detect rotation from preferredTransform
    if let transform = try? await track.load(.preferredTransform) {
        let angle = atan2(transform.b, transform.a)
        let degrees = Int(round(angle * 180 / .pi))
        // Normalize to 0, 90, 180, 270
        info.rotation = ((degrees % 360) + 360) % 360
    }
    let descriptions = (try? await track.load(.formatDescriptions)) ?? []
    for fd in descriptions {
        let fourCC = CMFormatDescriptionGetMediaSubType(fd)
        let chars: [Character] = [
            Character(UnicodeScalar((fourCC >> 24) & 0xFF)!),
            Character(UnicodeScalar((fourCC >> 16) & 0xFF)!),
            Character(UnicodeScalar((fourCC >> 8) & 0xFF)!),
            Character(UnicodeScalar(fourCC & 0xFF)!),
        ]
        info.codec = String(chars)

        if let bpc = CMFormatDescriptionGetExtension(fd, extensionKey: "BitsPerComponent" as CFString) {
            info.bitDepth = bpc as! Int
        }
        if let fr = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) {
            info.fullRange = (fr as! NSNumber).boolValue
        }

        if let exts = CMFormatDescriptionGetExtensions(fd) as? [String: Any] {
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
                    if dvcC.count >= 4 {
                        info.dvProfile = Int(dvcC[2] >> 1)
                        info.dvLevel = Int(dvcC[2] & 1) << 5 | Int(dvcC[3] >> 3)
                    }
                }
                if let dvvC = atoms["dvvC"] as? Data {
                    info.isDolbyVision = true; info.isHDR = true
                    if dvvC.count >= 4 {
                        info.dvProfile = Int(dvvC[2] >> 1)
                        info.dvLevel = Int(dvvC[2] & 1) << 5 | Int(dvvC[3] >> 3)
                    }
                }
            }
        }
    }
    return info
}

private let _avfColorSpaces: [(String, String)] = [
    (CGColorSpace.itur_2100_HLG as String, "HLG"),
    (CGColorSpace.itur_2100_PQ as String, "PQ"),
    (CGColorSpace.sRGB as String, "sRGB"),
    (CGColorSpace.displayP3 as String, "Display P3"),
    (CGColorSpace.extendedSRGB as String, "Ext sRGB"),
    (CGColorSpace.extendedLinearSRGB as String, "Ext Lin sRGB"),
    (CGColorSpace.linearSRGB as String, "Lin sRGB"),
    (CGColorSpace.itur_2020 as String, "BT.2020"),
]

private let _avfDecodeModes: [String] = [
    "Video BT.2020", "Full BT.2020", "Video BT.709", "Full BT.709",
    "Video BT.601", "Full BT.601", "Video 2020 NoClamp", "Full 2020 NoClamp",
    "V.2020 PQ->HLG", "V.2020 HLG->PQ", "V.2020 PQ->Linear", "V.2020 HLG->Linear",
    "Passthrough Y", "Passthrough CbCr",
]

// MARK: - AVFMetalView

class AVFMetalView: NSView, @unchecked Sendable {
    nonisolated(unsafe) private let metalLayer = CAMetalLayer()
    nonisolated(unsafe) private var device: MTLDevice!
    nonisolated(unsafe) private var commandQueue: MTLCommandQueue!
    nonisolated(unsafe) private var ycbcrPipeline: MTLRenderPipelineState!
    nonisolated(unsafe) private var bgraPipeline: MTLRenderPipelineState!
    nonisolated(unsafe) private var warpPipeline: MTLRenderPipelineState!
    nonisolated(unsafe) private var textureCache: CVMetalTextureCache!

    // Offscreen render target for Pass 1 (YCbCr->RGB), read by warp shader
    nonisolated(unsafe) private var offscreenTex: MTLTexture?
    nonisolated(unsafe) private var offscreenW: Int = 0
    nonisolated(unsafe) private var offscreenH: Int = 0

    // Gyro stabilization
    nonisolated(unsafe) private var gyroCore: GyroCoreProvider?
    nonisolated(unsafe) private var matTex: MTLTexture?
    nonisolated(unsafe) private var matTexH: Int = 0

    // Gyro Stability Index — written on renderQueue
    nonisolated(unsafe) private var prevMidRow: (Float, Float, Float, Float, Float, Float, Float, Float, Float)?
    nonisolated(unsafe) private var siAngles: [Double] = []
    // nonisolated(unsafe): written on renderQueue, read from poll queue.
    // Double on arm64 is naturally aligned; single-instruction reads cannot tear.
    nonisolated(unsafe) private(set) var gyroSI: Double = 0

    /// When true, suppress rendering until gyroCore is ready.
    nonisolated(unsafe) var waitingForGyro: Bool = false

    /// Deferred pause state: when setPause is called before player exists, saved here.
    nonisolated(unsafe) private var pendingPause: Bool? = nil
    nonisolated(unsafe) private(set) var player: AVPlayer?
    nonisolated(unsafe) private var playerItem: AVPlayerItem?
    nonisolated(unsafe) private var videoOutput: AVPlayerItemVideoOutput?
    nonisolated(unsafe) private var displayLink: CVDisplayLink?
    nonisolated(unsafe) private var timeObserver: Any?

    nonisolated(unsafe) private(set) var videoInfo = AVFVideoInfo()
    nonisolated(unsafe) private(set) var currentTime: Double = 0
    nonisolated(unsafe) private(set) var lastPTS: Double = -1
    nonisolated(unsafe) private(set) var videoDuration: Double = 0
    nonisolated(unsafe) private(set) var isEOFReached: Bool = false
    nonisolated(unsafe) private var eofObserver: NSObjectProtocol?

    // Frame timing — written on CVDisplayLink thread, read from poll queue.
    nonisolated(unsafe) private(set) var renderFPS: Double = 0
    nonisolated(unsafe) private(set) var renderCV: Double = 0
    nonisolated(unsafe) private(set) var renderStability: Double = 1
    nonisolated(unsafe) private var frameIntervals: [Double] = []
    nonisolated(unsafe) private var lastFrameTime: CFTimeInterval = 0
    nonisolated(unsafe) private var frameCount: Int = 0

    nonisolated(unsafe) var diagnosticsEnabled: Bool = true

    // Decode mode + layer colorspace
    nonisolated(unsafe) private var decodeMode: UInt32 = 0
    /// Video rotation from preferredTransform (0, 90, 180, 270)
    nonisolated(unsafe) private var videoRotation: UInt32 = 0

    static let colorSpaces = _avfColorSpaces
    static let decodeModeNames: [String] = _avfDecodeModes

    /// Human-readable CALayer colorspace name
    nonisolated var layerColorspaceInfo: String {
        guard let cs = metalLayer.colorspace?.name as String? else { return "-" }
        for (name, label) in _avfColorSpaces where name == cs { return label }
        return (cs as NSString).lastPathComponent
    }

    /// Decode colorspace info (e.g. "Video BT.2020", "V.2020 HLG->PQ").
    nonisolated var decodeColorspaceInfo: String {
        let m = Int(decodeMode)
        guard m < _avfDecodeModes.count else { return "-" }
        return "[\(m)] \(_avfDecodeModes[m])"
    }

    // MARK: - Public mode setters

    /// Cycle to next layer colorspace.
    func cycleColorspace() {
        let current = metalLayer.colorspace?.name as String?
        let idx = _avfColorSpaces.firstIndex(where: { $0.0 == current }) ?? -1
        let next = (idx + 1) % _avfColorSpaces.count
        let (name, _) = _avfColorSpaces[next]
        metalLayer.colorspace = CGColorSpace(name: name as CFString)
        metalLayer.wantsExtendedDynamicRangeContent =
            (name != CGColorSpace.sRGB as String && name != CGColorSpace.linearSRGB as String)
    }

    /// Cycle to next decode mode.
    nonisolated func cycleDecodeMode() {
        decodeMode = (decodeMode + 1) % UInt32(_avfDecodeModes.count)
    }

    /// Set layer colorspace by index into `colorSpaces`.
    func setColorspace(index: Int) {
        guard index >= 0, index < _avfColorSpaces.count else { return }
        let (name, _) = _avfColorSpaces[index]
        metalLayer.colorspace = CGColorSpace(name: name as CFString)
        metalLayer.wantsExtendedDynamicRangeContent =
            (name != CGColorSpace.sRGB as String && name != CGColorSpace.linearSRGB as String)
    }

    /// Set decode mode by index into `decodeModeNames`.
    nonisolated func setDecodeMode(index: Int) {
        guard index >= 0, index < _avfDecodeModes.count else { return }
        decodeMode = UInt32(index)
    }

    /// Declared FPS of the video file
    nonisolated var videoFPS: Double { videoInfo.fps }

    /// Pixel format summary (e.g. "YCbCr 10bit Video Range")
    nonisolated var pixelFormatInfo: String {
        let range = videoInfo.fullRange ? "Full Range" : "Video Range"
        return "YCbCr \(videoInfo.bitDepth)bit \(range)"
    }

    /// Codec info (e.g. "dvh1 DV P8.4", "avc1", nil if not interesting)
    nonisolated var codecInfo: String? {
        guard videoInfo.isDolbyVision else { return nil }
        return "\(videoInfo.codec) DV P\(videoInfo.dvProfile).\(videoInfo.dvLevel)"
    }

    /// Color space summary (e.g. "BT.2020", "BT.709")
    nonisolated var colorSpaceInfo: String {
        let matrix = videoInfo.matrix.contains("2020") ? "BT.2020"
                   : videoInfo.matrix.contains("601") ? "BT.601" : "BT.709"
        return matrix
    }

    /// True when DV content uses AVPlayerLayer.
    nonisolated var isAVFLayerMode: Bool { avfLayerMode }

    // Mute state
    nonisolated(unsafe) private var isMuted: Bool = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
        device = dev
        commandQueue = dev.makeCommandQueue()!

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
        CATransaction.commit()
    }

    private func setupPipelines() {
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: MetalShaders.source, options: nil) }
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
    }

    // MARK: - Offscreen texture

    nonisolated private func ensureOffscreenTexture(width: Int, height: Int) {
        guard width != offscreenW || height != offscreenH else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                             width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        offscreenTex = device.makeTexture(descriptor: desc)
        offscreenW = width; offscreenH = height
    }

    // MARK: - matTex (gyro matrix texture: 4 x vH, rgba32Float)

    nonisolated private func ensureMatTex(height: Int) {
        guard height != matTexH else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                             width: 4, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        matTex = device.makeTexture(descriptor: desc)
        matTexH = height
    }

    // MARK: - HDR configuration

    /// Toggle EDR (Extended Dynamic Range) on/off.
    /// Only changes wantsExtendedDynamicRangeContent — decode mode and colorspace stay unchanged.
    func setEDR(_ enabled: Bool) {
        metalLayer.wantsExtendedDynamicRangeContent = enabled
        avfPlayerLayer?.wantsExtendedDynamicRangeContent = enabled
    }

    // MARK: - Gyro

    nonisolated func loadGyroCore(_ core: GyroCoreProvider?) {
        // Synchronize with renderQueue to prevent use-after-free:
        // renderFrame() may be mid-flight using the old gyroCore when we nil it out.
        renderQueue.sync {
            self.gyroCore = core
            self.prevMidRow = nil; self.siAngles.removeAll(); self.gyroSI = 0
        }
        waitingForGyro = false
    }

    /// True when DV content is rendered via AVPlayerLayer instead of Metal pipeline.
    nonisolated(unsafe) private(set) var avfLayerMode: Bool = false
    nonisolated(unsafe) private var avfPlayerLayer: AVPlayerLayer?

    // MARK: - Load video

    func load(path: String) {
        stopDisplayLink()
        cleanupPlayer()
        disableAVFLayer()
        lastPTS = -1; frameCount = 0; isEOFReached = false
        frameIntervals.removeAll(); lastFrameTime = 0
        renderFPS = 0; renderCV = 0; renderStability = 1
        pendingPause = nil

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let info = await analyzeVideo(asset: asset)
            self.videoInfo = info
            self.videoDuration = info.duration
            self.videoRotation = UInt32(info.rotation)

            // Auto-select pixel format from file's bit depth + range
            let outputPixelFormat: OSType
            if info.bitDepth > 8 {
                outputPixelFormat = info.fullRange
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            } else {
                outputPixelFormat = info.fullRange
                    ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }

            // Auto-select decode mode from YCbCr matrix + range
            let fr = info.fullRange
            if info.matrix.contains("2020") {
                self.decodeMode = fr ? 1 : 0       // BT.2020 Full/Video
            } else if info.matrix.contains("601") {
                self.decodeMode = fr ? 5 : 4       // BT.601 Full/Video
            } else {
                self.decodeMode = fr ? 3 : 2       // BT.709 Full/Video (default)
            }

            // Auto-select colorspace + EDR
            if info.isDolbyVision {
                self.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                self.metalLayer.wantsExtendedDynamicRangeContent = true
            } else if info.isHLG {
                self.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                self.metalLayer.wantsExtendedDynamicRangeContent = true
            } else if info.isHDR {
                self.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                self.metalLayer.wantsExtendedDynamicRangeContent = true
            } else {
                self.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                self.metalLayer.wantsExtendedDynamicRangeContent = false
            }

            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: outputPixelFormat,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            self.videoOutput = output

            let item = AVPlayerItem(asset: asset)
            item.add(output)
            self.playerItem = item

            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = self.isMuted
            self.player = newPlayer

            // EOF detection
            self.eofObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.isEOFReached = true
            }

            // DV: auto-enable AVPlayerLayer (Apple applies RPU internally)
            if info.isDolbyVision {
                self.enableAVFLayer()
            }

            // Apply deferred pause/play if setPause was called before player existed
            if let pending = self.pendingPause {
                self.pendingPause = nil
                if !pending {
                    self.isEOFReached = false
                    newPlayer.play()
                }
            }

            Log.player.info("Loaded: \(url.lastPathComponent, privacy: .public)  \(info.width)x\(info.height)@\(String(format:"%.2f",info.fps))fps  transfer=\(info.transferFunction, privacy: .public)  isDV=\(info.isDolbyVision)  matrix=\(info.matrix, privacy: .public)  \(info.bitDepth)bit  decode=\(self.decodeColorspaceInfo, privacy: .public)  avfLayer=\(self.avfLayerMode, privacy: .public)")
        }
    }

    private func enableAVFLayer() {
        guard let p = player else { return }
        disableAVFLayer()
        let playerLayer = AVPlayerLayer(player: p)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = metalLayer.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        metalLayer.addSublayer(playerLayer)
        avfPlayerLayer = playerLayer
        avfLayerMode = true
        // Periodic time update (renderFrame is skipped in AVFLayer mode)
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }

    private func disableAVFLayer() {
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        avfPlayerLayer?.removeFromSuperlayer()
        avfPlayerLayer = nil
        avfLayerMode = false
    }

    func stop() {
        stopDisplayLink()
        cleanupPlayer()
        gyroCore = nil
    }

    private func cleanupPlayer() {
        player?.pause()
        disableAVFLayer()
        if let obs = eofObserver { NotificationCenter.default.removeObserver(obs); eofObserver = nil }
        player = nil
        playerItem = nil
        videoOutput = nil
        videoDuration = 0
        currentTime = 0
        isEOFReached = false
    }

    // MARK: - Playback control

    nonisolated var isPaused: Bool {
        guard let p = player else { return true }
        return p.rate == 0
    }

    nonisolated func setPause(_ paused: Bool) {
        guard let p = player else {
            pendingPause = paused
            return
        }
        pendingPause = nil
        if paused { p.pause() }
        else {
            isEOFReached = false
            p.play()
        }
    }

    nonisolated func seek(to seconds: Double) {
        guard let p = player else { return }
        isEOFReached = false
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        p.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    nonisolated(unsafe) private var _volume: Float = 1.0

    nonisolated func setMute(_ muted: Bool) {
        isMuted = muted
        player?.isMuted = muted
    }

    nonisolated func setVolume(_ volume: Float) {
        let v = max(0, min(1, volume))
        _volume = v
        player?.volume = v
    }

    nonisolated var volume: Float { _volume }
    nonisolated var muted: Bool { isMuted }

    // MARK: - CVDisplayLink

    /// Render queue: runs renderFrame at user-interactive QoS instead of the CVDisplayLink's
    /// real-time priority, avoiding interference with CoreAudio real-time threads (audio pops).
    private let renderQueue = DispatchQueue(label: "spectrum.render", qos: .userInteractive)

    nonisolated func startDisplayLink() {
        guard displayLink == nil else { return }
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        displayLink = dl
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<AVFMetalView>.fromOpaque(userInfo).takeUnretainedValue()
            view.renderQueue.async { view.renderFrame() }
            return kCVReturnSuccess
        }, selfPtr)
        CVDisplayLinkStart(dl)
    }

    nonisolated func stopDisplayLink() {
        if let dl = displayLink { CVDisplayLinkStop(dl); displayLink = nil }
    }

    // MARK: - Render frame

    /// Detect Metal texture formats for biplanar YCbCr pixel buffer (8-bit vs 10-bit).
    nonisolated private func biplanarFormats(for pixelBuffer: CVPixelBuffer) -> (MTLPixelFormat, MTLPixelFormat) {
        let bpp = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / max(1, CVPixelBufferGetWidthOfPlane(pixelBuffer, 0))
        if bpp >= 2 { return (.r16Unorm, .rg16Unorm) }     // 10-bit
        return (.r8Unorm, .rg8Unorm)                         // 8-bit
    }

    nonisolated private func renderFrame() {
        guard !waitingForGyro else { return }
        guard !avfLayerMode else { return }  // AVPlayerLayer handles rendering
        guard let output = videoOutput else { return }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }

        var presentationTime = CMTime.zero
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime,
                                                        itemTimeForDisplay: &presentationTime) else { return }
        let pts = CMTimeGetSeconds(presentationTime)
        lastPTS = pts
        currentTime = pts

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)

        frameCount += 1

        // Auto-correct colorspace from first frame's pixel buffer attachments
        if frameCount == 1 {
            if let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any] {
                if !videoInfo.isDolbyVision, let tf = attachments["CVImageBufferTransferFunction"] as? String {
                    if tf.contains("HLG") && !layerColorspaceInfo.contains("HLG") {
                        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                        metalLayer.wantsExtendedDynamicRangeContent = true
                        decodeMode = 0
                    } else if (tf.contains("2084") || tf.contains("PQ")) && !layerColorspaceInfo.contains("PQ") {
                        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                        metalLayer.wantsExtendedDynamicRangeContent = true
                        decodeMode = 0
                    }
                }
            }
        }

        // Fetch gyro matrix for this exact PTS (synchronous on renderQueue)
        var hasGyroWarp = false
        if let core = gyroCore, core.isReady {
            let vH = Int(core.gyroVideoH)
            ensureMatTex(height: vH)
            if let (buf, changed) = core.computeMatrixAtTime(timeSec: pts) {
                if changed, let matTex {
                    let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                           size: MTLSize(width: 4, height: vH, depth: 1))
                    matTex.replace(region: region, mipmapLevel: 0,
                                   withBytes: buf.baseAddress!,
                                   bytesPerRow: 4 * 4 * MemoryLayout<Float>.size)
                }
                hasGyroWarp = true

                // Gyro Stability Index (diagnostics)
                if diagnosticsEnabled {
                    computeGyroSI(buf: buf, vH: vH)
                }
            }
        }

        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        if hasGyroWarp {
            // === Two-pass rendering ===
            // Pass 1: YCbCr -> RGB -> offscreen texture
            ensureOffscreenTexture(width: width, height: height)
            guard let offTex = offscreenTex else { return }

            let pass1Desc = MTLRenderPassDescriptor()
            pass1Desc.colorAttachments[0].texture = offTex
            pass1Desc.colorAttachments[0].loadAction = .dontCare
            pass1Desc.colorAttachments[0].storeAction = .store

            if let enc1 = cmdBuf.makeRenderCommandEncoder(descriptor: pass1Desc) {
                let (yFmt, cbcrFmt) = biplanarFormats(for: pixelBuffer)
                if planeCount >= 2,
                   let texY = makeTexture(from: pixelBuffer, plane: 0, format: yFmt),
                   let texCbCr = makeTexture(from: pixelBuffer, plane: 1, format: cbcrFmt) {
                    enc1.setRenderPipelineState(ycbcrPipeline)
                    enc1.setFragmentTexture(texY, index: 0)
                    enc1.setFragmentTexture(texCbCr, index: 1)
                    var mode = decodeMode
                    enc1.setFragmentBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)
                }
                var rot = videoRotation
                enc1.setVertexBytes(&rot, length: MemoryLayout<UInt32>.size, index: 0)
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

                var uniforms = WarpUniforms()
                uniforms.videoSize = SIMD2<Float>(core.gyroVideoW, core.gyroVideoH)
                uniforms.matCount = core.gyroVideoH
                uniforms.fIn = SIMD2<Float>(core.frameFx, core.frameFy)
                uniforms.cIn = SIMD2<Float>(core.frameCx, core.frameCy)
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

                enc2.setFragmentBytes(&uniforms, length: MemoryLayout<WarpUniforms>.size, index: 0)
                var rot2: UInt32 = 0
                enc2.setVertexBytes(&rot2, length: MemoryLayout<UInt32>.size, index: 0)
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
                        var rot = videoRotation
                        encoder.setVertexBytes(&rot, length: MemoryLayout<UInt32>.size, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                } else {
                    if let tex = makeTexture(from: pixelBuffer, plane: 0, format: .bgra8Unorm) {
                        let viewport = aspectFitViewport(videoW: width, videoH: height,
                                                          drawableW: Int(drawable.texture.width),
                                                          drawableH: Int(drawable.texture.height))
                        encoder.setViewport(viewport)
                        encoder.setRenderPipelineState(bgraPipeline)
                        encoder.setFragmentTexture(tex, index: 0)
                        var rot = videoRotation
                        encoder.setVertexBytes(&rot, length: MemoryLayout<UInt32>.size, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                }
                encoder.endEncoding()
            }
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()

        // FPS / CV measurement (diagnostics only)
        if diagnosticsEnabled {
            measureFrameTiming()
        }
    }

    // MARK: - Helpers

    nonisolated private func makeTexture(from pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MTLTexture? {
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

    nonisolated private func aspectFitViewport(videoW: Int, videoH: Int, drawableW: Int, drawableH: Int) -> MTLViewport {
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

    nonisolated private func measureFrameTiming() {
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt < 2.0 {
                frameIntervals.append(dt)
                if frameIntervals.count > 60 { frameIntervals.removeFirst() }
                if frameIntervals.count >= 5 {
                    let mean = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                    renderFPS = mean > 0 ? 1.0 / mean : 0
                    // Coefficient of variation
                    let variance = frameIntervals.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(frameIntervals.count)
                    let stddev = variance.squareRoot()
                    renderCV = mean > 0 ? stddev / mean : 0
                    renderStability = max(0, 1 - renderCV)
                }
            }
        }
        lastFrameTime = now
    }

    nonisolated private func computeGyroSI(buf: UnsafeBufferPointer<Float>, vH: Int) {
        let midRow = vH / 2
        let base = midRow * 16
        let cur = (buf[base+0], buf[base+1], buf[base+2],
                   buf[base+4], buf[base+5], buf[base+6],
                   buf[base+8], buf[base+9], buf[base+10])
        if let prev = prevMidRow {
            // Relative rotation: R_delta = R_cur * R_prev^T
            // Angle = acos((trace(R_delta) - 1) / 2)
            let trace = (prev.0*cur.0 + prev.1*cur.1 + prev.2*cur.2) +
                        (prev.3*cur.3 + prev.4*cur.4 + prev.5*cur.5) +
                        (prev.6*cur.6 + prev.7*cur.7 + prev.8*cur.8)
            let cosAngle = min(1, max(-1, (Double(trace) - 1) / 2))
            let angle = acos(cosAngle)
            siAngles.append(angle)
            if siAngles.count > 120 { siAngles.removeFirst() }
            if siAngles.count >= 5 {
                let rms = (siAngles.reduce(0) { $0 + $1 * $1 } / Double(siAngles.count)).squareRoot()
                gyroSI = rms
            }
        }
        prevMidRow = cur
    }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl); displayLink = nil }
        player?.pause()
        if let obs = eofObserver { NotificationCenter.default.removeObserver(obs) }
    }
}
