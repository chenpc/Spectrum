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
    @State private var selectedBackend: MPVOpenGLLayer.PlayerBackend = .mpv
    @State private var mpvController = MPVController()
    @State private var isCropMode = false
    @State private var editingCropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    @State private var activeCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var activeRotation: Int = 0
    @State private var activeFlipH: Bool = false
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
    @State private var posterFrame: CGImage?
    @State private var mpvPlaybackStarted = false
    // Gyro config (stored in XMP sidecar, not DB)
    @State private var gyroConfigJson: String?
    // Shared
    @State private var spaceKeyMonitor: Any?
    @State private var cursorHidden = false
    @AppStorage("showMPVDiagBadge") private var showMPVDiagBadge: Bool = true
    @AppStorage("playerForSDR") private var playerForSDR: String = "libmpv"
    @AppStorage("playerForHLG") private var playerForHLG: String = "libmpv"
    @AppStorage("playerForHDR10") private var playerForHDR10: String = "libmpv"
    @AppStorage("playerForDolbyVision") private var playerForDV: String = "libmpv"
    @AppStorage("playerForSLog2") private var playerForSLog2: String = "libmpv"
    @AppStorage("playerForSLog3") private var playerForSLog3: String = "libmpv"
    @AppStorage("gyroStabEnabled") private var gyroStabEnabled: Bool = true
    @AppStorage("gyroSmooth") private var gyroSmooth: Double = 0.5
    @AppStorage("gyroOffsetMs") private var gyroOffsetMs: Double = 0
    @AppStorage("gyroLensPath") private var gyroLensPath: String = ""
    @AppStorage("gyroIntegrationMethod") private var gyroIntegrationMethod: Int = -1
    @AppStorage("gyroImuOrientation") private var gyroImuOrientation: String = ""
    @AppStorage("gyroFov") private var gyroFov: Double = 1.0
    @AppStorage("gyroLensCorrectionAmount") private var gyroLensCorrectionAmount: Double = 1.0
    @AppStorage("gyroZoomingMethod") private var gyroZoomingMethod: Int = 1
    @AppStorage("gyroZoomingAlgorithm") private var gyroZoomingAlgorithm: Int = 1
    @AppStorage("gyroAdaptiveZoom") private var gyroAdaptiveZoom: Double = 4.0
    @AppStorage("gyroMaxZoom") private var gyroMaxZoom: Double = 130.0
    @AppStorage("gyroMaxZoomIterations") private var gyroMaxZoomIterations: Int = 5
    @AppStorage("gyroUseGravityVectors") private var gyroUseGravityVectors: Bool = false
    @AppStorage("gyroVideoSpeed") private var gyroVideoSpeed: Double = 1.0
    @AppStorage("gyroHorizonLockEnabled") private var gyroHorizonLockEnabled: Bool = false
    @AppStorage("gyroHorizonLockAmount") private var gyroHorizonLockAmount: Double = 1.0
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
        .focusedSceneValue(\.gyroConfigBinding, $gyroConfigJson)
        .focusedSceneValue(\.mpvController, useMPV ? mpvController : nil)
        .onChange(of: useMPV) { _, active in
            if active {
                mpvController.diagnosticsEnabled = showMPVDiagBadge
            }
        }
        .onChange(of: showMPVDiagBadge) { _, enabled in
            mpvController.diagnosticsEnabled = enabled
        }
        .onChange(of: mpvController.isPlaying) { _, playing in
            if playing && !mpvPlaybackStarted {
                mpvPlaybackStarted = true
            }
        }
        .onChange(of: gyroConfigJson) { _, _ in
            writeXMPSidecar()
            guard useMPV, mpvController.gyroStabEnabled else { return }
            mpvController.stopGyroStab()
            let fps = mpvController.videoFPS > 0 ? mpvController.videoFPS : 30.0
            let lens: String? = gyroLensPath.isEmpty ? nil : gyroLensPath
            mpvController.startGyroStab(videoPath: photo.filePath, fps: fps,
                                        config: buildGyroConfig(), lensPath: lens)
        }
        .onDisappear {
            removeSpaceMonitor()
            showCursor()
            player?.pause()
            avController.detach()
        }
        .task(id: photo.filePath) {
            isCropMode = false
            if photo.isVideo {
                await loadVideo()
            } else {
                await loadFullImage()
                installImageKeyMonitor()
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

                    Divider()

                    Button { enterCropMode() } label: {
                        Image(systemName: "crop")
                    }
                    .help("Crop")
                    .disabled(isCropMode)

                    Button { rotateLeft() } label: {
                        Image(systemName: "rotate.left")
                    }
                    .help("Rotate Left")
                    .disabled(isCropMode)

                    Button { flipHorizontal() } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .help("Flip Horizontal")
                    .disabled(isCropMode)

                    if !photo.editOps.isEmpty {
                        Button { restoreEdits() } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .help("Restore Original")
                        .disabled(isCropMode)
                    }
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
                if mpvPlaybackStarted {
                    MPVPlayerView(path: photo.filePath, bookmarkData: bookmarkData,
                                  controller: mpvController,
                                  hdrType: videoHDRType,
                                  showHDR: showHDR,
                                  backend: selectedBackend)
                } else if let posterFrame {
                    Image(decorative: posterFrame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

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

    private var isTransposed: Bool { activeRotation == 90 || activeRotation == 270 }

    @ViewBuilder
    private var imageContent: some View {
        GeometryReader { geometry in
            if let image {
                let imageSize = image.size
                // Rotated dimensions
                let rotatedW = isTransposed ? imageSize.height : imageSize.width
                let rotatedH = isTransposed ? imageSize.width : imageSize.height
                let cropW = rotatedW * activeCrop.width
                let cropH = rotatedH * activeCrop.height
                let fitScale = min(geometry.size.width / cropW, geometry.size.height / cropH)
                let displayZoom: CGFloat = isCropMode ? 1.0 : zoomLevel
                // Original (pre-rotation) dimensions at fitScale
                let origW = imageSize.width * fitScale * displayZoom
                let origH = imageSize.height * fitScale * displayZoom
                // Rotated dimensions at fitScale
                let fullW = rotatedW * fitScale * displayZoom
                let fullH = rotatedH * fitScale * displayZoom
                let cropDisplayW = cropW * fitScale * displayZoom
                let cropDisplayH = cropH * fitScale * displayZoom

                ZStack {
                    ScrollView([.horizontal, .vertical]) {
                        Group {
                            if let hlgCGImage, showHDR, hdrFormat == .hlg {
                                HLGImageView(cgImage: hlgCGImage)
                            } else {
                                HDRImageView(image: image, dynamicRange: imageDynamicRange)
                            }
                        }
                        .frame(width: origW, height: origH)
                        .scaleEffect(x: activeFlipH ? -1 : 1, y: 1)
                        .rotationEffect(.degrees(Double(activeRotation)))
                        .frame(width: fullW, height: fullH)
                        .offset(
                            x: -activeCrop.minX * fullW,
                            y: -activeCrop.minY * fullH
                        )
                        .frame(width: cropDisplayW, height: cropDisplayH, alignment: .topLeading)
                        .clipped()
                        .contentShape(Rectangle())
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height
                        )
                    }
                    .scrollDisabled(isCropMode)
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: photo.filePath)])
                        }
                    }

                    if isCropMode {
                        CropOverlayView(
                            cropRect: $editingCropRect,
                            imagePixelWidth: isTransposed ? photo.pixelHeight : photo.pixelWidth,
                            imagePixelHeight: isTransposed ? photo.pixelWidth : photo.pixelHeight,
                            onApply: applyCrop,
                            onCancel: cancelCrop
                        )
                        .frame(width: fullW, height: fullH)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isHDR && showMPVDiagBadge && !isCropMode {
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

    // MARK: - Rotate actions

    private func rotateLeft() {
        var ops = photo.editOps
        ops.append(.rotate(-90))
        photo.editOps = ops
        writeXMPSidecar()
        applyCompositeState()
    }

    private func flipHorizontal() {
        var ops = photo.editOps
        ops.append(.flipH)
        photo.editOps = ops
        writeXMPSidecar()
        applyCompositeState()
    }

    /// Update active display state from the photo's composite edit.
    private func applyCompositeState() {
        let c = photo.compositeEdit
        activeRotation = c.rotation
        activeFlipH = c.flipH
        if let crop = c.crop {
            activeCrop = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
        } else {
            activeCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    // MARK: - Crop actions

    private func enterCropMode() {
        if let existing = photo.compositeEdit.crop {
            editingCropRect = CGRect(
                x: existing.x, y: existing.y,
                width: existing.width, height: existing.height
            )
        } else {
            editingCropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        }
        zoomLevel = 1.0
        withAnimation(.easeInOut(duration: 0.4)) {
            activeCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
            isCropMode = true
        }
    }

    private func applyCrop() {
        let crop = CropRect(
            x: editingCropRect.origin.x,
            y: editingCropRect.origin.y,
            width: editingCropRect.width,
            height: editingCropRect.height
        )
        // Remove last .crop op if any, then append the new one
        var ops = photo.editOps.filter { if case .crop = $0 { return false }; return true }
        ops.append(.crop(crop))
        photo.editOps = ops
        writeXMPSidecar()
        zoomLevel = 1.0
        withAnimation(.easeInOut(duration: 0.4)) {
            activeCrop = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
            isCropMode = false
        }
    }

    private func cancelCrop() {
        zoomLevel = 1.0
        let c = photo.compositeEdit
        if let existing = c.crop {
            withAnimation(.easeInOut(duration: 0.4)) {
                activeCrop = CGRect(
                    x: existing.x, y: existing.y,
                    width: existing.width, height: existing.height
                )
                isCropMode = false
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                isCropMode = false
            }
        }
    }

    private func restoreEdits() {
        photo.editOps = []
        writeXMPSidecar()
        activeRotation = 0
        activeFlipH = false
        activeCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        withAnimation(.easeInOut(duration: 0.25)) {
            isCropMode = false
        }
    }

    // MARK: - XMP Sidecar

    private func writeXMPSidecar() {
        guard let data = bookmarkData else { return }
        let edit = photo.compositeEdit
        let ori = photo.orientation ?? 1
        let gyro = gyroConfigJson
        let filePath = photo.filePath
        Task.detached {
            guard let folderURL = try? BookmarkService.resolveBookmark(data) else { return }
            BookmarkService.withSecurityScope(folderURL) {
                let imageURL = URL(fileURLWithPath: filePath)
                let hasEdits = edit.rotation != 0 || edit.flipH || edit.crop != nil
                if !hasEdits && gyro == nil {
                    XMPSidecarService.deleteSidecar(for: imageURL)
                } else {
                    try? XMPSidecarService.write(edit: edit, originalOrientation: ori,
                                                  gyroConfig: gyro, for: imageURL)
                }
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

                Text("AVPlayer · CALayer:\(showHDR && videoHDRType != nil ? "HDR" : "sRGB")")

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

            if mpvController.backendName == "MDK" {
                Text("MDK:\(mpvController.mdkColorspaceInfo) · CALayer:\(mpvController.layerColorspaceInfo)")
            } else {
                Text("mpv · \(mpvController.hwdecInfo) · CALayer:\(mpvController.layerColorspaceInfo)")
            }

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

            if mpvController.backendName != "MDK" {
                Text("↓ vo:\(mpvController.droppedFrames) dec:\(mpvController.decoderDroppedFrames)")
                    .foregroundStyle(
                        mpvController.droppedFrames > 0 || mpvController.decoderDroppedFrames > 0
                        ? .orange : .secondary
                    )
            }

            if mpvController.gyroStabEnabled {
                Text("gyro \(String(format: "%.2f", mpvController.gyroComputeMs))ms")
                    .foregroundStyle(.secondary)
                if !mpvController.gyroLensInfo.isEmpty {
                    Text(mpvController.gyroLensInfo)
                        .foregroundStyle(.secondary)
                }
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
        if let json = gyroConfigJson,
           let data = json.data(using: .utf8),
           let config = try? JSONDecoder().decode(GyroConfig.self, from: data) {
            return config
        }
        // Fallback to global settings
        return GyroConfig(
            smooth:               gyroSmooth,
            gyroOffsetMs:         gyroOffsetMs,
            integrationMethod:    gyroIntegrationMethod == -1 ? nil : gyroIntegrationMethod,
            imuOrientation:       gyroImuOrientation.isEmpty ? nil : gyroImuOrientation,
            fov:                  gyroFov,
            lensCorrectionAmount: gyroLensCorrectionAmount,
            zoomingMethod:        gyroZoomingMethod,
            zoomingAlgorithm:     gyroZoomingAlgorithm,
            adaptiveZoom:         gyroAdaptiveZoom,
            maxZoom:              gyroMaxZoom,
            maxZoomIterations:    gyroMaxZoomIterations,
            useGravityVectors:    gyroUseGravityVectors,
            videoSpeed:           gyroVideoSpeed,
            horizonLockEnabled:   gyroHorizonLockEnabled,
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
        showCursor()
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
        selectedBackend = .mpv
        videoStarted = false
        posterFrame = nil
        mpvPlaybackStarted = false
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

        // Read gyro config from XMP sidecar
        gyroConfigJson = readGyroConfigFromXMP()

        // Start playback immediately (no thumbnail preview phase)
        startPlayback()
    }

    /// Read gyroConfig JSON from XMP sidecar (security-scoped).
    private func readGyroConfigFromXMP() -> String? {
        guard let data = bookmarkData,
              let folderURL = try? BookmarkService.resolveBookmark(data) else { return nil }
        return BookmarkService.withSecurityScope(folderURL) {
            let imageURL = URL(fileURLWithPath: photo.filePath)
            let xmp = XMPSidecarService.read(for: imageURL, originalOrientation: photo.orientation ?? 1)
            return xmp?.gyroConfig
        }
    }

    /// Resolve per-type player preference: returns `"libmpv"`, `"mdk"`, or `"avplayer"`.
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
            let preferMDK = resolved == "mdk" && LibMDK.shared.ok

            if preferMPV || preferMDK {
                // Generate poster frame (first video frame) for static display
                if let data = bookmark,
                   let folderURL = try? BookmarkService.resolveBookmark(data) {
                    let gotAccess = folderURL.startAccessingSecurityScopedResource()
                    defer { if gotAccess { folderURL.stopAccessingSecurityScopedResource() } }
                    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    gen.requestedTimeToleranceBefore = .zero
                    gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
                    if let (cgImage, _) = try? await gen.image(at: .zero) {
                        posterFrame = cgImage
                    }
                }

                selectedBackend = preferMDK ? .mdk : .mpv
                mpvController.diagnosticsEnabled = showMPVDiagBadge
                useMPV = true   // shared MPVPlayerView (supports both backends)
                // Start gyro loading immediately (in parallel). By the time the
                // user presses Space, gyro will already be ready.
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

    /// Install key monitor for image viewing (f = fullscreen).
    private func installImageKeyMonitor() {
        removeSpaceMonitor()
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard bare else { return event }
            switch event.charactersIgnoringModifiers {
            case "f":
                NSApp.keyWindow?.toggleFullScreen(nil)
                return nil
            default:
                return event
            }
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

    private func showCursor() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    private var isFullScreen: Bool {
        NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
    }

    private func hideCursor() {
        guard isFullScreen else { return }
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
    }

    private func resetAVControlsTimer() {
        avHideTask?.cancel()
        showCursor()
        if !avControlsVisible {
            withAnimation(.easeIn(duration: 0.15)) { avControlsVisible = true }
        }
        avHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { avControlsVisible = false }
            hideCursor()
        }
    }

    private func resetMPVControlsTimer() {
        mpvHideTask?.cancel()
        showCursor()
        if !mpvControlsVisible {
            withAnimation(.easeIn(duration: 0.15)) { mpvControlsVisible = true }
        }
        mpvHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { mpvControlsVisible = false }
            hideCursor()
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

        let c = photo.compositeEdit
        activeRotation = c.rotation
        activeFlipH = c.flipH
        if let crop = c.crop {
            activeCrop = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
        } else {
            activeCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        }

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
