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
        if let data = photo.folder?.bookmarkData {
            return data
        }
        return folders.first { photo.filePath.hasPrefix($0.path) }?.bookmarkData
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
        let bookmark = bookmarkData
        let url = URL(fileURLWithPath: path)

        if let bookmark,
           let folderURL = try? BookmarkService.resolveBookmark(bookmark) {
            _ = folderURL.startAccessingSecurityScopedResource()
        }

        let asset = AVURLAsset(url: url)

        if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
           let track = videoTracks.first {
            if let descriptions = try? await track.load(.formatDescriptions) {
                for desc in descriptions {
                    if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
                       let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
                        if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) ||
                           transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                            isHDR = true
                        }
                    }
                }
            }

            if isHDR {
                let size = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let fps = (try? await track.load(.nominalFrameRate)) ?? 30
                let duration = (try? await asset.load(.duration)) ?? .indefinite

                let transformedSize = size.applying(transform)
                let composition = AVMutableVideoComposition()
                composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
                composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
                composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
                composition.renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
                composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps : 30))

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layerInstruction.setTransform(transform, at: .zero)
                instruction.layerInstructions = [layerInstruction]
                composition.instructions = [instruction]

                videoSDRComposition = composition
            }
        }

        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
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
        image = nil
        isHDR = false
        showHDR = true
        activeSpec = nil
        hdrImage = nil
        sdrImage = nil
        let path = photo.filePath
        let bookmark = bookmarkData
        let headroom = Float(NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 2.0)
        screenHeadroom = headroom

        let result = await Task.detached { () -> (NSImage?, (any HDRRenderSpec)?, NSImage?) in
            let url = URL(fileURLWithPath: path)

            var img: NSImage?
            var matchedSpec: (any HDRRenderSpec)?
            var sdr: NSImage?

            let load = {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    img = NSImage(contentsOfFile: path)
                    return
                }

                for spec in hdrRenderSpecs {
                    if spec.detect(source: source, url: url) {
                        matchedSpec = spec
                        let rendered = spec.render(url: url, filePath: path, screenHeadroom: headroom)
                        img = rendered.hdr
                        sdr = rendered.sdr
                        return
                    }
                }

                img = NSImage(contentsOfFile: path)
            }

            if let bookmark,
               let folderURL = try? BookmarkService.resolveBookmark(bookmark) {
                BookmarkService.withSecurityScope(folderURL, body: load)
            } else {
                load()
            }

            return (img, matchedSpec, sdr)
        }.value

        image = result.0
        activeSpec = result.1
        isHDR = result.1 != nil
        hdrImage = result.0
        sdrImage = result.2
    }
}
