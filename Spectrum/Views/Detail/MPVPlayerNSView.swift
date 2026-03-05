import SwiftUI

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
        mpvLayer.setMute(false)   // Unmute (MDK starts muted)
        mpvLayer.setPause(false)  // Play immediately (deferred from user press)
    }

    func stop() {
        controller?.stopPolling()
        mpvLayer.stop()
        stopScope()
        currentPath = nil
    }

    // Gyro stabilization pass-through
    nonisolated func loadGyroCore(_ core: GyroCoreProvider?) {
        mpvLayer.loadGyroCore(core)
    }
    /// Suppress rendering until gyro is ready — prevents unstabilized first-frame flash.
    nonisolated func setWaitingForGyro(_ waiting: Bool) {
        mpvLayer.waitingForGyro = waiting
    }

    // CVDisplayLink pass-through
    nonisolated func startDisplayLink() { mpvLayer.startDisplayLink() }
    nonisolated func stopDisplayLink() { mpvLayer.stopDisplayLink() }

    // HDR toggle pass-through
    func applyHDR(showHDR: Bool, hdrType: VideoHDRType?) {
        mpvLayer.applyHDRSettings(showHDR: showHDR, hdrType: hdrType)
    }

    // Diagnostics pass-through
    nonisolated var diagnosticsEnabled: Bool {
        get { mpvLayer.diagnosticsEnabled }
        set { mpvLayer.diagnosticsEnabled = newValue }
    }

    // Playback pass-throughs — nonisolated for poll queue access.
    nonisolated var isPaused: Bool { mpvLayer.isPaused }
    nonisolated var isEOFReached: Bool { mpvLayer.isEOFReached }
    nonisolated var currentTime: Double { mpvLayer.currentTime }
    nonisolated var videoDuration: Double { mpvLayer.videoDuration }
    nonisolated var renderFPS: Double { mpvLayer.renderFPS }
    nonisolated var renderCV: Double { mpvLayer.renderCV }
    nonisolated var renderStability: Double { mpvLayer.renderStability }
    nonisolated var gyroSI: Double { mpvLayer.gyroSI }
    nonisolated var videoFPS: Double { mpvLayer.videoFPS }
    nonisolated var layerColorspaceInfo: String { mpvLayer.layerColorspaceInfo }
    nonisolated var mdkColorspaceInfo: String { mpvLayer.mdkColorspaceInfo }
    nonisolated func setPause(_ paused: Bool) { mpvLayer.setPause(paused) }
    nonisolated func seek(to seconds: Double) { mpvLayer.seek(to: seconds) }

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
        // Apply HDR toggle state (no-op if unchanged; re-renders on option change)
        nsView.applyHDR(showHDR: showHDR, hdrType: hdrType)
    }

    static func dismantleNSView(_ nsView: MPVPlayerNSView, coordinator: ()) {
        nsView.stop()
    }
}
