import SwiftUI
import SwiftData
import AVKit

// MARK: - HDR NSImageView wrapper

private class FlexibleImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
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

struct HDRVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
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
    @State private var videoSDRComposition: AVVideoComposition?
    @State private var activeSpec: (any HDRRenderSpec)?
    @State private var hdrImage: NSImage?
    @State private var sdrImage: NSImage?
    @State private var screenHeadroom: Float = 1.0

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

                    if isHDR {
                        Button {
                            showHDR.toggle()
                            if activeSpec?.needsPrerenderedSDR == true, sdrImage != nil {
                                self.image = showHDR ? hdrImage : sdrImage
                            }
                        } label: {
                            hdrBadge
                        }
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

    private var imageDynamicRange: NSImage.DynamicRange {
        activeSpec?.dynamicRange(showHDR: showHDR && isHDR) ?? .standard
    }

    private var hdrBadge: some View {
        HStack(spacing: 6) {
            Text(activeSpec?.badgeLabel ?? "HDR")
                .font(.caption.bold())
                .foregroundStyle(showHDR ? .orange : .secondary)
            if activeSpec is HLGHDRSpec {
                Text("EDR \(String(format: "%.1f", screenHeadroom))x")
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
        player = nil
        isHDR = false
        showHDR = true
        activeSpec = nil
        videoSDRComposition = nil

        let path = photo.filePath

        // Check preload cache first
        if let cached = preloadCache?.getVideo(path) {
            player = cached.player
            isHDR = cached.isHDR
            videoSDRComposition = cached.sdrComposition
            preloadAdjacent()
            return
        }

        // Cache miss — load normally
        let bookmark = bookmarkData
        if let entry = await ImagePreloadCache.loadVideoEntry(path: path, bookmarkData: bookmark) {
            player = entry.player
            isHDR = entry.isHDR
            videoSDRComposition = entry.sdrComposition
            preloadCache?.setVideo(path, entry: entry)
        }

        preloadAdjacent()
    }

    private func applyVideoDynamicRange() {
        guard let playerItem = player?.currentItem else { return }

        if showHDR {
            playerItem.videoComposition = nil
        } else {
            playerItem.videoComposition = videoSDRComposition
        }
    }

    private func loadFullImage() async {
        zoomLevel = 1.0
        showHDR = true
        let path = photo.filePath
        let headroom = Float(NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 2.0)
        screenHeadroom = headroom

        // Check preload cache first
        if let cached = preloadCache?.get(path) {
            image = cached.image
            activeSpec = cached.spec
            isHDR = cached.spec != nil
            hdrImage = cached.hdrImage
            sdrImage = cached.sdrImage
            preloadAdjacent()
            return
        }

        // Cache miss — load normally
        image = nil
        isHDR = false
        activeSpec = nil
        hdrImage = nil
        sdrImage = nil

        let bookmark = bookmarkData
        let entry = await ImagePreloadCache.loadImageEntry(
            path: path, bookmarkData: bookmark, screenHeadroom: headroom
        )

        image = entry.image
        activeSpec = entry.spec
        isHDR = entry.spec != nil
        hdrImage = entry.hdrImage
        sdrImage = entry.sdrImage

        // Store in cache
        preloadCache?.set(path, entry: entry)

        // Preload adjacent photos
        preloadAdjacent()
    }

    private func preloadAdjacent() {
        guard let viewModel, let preloadCache else { return }

        let prev = viewModel.navigatePhoto(from: photo, direction: -1)
        let next = viewModel.navigatePhoto(from: photo, direction: 1)

        // Evict entries that are no longer adjacent
        var keep: Set<String> = [photo.filePath]
        if let p = prev { keep.insert(p.filePath) }
        if let n = next { keep.insert(n.filePath) }
        preloadCache.evict(keeping: keep)

        let headroom = screenHeadroom

        for adjacent in [prev, next].compactMap({ $0 }) {
            let adjPath = adjacent.filePath
            guard adjPath != photo.filePath else { continue }
            guard !preloadCache.isLoading(adjPath) else { continue }

            let bookmark = bookmarkFor(adjacent)

            if adjacent.isVideo {
                guard preloadCache.getVideo(adjPath) == nil else { continue }
                preloadCache.markLoading(adjPath)
                Task {
                    if let entry = await ImagePreloadCache.loadVideoEntry(
                        path: adjPath, bookmarkData: bookmark
                    ) {
                        preloadCache.setVideo(adjPath, entry: entry)
                    }
                }
            } else {
                guard preloadCache.get(adjPath) == nil else { continue }
                preloadCache.markLoading(adjPath)
                Task {
                    let entry = await ImagePreloadCache.loadImageEntry(
                        path: adjPath, bookmarkData: bookmark, screenHeadroom: headroom
                    )
                    preloadCache.set(adjPath, entry: entry)
                }
            }
        }
    }

    private func bookmarkFor(_ p: Photo) -> Data? {
        p.resolveBookmarkData(from: folders)
    }
}
