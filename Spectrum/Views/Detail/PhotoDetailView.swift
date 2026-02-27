import SwiftUI
import SwiftData
import AVKit

// MARK: - PhotoDetailView

struct PhotoDetailView: View {
    let photo: Photo
    @Binding var showInspector: Bool
    @Binding var isHDR: Bool
    var viewModel: LibraryViewModel?
    @Query private var folders: [ScannedFolder]
    @State private var image: NSImage?
    @State private var showHDR: Bool = true
    @State private var zoomLevel: CGFloat = 1.0
    @State private var containerSize: CGSize = .zero
    @State private var player: AVPlayer?
    @State private var videoHDRType: VideoHDRType?
    @State private var videoHDRComposition: AVVideoComposition?
    @State private var videoSDRComposition: AVVideoComposition?
    @State private var hdrFormat: HDRFormat?
    @State private var hlgCGImage: CGImage?
    @State private var useMPV = false
    @State private var mpvController = MPVController()
    @State private var mpvControlsVisible = true
    @State private var mpvHideTask: Task<Void, Never>? = nil
    @State private var mpvBarOffset: CGSize = .zero
    @State private var mpvBarDragStart: CGSize = .zero
    // AVPlayer custom UI
    @State private var avController = AVPlayerController()
    @State private var avControlsVisible = true
    @State private var avHideTask: Task<Void, Never>? = nil
    @State private var avBarOffset: CGSize = .zero
    @State private var avBarDragStart: CGSize = .zero
    @State private var videoStarted = false
    // Shared
    @State private var spaceKeyMonitor: Any?
    @AppStorage("showMPVDiagBadge") private var showMPVDiagBadge: Bool = true
    @AppStorage("playerForSDR") private var playerForSDR: String = "libmpv"
    @AppStorage("playerForHLG") private var playerForHLG: String = "libmpv"
    @AppStorage("playerForHDR10") private var playerForHDR10: String = "libmpv"
    @AppStorage("playerForDolbyVision") private var playerForDV: String = "avplayer"
    @AppStorage("playerForSLog2") private var playerForSLog2: String = "libmpv"
    @AppStorage("playerForSLog3") private var playerForSLog3: String = "libmpv"
    @AppStorage("gyroStabEnabled") private var gyroStabEnabled: Bool = true
    @AppStorage("gyroSmooth") private var gyroSmooth: Double = 0.5
    @AppStorage("gyroOffsetMs") private var gyroOffsetMs: Double = 0
    @AppStorage("gyroLensPath") private var gyroLensPath: String = ""
    @AppStorage("gyroIntegrationMethod") private var gyroIntegrationMethod: Int = 2
    @AppStorage("gyroImuOrientation") private var gyroImuOrientation: String = "YXz"
    @AppStorage("gyroFov") private var gyroFov: Double = 1.0
    @AppStorage("gyroLensCorrectionAmount") private var gyroLensCorrectionAmount: Double = 1.0
    @AppStorage("gyroZoomingMethod") private var gyroZoomingMethod: Int = 1
    @AppStorage("gyroAdaptiveZoom") private var gyroAdaptiveZoom: Double = 4.0
    @AppStorage("gyroMaxZoom") private var gyroMaxZoom: Double = 130.0
    @AppStorage("gyroMaxZoomIterations") private var gyroMaxZoomIterations: Int = 5
    @AppStorage("gyroUseGravityVectors") private var gyroUseGravityVectors: Bool = false
    @AppStorage("gyroVideoSpeed") private var gyroVideoSpeed: Double = 1.0
    @AppStorage("gyroHorizonLockAmount") private var gyroHorizonLockAmount: Double = 0
    @AppStorage("gyroHorizonLockRoll") private var gyroHorizonLockRoll: Double = 0
    @AppStorage("gyroPerAxis") private var gyroPerAxis: Bool = false
    @AppStorage("gyroSmoothnessPitch") private var gyroSmoothnessPitch: Double = 0
    @AppStorage("gyroSmoothnessYaw") private var gyroSmoothnessYaw: Double = 0
    @AppStorage("gyroSmoothnessRoll") private var gyroSmoothnessRoll: Double = 0

    private var bookmarkData: Data? {
        photo.resolveBookmarkData(from: folders)
    }

    var body: some View {
        Group {
            if photo.isVideo {
                videoContent
            } else {
                imageContent
            }
        }
        .background(.black)
        .focusedSceneValue(\.mpvPlayPause, useMPV ? mpvController.togglePlayPause : nil)
        .onChange(of: useMPV) { _, active in
            if active {
                mpvController.diagnosticsEnabled = showMPVDiagBadge
            }
        }
        .onChange(of: showMPVDiagBadge) { _, enabled in
            mpvController.diagnosticsEnabled = enabled
        }
        .onChange(of: photo.gyroConfigJson) { _, _ in
            guard useMPV, mpvController.gyroStabEnabled else { return }
            mpvController.stopGyroStab()
            let fps = mpvController.videoFPS > 0 ? mpvController.videoFPS : 30.0
            let lens: String? = gyroLensPath.isEmpty ? nil : gyroLensPath
            mpvController.startGyroStab(videoPath: photo.filePath, fps: fps,
                                        config: buildGyroConfig(), lensPath: lens)
        }
        .onDisappear {
            removeSpaceMonitor()
            player?.pause()
            avController.detach()
        }
        .task(id: photo.filePath) {
            if photo.isVideo {
                await loadVideo()
            } else {
                await loadFullImage()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if !photo.isVideo {
                    Button {
                        zoomLevel = 1.0
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Fit to Window")

                    Button {
                        if let image, containerSize.width > 0 {
                            let fitScale = min(
                                containerSize.width / image.size.width,
                                containerSize.height / image.size.height
                            )
                            zoomLevel = 1.0 / fitScale
                        }
                    } label: {
                        Image(systemName: "1.magnifyingglass")
                    }
                    .help("Actual Size")

                    Button {
                        zoomLevel = min(zoomLevel * 1.5, 10.0)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom In")

                    Button {
                        zoomLevel = max(zoomLevel / 1.5, 0.1)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom Out")

                }

                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("Toggle Inspector")
            }
        }
        .navigationTitle(photo.fileName)
    }

    @ViewBuilder
    private var videoContent: some View {
        activeVideoContent
    }

    /// Active video player (mpv or AVPlayer) — created only after user presses play.
    @ViewBuilder
    private var activeVideoContent: some View {
        if useMPV {
            ZStack(alignment: .bottom) {
                MPVPlayerView(path: photo.filePath, bookmarkData: bookmarkData,
                              controller: mpvController,
                              hdrType: videoHDRType,
                              showHDR: showHDR)

                if showMPVDiagBadge {
                    mpvDiagBadge
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if mpvControlsVisible {
                    MPVControlBar(controller: mpvController)
                        .frame(maxWidth: 480)
                        .offset(mpvBarOffset)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    mpvBarOffset = CGSize(
                                        width:  mpvBarDragStart.width  + v.translation.width,
                                        height: mpvBarDragStart.height + v.translation.height
                                    )
                                    resetMPVControlsTimer()
                                }
                                .onEnded { v in
                                    mpvBarOffset = CGSize(
                                        width:  mpvBarDragStart.width  + v.translation.width,
                                        height: mpvBarDragStart.height + v.translation.height
                                    )
                                    mpvBarDragStart = mpvBarOffset
                                }
                        )
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: mpvControlsVisible)
            .onContinuousHover { phase in
                if case .active = phase { resetMPVControlsTimer() }
            }
            .onAppear { resetMPVControlsTimer() }
        } else {
            ZStack(alignment: .bottom) {
                if let player {
                    HDRVideoPlayerView(player: player)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if showMPVDiagBadge {
                    avDiagBadge
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if avControlsVisible {
                    AVPlayerControlBar(controller: avController)
                        .frame(maxWidth: 480)
                        .offset(avBarOffset)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    avBarOffset = CGSize(
                                        width:  avBarDragStart.width  + v.translation.width,
                                        height: avBarDragStart.height + v.translation.height
                                    )
                                    resetAVControlsTimer()
                                }
                                .onEnded { v in
                                    avBarOffset = CGSize(
                                        width:  avBarDragStart.width  + v.translation.width,
                                        height: avBarDragStart.height + v.translation.height
                                    )
                                    avBarDragStart = avBarOffset
                                }
                        )
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: avControlsVisible)
            .onContinuousHover { phase in
                if case .active = phase { resetAVControlsTimer() }
            }
            .onAppear { resetAVControlsTimer() }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        GeometryReader { geometry in
            if let image {
                let imageSize = image.size
                let fitScale = min(
                    geometry.size.width / imageSize.width,
                    geometry.size.height / imageSize.height
                )
                let displayWidth = imageSize.width * fitScale * zoomLevel
                let displayHeight = imageSize.height * fitScale * zoomLevel

                ZStack(alignment: .topLeading) {
                    ScrollView([.horizontal, .vertical]) {
                        Group {
                            if let hlgCGImage, showHDR, hdrFormat == .hlg {
                                // mpv-style: CALayer with explicit itur_2100_HLG colorspace + EDR hierarchy
                                HLGImageView(cgImage: hlgCGImage)
                            } else {
                                // Gain Map / SDR / HLG-SDR-toggle: NSImageView path
                                HDRImageView(image: image, dynamicRange: imageDynamicRange)
                            }
                        }
                        .frame(width: displayWidth, height: displayHeight)
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height
                        )
                    }
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: photo.filePath)])
                        }
                    }

                    if isHDR && showMPVDiagBadge {
                        Button { showHDR.toggle() } label: { hdrBadge }
                            .buttonStyle(.plain)
                            .help(showHDR ? "Switch to SDR" : "Switch to HDR")
                            .padding(12)
                    }
                }
                .onAppear { containerSize = geometry.size }
                .onChange(of: geometry.size) { _, newSize in containerSize = newSize }
            } else {
                ProgressView("Loading...")
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onAppear { containerSize = geometry.size }
            }
        }
    }

    @ViewBuilder
    private var avDiagBadge: some View {
        let cv        = avController.renderCV
        let dotColor: Color = cv < 0.05 ? .green : cv < 0.15 ? .yellow : .red
        let videoFPS  = avController.videoFPS
        let renderFPS = avController.renderFPS

        Button {
            if isHDR {
                showHDR.toggle()
                applyVideoDynamicRange()
            }
        } label: {
            VStack(alignment: .trailing, spacing: 3) {
                // Top line: HDR/SDR state + codec
                HStack(spacing: 4) {
                    if let hdrType = videoHDRType {
                        Text(showHDR ? hdrType.rawValue : "SDR")
                            .foregroundStyle(showHDR ? .orange : .secondary)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(avController.codecInfo)
                }

                // Bottom line: render fps / video fps + CV dot
                HStack(spacing: 4) {
                    Circle()
                        .fill(renderFPS > 0 ? dotColor : .secondary)
                        .frame(width: 6, height: 6)
                    if videoFPS > 0 {
                        Text(String(format: "%.1f/%.0f fps", renderFPS, videoFPS))
                    } else {
                        Text(String(format: "%.1f fps", renderFPS))
                    }
                    Text("CV \(String(format: "%.3f", cv))")
                        .foregroundStyle(dotColor)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
            .padding(8)
        }
        .buttonStyle(.plain)
        .help(isHDR ? (showHDR ? "Switch to SDR" : "Switch to HDR") : "")
    }

    @ViewBuilder
    private var mpvDiagBadge: some View {
        // Same thresholds as testmpv: green CV<0.05, yellow CV<0.15, red CV≥0.15
        let cv = mpvController.renderCV
        let dotColor: Color = cv < 0.05 ? .green : cv < 0.15 ? .yellow : .red
        let videoFPS = mpvController.videoFPS
        let renderFPS = mpvController.renderFPS

        VStack(alignment: .trailing, spacing: 4) {
            // Toggle pills — separate row so they look clearly interactive
            HStack(spacing: 4) {
                if let hdrType = videoHDRType {
                    togglePill(label: showHDR ? hdrType.rawValue : "SDR",
                               active: showHDR, color: .orange) {
                        showHDR.toggle()
                    }
                }
                if mpvController.gyroAvailable {
                    togglePill(label: "GYRO",
                               active: mpvController.gyroStabEnabled, color: .green) {
                        toggleGyroStab()
                    }
                }
            }

            Text(mpvController.hwdecInfo)

            HStack(spacing: 4) {
                Circle()
                    .fill(renderFPS > 0 ? dotColor : .secondary)
                    .frame(width: 6, height: 6)
                if videoFPS > 0 {
                    Text(String(format: "%.1f/%.0f fps", renderFPS, videoFPS))
                } else {
                    Text(String(format: "%.1f fps", renderFPS))
                }
                Text("CV \(String(format: "%.3f", mpvController.renderCV))")
                    .foregroundStyle(dotColor)
            }

            Text("↓ vo:\(mpvController.droppedFrames) dec:\(mpvController.decoderDroppedFrames)")
                .foregroundStyle(
                    mpvController.droppedFrames > 0 || mpvController.decoderDroppedFrames > 0
                    ? .orange : .secondary
                )

            if mpvController.gyroStabEnabled {
                Text("gyro \(String(format: "%.2f", mpvController.gyroComputeMs))ms")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
        .padding(8)
    }

    private func togglePill(label: String, active: Bool, color: Color,
                            action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(active ? .white : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(active ? color.opacity(0.8) : Color.secondary.opacity(0.2),
                        in: Capsule())
            .onTapGesture(perform: action)
    }

    private func buildGyroConfig() -> GyroConfig {
        // Per-video override takes priority
        if let json = photo.gyroConfigJson,
           let data = json.data(using: .utf8),
           let config = try? JSONDecoder().decode(GyroConfig.self, from: data) {
            return config
        }
        // Fallback to global settings
        return GyroConfig(
            smooth:               gyroSmooth,
            gyroOffsetMs:         gyroOffsetMs,
            integrationMethod:    gyroIntegrationMethod,
            imuOrientation:       gyroImuOrientation,
            fov:                  gyroFov,
            lensCorrectionAmount: gyroLensCorrectionAmount,
            zoomingMethod:        gyroZoomingMethod,
            adaptiveZoom:         gyroAdaptiveZoom,
            maxZoom:              gyroMaxZoom,
            maxZoomIterations:    gyroMaxZoomIterations,
            useGravityVectors:    gyroUseGravityVectors,
            videoSpeed:           gyroVideoSpeed,
            horizonLockAmount:    gyroHorizonLockAmount,
            horizonLockRoll:      gyroHorizonLockRoll,
            perAxis:              gyroPerAxis,
            smoothnessPitch:      gyroSmoothnessPitch,
            smoothnessYaw:        gyroSmoothnessYaw,
            smoothnessRoll:       gyroSmoothnessRoll
        )
    }

    private func toggleGyroStab() {
        if mpvController.gyroStabEnabled {
            mpvController.stopGyroStab()
        } else {
            let fps = mpvController.videoFPS > 0 ? mpvController.videoFPS : 30.0
            let lens = gyroLensPath.isEmpty ? nil : gyroLensPath
            mpvController.startGyroStab(videoPath: photo.filePath, fps: fps,
                                        config: buildGyroConfig(), lensPath: lens)
        }
    }

    private var isHLGImage: Bool { hdrFormat == .hlg }

    private var imageDynamicRange: NSImage.DynamicRange {
        showHDR && isHDR ? .high : .standard
    }

    private var hdrBadgeLabel: String {
        if let videoType = videoHDRType {
            return videoType.rawValue
        }
        return hdrFormat?.badgeLabel ?? "HDR"
    }

    private var hdrBadge: some View {
        HStack(spacing: 6) {
            Text(hdrBadgeLabel)
                .font(.caption.bold())
                .foregroundStyle(showHDR ? .orange : .secondary)
            if isHLGImage {
                let edr = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
                Text("EDR \(String(format: "%.1f", edr))x")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let headroom = photo.headroom {
                Text("Headroom \(String(format: "%.1f", headroom))x")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(showHDR ? .orange.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Loading

    /// Load video: reset state and immediately start the player.
    private func loadVideo() async {
        // Reset all player state from previous video
        player?.pause()
        avController.detach()
        player = nil
        isHDR = false
        showHDR = true
        hdrFormat = nil
        videoHDRType = nil
        videoHDRComposition = nil
        videoSDRComposition = nil
        useMPV = false
        videoStarted = false
        mpvController.reset()
        mpvHideTask?.cancel()
        mpvControlsVisible = true
        mpvBarOffset = .zero
        mpvBarDragStart = .zero
        avHideTask?.cancel()
        avControlsVisible = true
        avBarOffset = .zero
        avBarDragStart = .zero
        removeSpaceMonitor()

        // Start playback immediately (no thumbnail preview phase)
        startPlayback()
    }

    /// Resolve per-type player preference: returns `"libmpv"` or `"avplayer"`.
    private func resolvedPlayer(for hdrType: VideoHDRType?) -> String {
        switch hdrType {
        case .hlg:          return playerForHLG
        case .hdr10:        return playerForHDR10
        case .dolbyVision:  return playerForDV
        case .slog2:        return playerForSLog2
        case .slog3:        return playerForSLog3
        case nil:           return playerForSDR
        }
    }

    /// Load the player (paused on first frame; user presses Space to play).
    private func startPlayback() {
        guard !videoStarted else { return }
        videoStarted = true

        Task {
            let path = photo.filePath
            let bookmark = bookmarkData

            // 1. Lightweight HDR type detection (~50ms, no AVPlayer created)
            let detectedType = await ImagePreloadCache.detectVideoHDRType(path: path, bookmarkData: bookmark)
            videoHDRType = detectedType
            isHDR = detectedType != nil

            // 2. Resolve which player to use based on per-type setting
            let resolved = resolvedPlayer(for: detectedType)
            let preferMPV = resolved == "libmpv" && LibMPV.shared.ok

            if preferMPV {
                mpvController.diagnosticsEnabled = showMPVDiagBadge
                useMPV = true
                // Start gyro loading immediately (in parallel with SwiftUI creating
                // the MPVPlayerView). By the time the user presses Space, gyro will
                // already be ready. Previously gyro only started on first Space press,
                // which had a one-shot gyroLaunched flag that prevented retries on failure.
                if gyroStabEnabled && GyroCore.dylibFound {
                    let cfg = buildGyroConfig()
                    let lens: String? = gyroLensPath.isEmpty ? nil : gyroLensPath
                    mpvController.startGyroStab(videoPath: path, fps: 30,
                                                config: cfg, lensPath: lens)
                }
            } else {
                // AVPlayer path: full load (creates player + compositions)
                guard let entry = await ImagePreloadCache.loadVideoEntry(path: path, bookmarkData: bookmark) else { return }
                player = entry.player
                videoHDRComposition = entry.hdrComposition
                videoSDRComposition = entry.sdrComposition
                applyVideoDynamicRange()
                avController.attach(player: entry.player)
                resetAVControlsTimer()
            }

            // Install key monitor with full playback controls
            installActiveKeyMonitor()
        }
    }

    /// Install key monitor with full playback controls (called after startPlayback).
    private func installActiveKeyMonitor() {
        removeSpaceMonitor()
        let isMPV = useMPV
        let mpv   = mpvController
        let av    = avController
        let gyroCfg = buildGyroConfig()
        let lens: String? = gyroLensPath.isEmpty ? nil : gyroLensPath
        let gyroToggle: () -> Void = { [mpv, photo] in
            if mpv.gyroStabEnabled {
                mpv.stopGyroStab()
            } else {
                let fps = mpv.videoFPS > 0 ? mpv.videoFPS : 30.0
                mpv.startGyroStab(videoPath: photo.filePath, fps: fps,
                                  config: gyroCfg, lensPath: lens)
            }
        }
        let inspectorToggle: () -> Void = { [self] in self.showInspector.toggle() }
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard bare else { return event }
            switch event.charactersIgnoringModifiers {
            case " ":
                // Gyro is started early in startPlayback() — Space only toggles play/pause.
                if isMPV { mpv.togglePlayPause() } else { av.togglePlayPause() }
                return nil
            case "f":
                NSApp.keyWindow?.toggleFullScreen(nil)
                return nil
            case "s":
                gyroToggle()
                return nil
            case "i":
                inspectorToggle()
                return nil
            default:
                return event
            }
        }
    }

    private func removeSpaceMonitor() {
        if let m = spaceKeyMonitor { NSEvent.removeMonitor(m); spaceKeyMonitor = nil }
    }

    private func resetAVControlsTimer() {
        avHideTask?.cancel()
        if !avControlsVisible {
            withAnimation(.easeIn(duration: 0.15)) { avControlsVisible = true }
        }
        avHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { avControlsVisible = false }
        }
    }

    private func resetMPVControlsTimer() {
        mpvHideTask?.cancel()
        if !mpvControlsVisible {
            withAnimation(.easeIn(duration: 0.15)) { mpvControlsVisible = true }
        }
        mpvHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { mpvControlsVisible = false }
        }
    }

    private func applyVideoDynamicRange() {
        guard let playerItem = player?.currentItem else { return }
        playerItem.videoComposition = showHDR ? videoHDRComposition : videoSDRComposition
    }

    private func loadFullImage() async {
        zoomLevel = 1.0
        showHDR = true
        isHDR = false
        hdrFormat = nil
        hlgCGImage = nil

        let path = photo.filePath

        // Use cached thumbnail immediately (nonisolated, no actor wait) to avoid
        // black screen when the ThumbnailService actor is busy generating grid thumbnails.
        image = ThumbnailService.shared.cachedThumbnail(for: path)

        // Load full image directly — skip actor-bound thumbnail generation
        let bookmark = bookmarkData
        let entry = await ImagePreloadCache.loadImageEntry(path: path, bookmarkData: bookmark)

        image = entry.image
        hlgCGImage = entry.hlgCGImage
        hdrFormat = entry.hdrFormat
        isHDR = entry.hdrFormat != nil
    }
}
