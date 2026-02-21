import SwiftUI
import SwiftData
import AVKit

// MARK: - HDR NSImageView wrapper

private class FlexibleImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override var acceptsFirstResponder: Bool { false }
}

struct HDRImageView: NSViewRepresentable {
    let image: NSImage
    let dynamicRange: NSImage.DynamicRange

    func makeNSView(context: Context) -> NSImageView {
        let view = FlexibleImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = false
        view.isEditable = false
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = image
        nsView.preferredImageDynamicRange = dynamicRange
    }
}

// MARK: - HLG CALayer image view (mpv-style: explicit itur_2100_HLG colorspace + EDR hierarchy)

class HLGNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(cgImage: CGImage) {
        layer?.contents = cgImage
        enableEDR()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enableEDR()
    }

    private func enableEDR() {
        setEDRDown(layer)
        var current = layer?.superlayer
        while let l = current { setEDR(l); current = l.superlayer }
    }

    private func setEDR(_ l: CALayer) {
        if #available(macOS 26.0, *) {
            l.preferredDynamicRange = .high
        } else {
            l.wantsExtendedDynamicRangeContent = true
        }
    }

    private func setEDRDown(_ l: CALayer?) {
        guard let l else { return }
        setEDR(l)
        l.sublayers?.forEach { setEDRDown($0) }
    }
}

struct HLGImageView: NSViewRepresentable {
    let cgImage: CGImage

    func makeNSView(context: Context) -> HLGNSView { HLGNSView() }

    func updateNSView(_ nsView: HLGNSView, context: Context) { nsView.configure(cgImage: cgImage) }

}

// MARK: - HDR AVPlayerView wrapper

private class EDRPlayerView: AVPlayerView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enableEDR()
    }

    override func layout() {
        super.layout()
        enableEDR()
    }

    private func enableEDR() {
        setEDRDown(layer)
        var current = layer?.superlayer
        while let l = current {
            setEDR(l)
            current = l.superlayer
        }
    }

    private func setEDR(_ l: CALayer) {
        if #available(macOS 26.0, *) {
            l.preferredDynamicRange = .high
        } else {
            l.wantsExtendedDynamicRangeContent = true
        }
    }

    private func setEDRDown(_ l: CALayer?) {
        guard let l else { return }
        setEDR(l)
        l.sublayers?.forEach { setEDRDown($0) }
    }
}

struct HDRVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = EDRPlayerView()
        view.controlsStyle = .none          // custom control bar overlaid in SwiftUI
        view.allowsVideoFrameAnalysis = false
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

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
    // Shared
    @State private var spaceKeyMonitor: Any?
    @AppStorage("showMPVDiagBadge") private var showMPVDiagBadge: Bool = true
    @AppStorage("videoPlayer") private var videoPlayerPref: String = "libmpv"

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
        if useMPV {
            // mpv handles HLG HDR natively — correct brightness + colors without any toggle
            ZStack(alignment: .bottom) {
                MPVPlayerView(path: photo.filePath, bookmarkData: bookmarkData,
                              controller: mpvController,
                              hdrType: videoHDRType,
                              showHDR: showHDR)

                // HDR/SDR toggle badge — top-left (mirrors AVPlayer branch)
                if isHDR {
                    Button {
                        showHDR.toggle()
                        // MPVPlayerView.updateNSView picks up showHDR change automatically
                    } label: {
                        hdrBadge
                    }
                    .buttonStyle(.plain)
                    .help(showHDR ? "Switch to SDR" : "Switch to HDR")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                }

                // Diagnostics badge — top-right corner (hidden via Settings)
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
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // HDR badge — top-left
                if isHDR {
                    Button {
                        showHDR.toggle()
                        applyVideoDynamicRange()
                    } label: {
                        hdrBadge
                    }
                    .buttonStyle(.plain)
                    .help(showHDR ? "Switch to SDR" : "Switch to HDR")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                    .allowsHitTesting(true)
                }

                // Diagnostics badge — top-right
                if showMPVDiagBadge {
                    avDiagBadge
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                // Custom control bar — bottom centre, draggable
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

                    if isHDR {
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

        VStack(alignment: .trailing, spacing: 3) {
            // Top line: HDR type (if any) + codec
            HStack(spacing: 4) {
                if let hdrType = videoHDRType {
                    Text(hdrType.rawValue).foregroundStyle(.orange)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(avController.codecInfo)
            }

            // Bottom line: render fps / video fps + CV dot (same format as mpvDiagBadge)
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

    @ViewBuilder
    private var mpvDiagBadge: some View {
        // Same thresholds as testmpv: green CV<0.05, yellow CV<0.15, red CV≥0.15
        let cv = mpvController.renderCV
        let dotColor: Color = cv < 0.05 ? .green : cv < 0.15 ? .yellow : .red
        let videoFPS = mpvController.videoFPS
        let renderFPS = mpvController.renderFPS

        VStack(alignment: .trailing, spacing: 3) {
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

            if mpvController.droppedFrames > 0 {
                Text("↓ \(mpvController.droppedFrames) dropped")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
        .padding(8)
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

    private func loadVideo() async {
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
        mpvController.reset()
        mpvHideTask?.cancel()
        mpvControlsVisible = true
        mpvBarOffset = .zero
        mpvBarDragStart = .zero
        avHideTask?.cancel()
        avControlsVisible = true
        avBarOffset = .zero
        avBarDragStart = .zero

        let path = photo.filePath
        let bookmark = bookmarkData
        guard let entry = await ImagePreloadCache.loadVideoEntry(path: path, bookmarkData: bookmark) else { return }

        // Apple DV Profile 8.4 is HLG-decoded by VideoToolbox (hdrType=.dolbyVision but
        // actual pixels are HLG). Fall back to AVPlayer which handles Apple DV natively.
        let mpvCanHandle = entry.hdrType != .dolbyVision
        let preferMPV = videoPlayerPref == "libmpv" && LibMPV.shared.ok && mpvCanHandle

        if preferMPV {
            // libmpv: all formats; colorspace configured per hdrType in MPVOpenGLLayer
            mpvController.diagnosticsEnabled = showMPVDiagBadge
            useMPV = true
            installVideoKeyMonitor()
            // videoHDRType still useful for badge label even in mpv mode
            videoHDRType = entry.hdrType
            isHDR = entry.hdrType != nil
        } else {
            // AVPlayer: use custom control bar
            player = entry.player
            videoHDRType = entry.hdrType
            isHDR = entry.hdrType != nil
            videoHDRComposition = entry.hdrComposition
            videoSDRComposition = entry.sdrComposition
            applyVideoDynamicRange()
            avController.attach(player: entry.player)
            installVideoKeyMonitor()
            resetAVControlsTimer()
        }
    }

    /// Installs a local key monitor for Space → play/pause.
    /// macOS menu commands don't support bare Space, so we use NSEvent local monitor
    /// — same approach as IINA and VLC.
    private func installVideoKeyMonitor() {
        removeSpaceMonitor()
        let isMPV = useMPV
        let mpv   = mpvController
        let av    = avController
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,   // Space
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }
            if isMPV { mpv.togglePlayPause() } else { av.togglePlayPause() }
            return nil
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
        image = nil
        isHDR = false
        hdrFormat = nil
        hlgCGImage = nil

        let path = photo.filePath

        let thumbBookmark = bookmarkData
        if let thumb = await ThumbnailService.shared.thumbnail(for: path, bookmarkData: thumbBookmark),
           image == nil {
            image = thumb
        }

        let bookmark = bookmarkData
        let entry = await ImagePreloadCache.loadImageEntry(path: path, bookmarkData: bookmark)

        image = entry.image
        hlgCGImage = entry.hlgCGImage
        hdrFormat = entry.hdrFormat
        isHDR = entry.hdrFormat != nil
    }
}
