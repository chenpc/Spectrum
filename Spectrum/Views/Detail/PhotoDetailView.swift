import SwiftUI
import SwiftData
import AVKit
import os

private let logger = Logger(subsystem: "com.spectrum.Spectrum", category: "Preload")

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

// MARK: - HDR AVPlayerView wrapper

/// AVPlayerView subclass that enables EDR on the entire layer chain,
/// ensuring HDR video plays at full brightness in SwiftUI embedding.
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
        // Walk UP to window level — parent layers must also support EDR
        var current = layer
        while let l = current {
            l.wantsExtendedDynamicRangeContent = true
            current = l.superlayer
        }
        // Walk DOWN through sublayers (including internal AVPlayerLayer)
        enableEDRDown(layer)
    }

    private func enableEDRDown(_ layer: CALayer?) {
        guard let layer else { return }
        layer.wantsExtendedDynamicRangeContent = true
        layer.sublayers?.forEach { enableEDRDown($0) }
    }
}

struct HDRVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = EDRPlayerView()
        view.controlsStyle = .floating
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
    var preloadCache: ImagePreloadCache?
    @Query private var folders: [ScannedFolder]
    @State private var image: NSImage?
    @State private var showHDR: Bool = true
    @State private var zoomLevel: CGFloat = 1.0
    @State private var containerSize: CGSize = .zero
    @State private var player: AVPlayer?
    @State private var videoHDRType: VideoHDRType?
    @State private var videoHDRComposition: AVVideoComposition?
    @State private var videoSDRComposition: AVVideoComposition?
    @State private var activeSpec: (any HDRRenderSpec)?
    @State private var hdrImage: NSImage?
    @State private var sdrImage: NSImage?
    @State private var screenHeadroom: Float = 1.0
    @State private var originalImage: NSImage?
    @State private var selectedColorSpace: ColorSpaceOption = .original
    @State private var hlgToneMapMode: HLGToneMapMode = .iccTRC
    @AppStorage("developerMode") private var developerMode: Bool = false
    @AppStorage("prefetchCount") private var prefetchCount: Int = 2
    @AppStorage("cacheHistoryCount") private var cacheHistoryCount: Int = 10
    @AppStorage("cacheHistoryMemoryMB") private var cacheHistoryMemoryMB: Int = 1000

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
        .onDisappear {
            player?.pause()
        }
        .task(id: photo.filePath) {
            if photo.isVideo {
                await loadVideo()
            } else {
                await loadFullImage()
            }
        }
        .onChange(of: selectedColorSpace) { _, _ in
            applyColorSpaceConversion()
        }
        .onChange(of: hlgToneMapMode) { _, _ in
            guard isHLGImage else { return }
            Task { await loadFullImage(skipCache: true) }
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

                    if developerMode {
                        Menu {
                            ForEach(ColorSpaceOption.allCases) { option in
                                Button {
                                    selectedColorSpace = option
                                } label: {
                                    if selectedColorSpace == option {
                                        Label(option.label, systemImage: "checkmark")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "paintpalette")
                        }
                        .help("Color Space")

                        if isHLGImage {
                            Menu {
                                ForEach(HLGToneMapMode.allCases) { mode in
                                    Button {
                                        hlgToneMapMode = mode
                                    } label: {
                                        if hlgToneMapMode == mode {
                                            Label(mode.rawValue, systemImage: "checkmark")
                                        } else {
                                            Text(mode.rawValue)
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "wand.and.rays")
                            }
                            .help("HLG Tone Map: \(hlgToneMapMode.rawValue)")
                        }
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
        ZStack(alignment: .topLeading) {
            if let player {
                HDRVideoPlayerView(player: player)
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isHDR {
                Button {
                    showHDR.toggle()
                    applyVideoDynamicRange()
                } label: {
                    hdrBadge
                }
                .buttonStyle(.plain)
                .help(showHDR ? "Switch to SDR" : "Switch to HDR")
                .padding(12)
                .allowsHitTesting(true)
            }
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
                        HDRImageView(
                            image: image,
                            dynamicRange: imageDynamicRange
                        )
                        .frame(width: displayWidth, height: displayHeight)
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height
                        )
                    }
                    .contextMenu {
                        if developerMode {
                            Menu("Color Space") {
                                ForEach(ColorSpaceOption.allCases) { option in
                                    Button {
                                        selectedColorSpace = option
                                    } label: {
                                        if selectedColorSpace == option {
                                            Label(option.label, systemImage: "checkmark")
                                        } else {
                                            Text(option.label)
                                        }
                                    }
                                }
                            }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: photo.filePath)])
                        }
                    }

                    if isHDR {
                        Button {
                            showHDR.toggle()
                            if activeSpec?.needsPrerenderedSDR == true, sdrImage != nil {
                                originalImage = showHDR ? hdrImage : sdrImage
                                applyColorSpaceConversion()
                            }
                        } label: {
                            hdrBadge
                        }
                        .buttonStyle(.plain)
                        .help(showHDR ? "Switch to SDR" : "Switch to HDR")
                        .padding(12)
                    }

                    if selectedColorSpace != .original {
                        colorSpaceBadge
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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

    /// Whether the current image is HLG-based (HLG Still, or Sony PP HLG1-3/HLG)
    private var isHLGImage: Bool {
        if activeSpec is HLGHDRSpec { return true }
        if let ppSpec = activeSpec as? SonyPPRenderSpec, [32, 33, 34, 35].contains(ppSpec.profileValue) { return true }
        return false
    }

    private var imageDynamicRange: NSImage.DynamicRange {
        activeSpec?.dynamicRange(showHDR: showHDR && isHDR) ?? .standard
    }

    private var hdrBadgeLabel: String {
        if let videoType = videoHDRType {
            return videoType.rawValue
        }
        return activeSpec?.badgeLabel ?? "HDR"
    }

    private var hdrBadge: some View {
        HStack(spacing: 6) {
            Text(hdrBadgeLabel)
                .font(.caption.bold())
                .foregroundStyle(showHDR ? .orange : .secondary)
            if isHLGImage {
                Text("EDR \(String(format: "%.1f", screenHeadroom))x")
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

    private var colorSpaceBadge: some View {
        Text(selectedColorSpace.label)
            .font(.caption.bold())
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    private func applyColorSpaceConversion() {
        guard let originalImage else { return }
        if selectedColorSpace == .original {
            image = originalImage
        } else if let colorSpace = selectedColorSpace.cgColorSpace {
            image = ColorSpaceConverter.convert(originalImage, to: colorSpace) ?? originalImage
        }
    }

    // MARK: - Loading

    private func loadVideo() async {
        player?.pause()
        player = nil
        isHDR = false
        showHDR = true
        originalImage = nil
        selectedColorSpace = .original
        activeSpec = nil
        videoHDRType = nil
        videoHDRComposition = nil
        videoSDRComposition = nil

        let path = photo.filePath
        preloadCache?.recordView(path)

        let fileName = URL(fileURLWithPath: path).lastPathComponent

        // Check preload cache first
        if let cached = preloadCache?.getVideo(path) {
            logger.info("CACHE HIT video: \(fileName)")
            player = cached.player
            videoHDRType = cached.hdrType
            isHDR = cached.hdrType != nil
            videoHDRComposition = cached.hdrComposition
            videoSDRComposition = cached.sdrComposition
            applyVideoDynamicRange()
            preloadAdjacent()
            return
        }

        // Cache miss — load normally
        logger.info("CACHE MISS video: \(fileName)")
        let loadStart = CFAbsoluteTimeGetCurrent()
        let bookmark = bookmarkData
        if let entry = await ImagePreloadCache.loadVideoEntry(path: path, bookmarkData: bookmark) {
            let ms = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            logger.info("Loaded video: \(fileName) (HDR: \(entry.hdrType?.rawValue ?? "none"), \(ms, format: .fixed(precision: 0))ms)")
            player = entry.player
            videoHDRType = entry.hdrType
            isHDR = entry.hdrType != nil
            videoHDRComposition = entry.hdrComposition
            videoSDRComposition = entry.sdrComposition
            applyVideoDynamicRange()
            preloadCache?.setVideo(path, entry: entry)
        }

        preloadAdjacent()
    }

    private func applyVideoDynamicRange() {
        guard let playerItem = player?.currentItem else { return }

        if showHDR {
            // HLG: native playback (no composition) preserves full EDR
            // DV/HDR10: explicit composition triggers correct processing
            playerItem.videoComposition = (videoHDRType == .hlg) ? nil : videoHDRComposition
        } else {
            playerItem.videoComposition = videoSDRComposition
        }
    }

    private func loadFullImage(skipCache: Bool = false) async {
        zoomLevel = 1.0
        showHDR = true
        originalImage = nil
        selectedColorSpace = .original
        let path = photo.filePath
        let headroom = Float(NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 2.0)
        screenHeadroom = headroom
        preloadCache?.recordView(path)

        let fileName = URL(fileURLWithPath: path).lastPathComponent

        // Check preload cache first
        if !skipCache, let cached = preloadCache?.get(path) {
            logger.info("CACHE HIT image: \(fileName)")
            image = cached.image
            originalImage = cached.image
            activeSpec = cached.spec
            isHDR = cached.spec != nil
            hdrImage = cached.hdrImage
            sdrImage = cached.sdrImage
            preloadAdjacent()
            return
        }

        // Cache miss — load normally
        logger.info("CACHE MISS image: \(fileName)")
        image = nil
        isHDR = false
        activeSpec = nil
        hdrImage = nil
        sdrImage = nil

        let loadStart = CFAbsoluteTimeGetCurrent()
        let bookmark = bookmarkData
        let maxPx = renderMaxPixelSize
        let toneMode = hlgToneMapMode
        let entry = await ImagePreloadCache.loadImageEntry(
            path: path, bookmarkData: bookmark, screenHeadroom: headroom,
            maxPixelSize: maxPx, hlgToneMapMode: toneMode
        )
        let ms = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
        logger.info("Loaded image: \(fileName) (HDR: \(entry.spec != nil), \(ms, format: .fixed(precision: 0))ms, maxPx: \(maxPx))")

        image = entry.image
        originalImage = entry.image
        activeSpec = entry.spec
        isHDR = entry.spec != nil
        hdrImage = entry.hdrImage
        sdrImage = entry.sdrImage

        // Store in cache
        preloadCache?.set(path, entry: entry)

        // Preload adjacent photos
        preloadAdjacent()
    }

    /// Max pixel size for rendering — limits longest side to screen resolution × 2 (retina).
    private var renderMaxPixelSize: Int {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 2560, height: 1600)
        return Int(max(screen.width, screen.height)) * 2
    }

    private func preloadAdjacent() {
        guard let viewModel, let preloadCache else {
            logger.warning("preloadAdjacent skipped: viewModel=\(viewModel != nil), cache=\(preloadCache != nil)")
            return
        }

        let count = prefetchCount
        guard count > 0 else { return }

        // Collect prev N and next N
        var adjacents: [Photo] = []
        var keep: Set<String> = [photo.filePath]
        var cursor: Photo? = photo
        for _ in 0..<count {
            cursor = viewModel.navigatePhoto(from: cursor, direction: -1)
            if let p = cursor, p.filePath != photo.filePath {
                adjacents.append(p)
                keep.insert(p.filePath)
            }
        }
        cursor = photo
        for _ in 0..<count {
            cursor = viewModel.navigatePhoto(from: cursor, direction: 1)
            if let n = cursor, n.filePath != photo.filePath {
                adjacents.append(n)
                keep.insert(n.filePath)
            }
        }

        logger.info("Preloading \(adjacents.count) adjacent: \(adjacents.map { URL(fileURLWithPath: $0.filePath).lastPathComponent }.joined(separator: ", "))")
        preloadCache.evict(keeping: keep, historyCount: cacheHistoryCount, historyMemoryLimitMB: cacheHistoryMemoryMB)

        let headroom = screenHeadroom

        for adjacent in adjacents {
            let adjPath = adjacent.filePath
            guard !preloadCache.isLoading(adjPath) else { continue }

            let bookmark = bookmarkFor(adjacent)
            let adjName = URL(fileURLWithPath: adjPath).lastPathComponent

            if adjacent.isVideo {
                guard preloadCache.getVideo(adjPath) == nil else {
                    logger.debug("Already cached video: \(adjName)")
                    continue
                }
                preloadCache.markLoading(adjPath)
                logger.info("Prefetching video: \(adjName)")
                Task {
                    let start = CFAbsoluteTimeGetCurrent()
                    if let entry = await ImagePreloadCache.loadVideoEntry(
                        path: adjPath, bookmarkData: bookmark
                    ) {
                        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                        logger.info("Prefetched video: \(adjName) (\(ms, format: .fixed(precision: 0))ms)")
                        preloadCache.setVideo(adjPath, entry: entry)
                    }
                }
            } else {
                guard preloadCache.get(adjPath) == nil else {
                    logger.debug("Already cached image: \(adjName)")
                    continue
                }
                preloadCache.markLoading(adjPath)
                logger.info("Prefetching image: \(adjName)")
                Task {
                    let start = CFAbsoluteTimeGetCurrent()
                    let entry = await ImagePreloadCache.loadImageEntry(
                        path: adjPath, bookmarkData: bookmark, screenHeadroom: headroom,
                        maxPixelSize: self.renderMaxPixelSize
                    )
                    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    logger.info("Prefetched image: \(adjName) (HDR: \(entry.spec != nil), \(ms, format: .fixed(precision: 0))ms)")
                    preloadCache.set(adjPath, entry: entry)
                }
            }
        }
    }

    private func bookmarkFor(_ p: Photo) -> Data? {
        p.resolveBookmarkData(from: folders)
    }
}
