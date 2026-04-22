import SwiftUI
import SwiftData
import AVFoundation

// MARK: - PhotoDetailView

struct PhotoDetailView: View {
    @Binding var photo: PhotoItem
    @Binding var showInspector: Bool
    @Binding var isHDR: Bool
    var viewModel: LibraryViewModel?
    @Query private var folders: [ScannedFolder]
    @State private var image: NSImage?
    @State private var showEDR: Bool = true
    @State private var zoomLevel: CGFloat = 1.0
    @State private var containerSize: CGSize = .zero
    @State private var videoHDRType: VideoHDRType?
    @State private var hdrFormat: HDRFormat?
    @State private var hlgCGImage: CGImage?
    @State private var videoController = VideoController()
    @State private var isCropMode = false
    @State private var editingCropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    @State private var activeCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var activeRotation: Int = 0
    @State private var activeFlipH: Bool = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var barOffset: CGSize = .zero
    @State private var barDragStart: CGSize = .zero
    @State private var videoStarted = false
    @State private var previewThumbnail: NSImage?
    @State private var previewDuration: Double?
    @State private var playbackStarted = false
    @State private var livePhotoPlaying = false
    // Gyro config (stored in XMP sidecar, not DB)
    @State private var gyroConfigJson: String?
    // Shared
    @State private var spaceKeyMonitor: Any?
    @State private var cursorHidden = false
    @State private var statusBadgeVisible = false
    @State private var statusBadgeTask: Task<Void, Never>?
    @AppStorage("showDiagBadge") private var showDiagBadge: Bool = true
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
        photo.resolveBookmarkData(from: Array(folders))
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
        .focusedSceneValue(\.videoPlayPause, startPlayback)
        .focusedSceneValue(\.gyroConfigBinding, $gyroConfigJson)
        .focusedSceneValue(\.videoController, videoController)
        .onChange(of: showDiagBadge) { _, enabled in
            videoController.diagnosticsEnabled = enabled
        }
        .onChange(of: videoController.isPlaying) { _, playing in
            if playing && !playbackStarted {
                playbackStarted = true
            }
        }
        .onChange(of: videoController.gyroStabEnabled) { _, enabled in
            if enabled { flashStatusBadge() }
        }
        .onChange(of: gyroConfigJson) { _, _ in
            writeXMPSidecar()
            guard videoController.gyroStabEnabled else { return }
            videoController.stopGyroStab()
            let fps = videoController.videoFPS > 0 ? videoController.videoFPS : 30.0
            let lens: String? = gyroLensPath.isEmpty ? nil : gyroLensPath
            videoController.startGyroStab(videoPath: photo.filePath, fps: fps,
                                          config: buildGyroConfig(), lensPath: lens)
        }
        .onDisappear {
            removeSpaceMonitor()
            showCursor()
        }
        .onChange(of: photo.filePath) { _, _ in
            // Immediately clear stale gyro state to prevent badge flash
            videoController.reset()
        }
        .task(id: photo.filePath) {
            isCropMode = false
            livePhotoPlaying = false
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

    /// Active video player — created only after user presses play.
    @ViewBuilder
    private var activeVideoContent: some View {
        ZStack(alignment: .bottom) {
            if playbackStarted {
                VideoPlayerView(path: photo.filePath, bookmarkData: bookmarkData,
                              controller: videoController,
                              showEDR: showEDR)
            } else if let previewThumbnail {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: previewThumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let duration = previewDuration ?? photo.duration {
                        Text(formatDuration(duration))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .padding(12)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                statusBadge
                videoLoadingBadge
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if showDiagBadge {
                diagBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if controlsVisible {
                VideoControlBar(controller: videoController, onPlay: startPlayback)
                    .frame(maxWidth: 480)
                    .offset(barOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                barOffset = CGSize(
                                    width:  barDragStart.width  + v.translation.width,
                                    height: barDragStart.height + v.translation.height
                                )
                                resetControlsTimer()
                            }
                            .onEnded { v in
                                barOffset = CGSize(
                                    width:  barDragStart.width  + v.translation.width,
                                    height: barDragStart.height + v.translation.height
                                )
                                barDragStart = barOffset
                            }
                    )
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .onContinuousHover { phase in
            if case .active = phase { resetControlsTimer() }
        }
        .onAppear { resetControlsTimer() }
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
                            if let hlgCGImage, showEDR, hdrFormat == .hlg {
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
                    .overlay {
                        if livePhotoPlaying, let movPath = photo.livePhotoMovPath {
                            LivePhotoPlayerView(
                                url: URL(fileURLWithPath: movPath),
                                bookmarkData: bookmarkData,
                                isPlaying: livePhotoPlaying,
                                onEnded: { livePhotoPlaying = false }
                            )
                        }
                    }
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
                    VStack(alignment: .leading, spacing: 6) {
                        if isHDR && showDiagBadge && !isCropMode {
                            Button { showEDR.toggle() } label: { edrBadge }
                                .buttonStyle(.plain)
                                .help(showEDR ? "Switch to SDR" : "Switch to EDR")
                        }
                        if photo.livePhotoMovPath != nil && !isCropMode {
                            Button { livePhotoPlaying.toggle() } label: {
                                Image(systemName: livePhotoPlaying ? "livephoto.play" : "livephoto")
                                    .font(.title2)
                                    .foregroundStyle(livePhotoPlaying ? .yellow : .white)
                                    .shadow(radius: 3)
                            }
                            .buttonStyle(.plain)
                            .help("Play Live Photo (Space)")
                        }
                    }
                    .padding(12)
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
    private var diagBadge: some View {
        // Same thresholds as testmpv: green CV<0.05, yellow CV<0.15, red CV≥0.15
        let cv = videoController.renderCV
        let dotColor: Color = cv < 0.05 ? .green : cv < 0.15 ? .yellow : .red
        let videoFPS = videoController.videoFPS
        let renderFPS = videoController.renderFPS

        VStack(alignment: .trailing, spacing: 4) {
            // Toggle pills — separate row so they look clearly interactive
            HStack(spacing: 4) {
                if videoHDRType != nil && !videoController.isAVFLayerMode {
                    togglePill(label: showEDR ? "EDR" : "SDR",
                               active: showEDR, color: .orange) {
                        showEDR.toggle()
                    }
                }
                if videoController.gyroAvailable {
                    togglePill(label: videoController.gyroStabEnabled ? "GYRO" : "GYRO OFF",
                               active: videoController.gyroStabEnabled, color: .green) {
                        toggleGyroStab()
                    }
                }
            }

            if let codec = videoController.codecInfo {
                Text("Codec: \(codec)")
            }
            Text("Format: \(videoController.pixelFormatInfo)")
            Text("ColorSpace: \(videoController.colorSpaceInfo)")
            if videoController.isAVFLayerMode {
                Text("Render: AVPlayerLayer")
            } else {
                Text("Decode: \(videoController.decodeColorspaceInfo)")
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(renderFPS > 0 ? dotColor : .secondary)
                    .frame(width: 6, height: 6)
                if videoFPS > 0 {
                    Text(String(format: "FPS: %.1f/%.0f", renderFPS, videoFPS))
                } else {
                    Text(String(format: "FPS: %.1f", renderFPS))
                }
                Text(String(format: "CV: %.3f", videoController.renderCV))
                    .foregroundStyle(dotColor)
                if videoController.gyroStabEnabled && videoController.gyroSI > 0 {
                    Text(String(format: "SI: %.4f", videoController.gyroSI))
                        .foregroundStyle(.cyan)
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

    /// Persistent loading badge (top-left): shows active loading stages while player starts.
    @ViewBuilder
    private var videoLoadingBadge: some View {
        let analyzing = videoController.videoIsAnalyzing
        let buffering  = videoController.videoIsBuffering
        let gyroLoad   = videoController.gyroShowLoadingUI
        if playbackStarted && (analyzing || buffering || gyroLoad) {
            VStack(alignment: .leading, spacing: 5) {
                if analyzing {
                    loadingRow(label: "Decode")
                }
                if buffering {
                    loadingRow(label: "Buffer")
                }
                if gyroLoad {
                    let pct = videoController.gyroLoadProgress
                    let label = pct >= 0 ? "Loading Gyro \(Int(pct * 100))%" : "Loading Gyro"
                    loadingRow(label: label, prominent: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 8)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func loadingRow(label: String, prominent: Bool = false) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(prominent ? .small : .mini)
                .tint(prominent ? .yellow : .white)
            Text(label)
                .font(.system(size: prominent ? 12 : 11,
                              weight: prominent ? .semibold : .medium,
                              design: .monospaced))
                .foregroundStyle(prominent ? Color.yellow : .white.opacity(0.85))
        }
    }

    /// Transient status badge (top-left): shows HDR / GYRO state for 2 seconds.
    @ViewBuilder
    private var statusBadge: some View {
        let hasHDR = showEDR && videoHDRType != nil && !videoController.isAVFLayerMode
        let hasGyro = videoController.gyroStabEnabled
        if statusBadgeVisible && (hasHDR || hasGyro) {
            HStack(spacing: 4) {
                if hasHDR { Text("HDR") }
                if hasGyro { Text("GYRO") }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .padding(8)
            .transition(.opacity)
        }
    }

    private func flashStatusBadge() {
        statusBadgeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { statusBadgeVisible = true }
        statusBadgeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { statusBadgeVisible = false }
        }
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
           var config = try? JSONDecoder().decode(GyroConfig.self, from: data) {
            if config.lensDbDir == nil {
                config.lensDbDir = "/Applications/Gyroflow.app/Contents/Resources"
            }
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
            smoothnessRoll:       gyroSmoothnessRoll,
            lensDbDir:            "/Applications/Gyroflow.app/Contents/Resources"
        )
    }

    /// Toggle gyro stabilization on/off.
    private func toggleGyroStab() {
        if videoController.gyroStabEnabled {
            videoController.stopGyroStab()
        } else {
            let fps = videoController.videoFPS > 0 ? videoController.videoFPS : 30.0
            let lens = gyroLensPath.isEmpty ? nil : gyroLensPath
            videoController.startGyroStab(videoPath: photo.filePath, fps: fps,
                                          config: buildGyroConfig(), lensPath: lens)
        }
    }

    private var isHLGImage: Bool { hdrFormat == .hlg }

    private var imageDynamicRange: NSImage.DynamicRange {
        showEDR && isHDR ? .high : .standard
    }

    private var edrBadge: some View {
        HStack(spacing: 6) {
            Text(showEDR ? "EDR" : "SDR")
                .font(.caption.bold())
                .foregroundStyle(showEDR ? .orange : .secondary)
            let edr = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
            if showEDR && edr > 1.0 {
                Text("\(String(format: "%.1f", edr))x")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(showEDR ? .orange.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Loading

    /// Load video: reset state and show thumbnail preview. Heavy work deferred until play is pressed.
    private func loadVideo() async {
        // Reset all player state from previous video
        showCursor()
        isHDR = false
        showEDR = true
        hdrFormat = nil
        videoHDRType = nil
        videoStarted = false
        previewThumbnail = nil
        previewDuration = nil
        playbackStarted = false
        gyroConfigJson = nil
        videoController.reset()
        resetControlsTimer()
        barOffset = .zero
        barDragStart = .zero
        removeSpaceMonitor()

        // Show cached thumbnail as static preview (no AVFoundation, no gyro)
        let path = photo.filePath
        let bookmark = bookmarkData
        let filename = URL(fileURLWithPath: path).lastPathComponent
        previewDuration = photo.duration
        Log.debug(Log.video, "[duration] \(filename) — photo.duration=\(photo.duration.map { String(format: "%.1f", $0) } ?? "nil") bookmark=\(bookmark != nil ? "yes" : "nil")")
        if let cached = ThumbnailService.shared.cachedThumbnail(for: path) {
            previewThumbnail = cached
        } else {
            previewThumbnail = await ThumbnailService.shared.thumbnail(for: path, bookmarkData: bookmarkData)
        }

        // Fetch duration if not yet in DB — use security scope from folder bookmark
        if photo.isVideo && photo.duration == nil {
            Log.debug(Log.video, "[duration] \(filename) — fetching via AVAsset (bookmark=\(bookmark != nil ? "yes" : "nil"))")
            let fileURL = URL(fileURLWithPath: path)
            let seconds: Double?
            if let bm = bookmark, let folderURL = try? BookmarkService.resolveBookmark(bm) {
                let started = folderURL.startAccessingSecurityScopedResource()
                Log.debug(Log.video, "[duration] \(filename) — scope started=\(started) folderURL=\(folderURL.lastPathComponent)")
                let t = try? await AVURLAsset(url: fileURL).load(.duration)
                if started { folderURL.stopAccessingSecurityScopedResource() }
                seconds = (t?.seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                Log.debug(Log.video, "[duration] \(filename) — AVAsset result=\(seconds.map { String(format: "%.1f", $0) } ?? "nil") raw=\(t?.seconds ?? -1)")
            } else {
                Log.debug(Log.video, "[duration] \(filename) — no bookmark, trying without scope")
                let t = try? await AVURLAsset(url: fileURL).load(.duration)
                seconds = (t?.seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                Log.debug(Log.video, "[duration] \(filename) — no-scope result=\(seconds.map { String(format: "%.1f", $0) } ?? "nil")")
            }
            if let s = seconds {
                Log.debug(Log.video, "[duration] \(filename) — \(String(format: "%.1f", s))s")
                previewDuration = s
                photo.duration = s
            } else {
                Log.debug(Log.video, "[duration] \(filename) — fetch failed, duration remains nil")
            }
        }

        // Key monitor before play: Space starts playback; full monitor installed in startPlayback()
        installActiveKeyMonitor()
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

    /// Called when user first presses play. Subsequent calls toggle play/pause.
    private func startPlayback() {
        guard !videoStarted else { videoController.togglePlayPause(); return }
        videoStarted = true
        playbackStarted = true

        // Read gyro config from XMP sidecar (fast: small file, bookmark already resolved)
        gyroConfigJson = readGyroConfigFromXMP()

        // Start gyro loading (non-blocking background task)
        if gyroStabEnabled && GyroCore.dylibFound {
            let cfg = buildGyroConfig()
            let lens: String? = gyroLensPath.isEmpty ? nil : gyroLensPath
            videoController.startGyroStab(videoPath: photo.filePath, fps: 30,
                                          config: cfg, lensPath: lens)
        }

        videoController.diagnosticsEnabled = showDiagBadge

        // Signal play — gyro's waitingForGyro will defer actual frame output if still loading
        videoController.togglePlayPause()

        // Detect HDR in parallel with player creation (both are async)
        Task {
            let detectedType = await ImagePreloadCache.detectVideoHDRType(
                path: photo.filePath, bookmarkData: bookmarkData)
            videoHDRType = detectedType
            isHDR = detectedType != nil
            if detectedType != nil { flashStatusBadge() }
        }

        // Upgrade key monitor to full playback controls
        installActiveKeyMonitor()
    }

    /// Install key monitor for image viewing (f = fullscreen).
    private func installImageKeyMonitor() {
        removeSpaceMonitor()
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard bare else { return event }
            guard event.type == .keyDown, !event.isARepeat else { return event }
            if event.charactersIgnoringModifiers == " " && photo.livePhotoMovPath != nil {
                livePhotoPlaying.toggle()
                return nil
            }
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
        let mpv   = videoController
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
        let hdrToggle: () -> Void = { [self] in self.showEDR.toggle(); flashStatusBadge() }
        let gyroToggleWithBadge: () -> Void = { [self] in gyroToggle(); flashStatusBadge() }
        let inspectorToggle: () -> Void = { [self] in self.showInspector.toggle() }
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard bare else { return event }
            switch event.charactersIgnoringModifiers {
            case " ":
                startPlayback()  // handles first-play and subsequent toggle
                return nil
            case "f":
                NSApp.keyWindow?.toggleFullScreen(nil)
                return nil
            case "h":
                hdrToggle()
                return nil
            case "s", "g":
                gyroToggleWithBadge()
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

    private func resetControlsTimer() {
        hideTask?.cancel()
        showCursor()
        if !controlsVisible {
            withAnimation(.easeIn(duration: 0.15)) { controlsVisible = true }
        }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { controlsVisible = false }
            hideCursor()
        }
    }

    private func loadFullImage() async {
        zoomLevel = 1.0
        showEDR = true
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

        prefetchAdjacentImages()
    }

    private func prefetchAdjacentImages() {
        let flatPhotos = viewModel?.flatPhotos ?? []
        guard let idx = flatPhotos.firstIndex(where: { $0.filePath == photo.filePath }) else { return }
        for offset in [-1, 1] {
            let ni = idx + offset
            guard flatPhotos.indices.contains(ni) else { continue }
            let adj = flatPhotos[ni]
            guard !adj.isVideo else { continue }
            let bm = adj.resolveBookmarkData(from: Array(folders))
            ImagePreloadCache.prefetch(path: adj.filePath, bookmarkData: bm)
        }
    }
}
