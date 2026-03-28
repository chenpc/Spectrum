import SwiftUI

// MARK: - VideoPlayerNSView

class VideoPlayerNSView: NSView {
    private let metalView = AVFMetalView()
    private var currentPath: String?
    private var scopeURL: URL?
    private var scopeStarted = false
    weak var controller: VideoController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        metalView.frame = bounds
    }

    func load(path: String, bookmarkData: Data?) {
        guard path != currentPath else { return }
        stopScope()
        currentPath = path
        startScope(bookmarkData: bookmarkData)
        metalView.load(path: path)
    }

    func stop() {
        controller?.stopPolling()
        metalView.stop()
        stopScope()
        currentPath = nil
    }

    // Gyro stabilization pass-through
    nonisolated func loadGyroCore(_ core: GyroCoreProvider?) {
        metalView.loadGyroCore(core)
    }
    /// Suppress rendering until gyro is ready — prevents unstabilized first-frame flash.
    nonisolated func setWaitingForGyro(_ waiting: Bool) {
        metalView.waitingForGyro = waiting
    }

    // CVDisplayLink pass-through
    nonisolated func startDisplayLink() { metalView.startDisplayLink() }
    nonisolated func stopDisplayLink() { metalView.stopDisplayLink() }

    // HDR / colorspace / decode pass-through
    func setEDR(_ enabled: Bool) {
        metalView.setEDR(enabled)
    }
    func cycleColorspace() { metalView.cycleColorspace() }
    nonisolated func cycleDecodeMode() { metalView.cycleDecodeMode() }
    func setColorspace(index: Int) { metalView.setColorspace(index: index) }
    nonisolated func setDecodeMode(index: Int) { metalView.setDecodeMode(index: index) }

    // Diagnostics pass-through
    nonisolated var diagnosticsEnabled: Bool {
        get { metalView.diagnosticsEnabled }
        set { metalView.diagnosticsEnabled = newValue }
    }

    // Playback pass-throughs — nonisolated for poll queue access.
    nonisolated var isPaused: Bool { metalView.isPaused }
    nonisolated var isEOFReached: Bool { metalView.isEOFReached }
    nonisolated var currentTime: Double { metalView.currentTime }
    nonisolated var videoDuration: Double { metalView.videoDuration }
    nonisolated var renderFPS: Double { metalView.renderFPS }
    nonisolated var renderCV: Double { metalView.renderCV }
    nonisolated var renderStability: Double { metalView.renderStability }
    nonisolated var gyroSI: Double { metalView.gyroSI }
    nonisolated var videoFPS: Double { metalView.videoFPS }
    nonisolated var layerColorspaceInfo: String { metalView.layerColorspaceInfo }
    nonisolated var decodeColorspaceInfo: String { metalView.decodeColorspaceInfo }
    nonisolated var pixelFormatInfo: String { metalView.pixelFormatInfo }
    nonisolated var codecInfo: String? { metalView.codecInfo }
    nonisolated var colorSpaceInfo: String { metalView.colorSpaceInfo }
    nonisolated var isAVFLayerMode: Bool { metalView.isAVFLayerMode }
    nonisolated var isAnalyzing: Bool { metalView.isAnalyzing }
    nonisolated var isBuffering: Bool { metalView.isBuffering }
    nonisolated func setPause(_ paused: Bool) { metalView.setPause(paused) }
    nonisolated func seek(to seconds: Double) { metalView.seek(to: seconds) }
    nonisolated func setVolume(_ volume: Float) { metalView.setVolume(volume) }
    nonisolated func setMute(_ muted: Bool) { metalView.setMute(muted) }
    var currentVolume: Float { metalView.volume }
    var currentMuted: Bool { metalView.muted }

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

// MARK: - VideoPlayerView (SwiftUI)

struct VideoPlayerView: NSViewRepresentable {
    let path: String
    let bookmarkData: Data?
    let controller: VideoController
    var showEDR: Bool = true

    func makeNSView(context: Context) -> VideoPlayerNSView {
        let view = VideoPlayerNSView()
        view.controller = controller
        view.load(path: path, bookmarkData: bookmarkData)
        controller.startPolling(view: view)
        return view
    }

    func updateNSView(_ nsView: VideoPlayerNSView, context: Context) {
        controller.startPolling(view: nsView)   // idempotent if same view
        nsView.load(path: path, bookmarkData: bookmarkData)
        nsView.setEDR(showEDR)
    }

    static func dismantleNSView(_ nsView: VideoPlayerNSView, coordinator: ()) {
        nsView.stop()
    }
}
