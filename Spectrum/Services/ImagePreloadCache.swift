import AppKit
import AVFoundation
import CoreMedia

enum VideoHDRType: String {
    case dolbyVision = "Dolby Vision"
    case hlg = "HLG"
    case hdr10 = "HDR10"
}

struct CachedImageEntry {
    let image: NSImage?
    let spec: (any HDRRenderSpec)?
    let hdrImage: NSImage?
    let sdrImage: NSImage?
}

struct CachedVideoEntry {
    let player: AVPlayer
    let hdrType: VideoHDRType?
    let hdrComposition: AVVideoComposition?
    let sdrComposition: AVVideoComposition?
}

@Observable
@MainActor
final class ImagePreloadCache {
    private var imageCache: [String: CachedImageEntry] = [:]
    private var videoCache: [String: CachedVideoEntry] = [:]
    private var loading: Set<String> = []

    /// Recently viewed paths (most recent last), for history retention.
    private var viewHistory: [String] = []

    func get(_ path: String) -> CachedImageEntry? {
        imageCache[path]
    }

    func set(_ path: String, entry: CachedImageEntry) {
        imageCache[path] = entry
        loading.remove(path)
    }

    func getVideo(_ path: String) -> CachedVideoEntry? {
        videoCache[path]
    }

    func setVideo(_ path: String, entry: CachedVideoEntry) {
        videoCache[path] = entry
        loading.remove(path)
    }

    func isLoading(_ path: String) -> Bool {
        loading.contains(path)
    }

    func markLoading(_ path: String) {
        loading.insert(path)
    }

    /// Record a photo as viewed (for history-based cache retention).
    func recordView(_ path: String) {
        viewHistory.removeAll { $0 == path }
        viewHistory.append(path)
    }

    /// Evict cache entries that are not in the keep set and exceed history limits.
    /// - `keeping`: paths that must stay (current + prefetch adjacent)
    /// - `historyCount`: max number of history entries to keep
    /// - `historyMemoryLimitMB`: max memory for history entries (0 = unlimited)
    func evict(keeping paths: Set<String>, historyCount: Int, historyMemoryLimitMB: Int) {
        // Determine which history entries to keep (most recent first, within limits)
        var historyKeep = Set<String>()
        var historyBytes: Int64 = 0
        let memoryLimit = Int64(historyMemoryLimitMB) * 1024 * 1024

        for path in viewHistory.reversed() {
            guard !paths.contains(path) else { continue } // already kept by adjacency
            guard historyKeep.count < historyCount else { break }

            let entryBytes = estimatedBytes(for: path)
            if memoryLimit > 0 && historyBytes + entryBytes > memoryLimit {
                break
            }

            historyKeep.insert(path)
            historyBytes += entryBytes
        }

        let allKeep = paths.union(historyKeep)

        for (key, entry) in videoCache where !allKeep.contains(key) {
            entry.player.pause()
        }
        imageCache = imageCache.filter { allKeep.contains($0.key) }
        videoCache = videoCache.filter { allKeep.contains($0.key) }
        loading = loading.filter { allKeep.contains($0) }

        // Trim history list to avoid unbounded growth
        if viewHistory.count > max(historyCount * 2, 50) {
            viewHistory = Array(viewHistory.suffix(max(historyCount, 20)))
        }
    }

    /// Estimate memory usage of a cached path (image + video).
    private func estimatedBytes(for path: String) -> Int64 {
        var bytes: Int64 = 0
        if let entry = imageCache[path] {
            bytes += Self.estimatedImageBytes(entry.hdrImage)
            bytes += Self.estimatedImageBytes(entry.sdrImage)
        }
        // Video entries are relatively small (AVPlayer buffers are managed by system)
        return bytes
    }

    /// Estimate memory footprint of an NSImage from its pixel dimensions.
    private static func estimatedImageBytes(_ image: NSImage?) -> Int64 {
        guard let image else { return 0 }
        let w = Int64(image.size.width)
        let h = Int64(image.size.height)
        return w * h * 8 // assume RGBAh (16-bit per channel)
    }

    // MARK: - Standalone video loading (no UI state)

    nonisolated static func loadVideoEntry(
        path: String,
        bookmarkData: Data?
    ) async -> CachedVideoEntry? {
        let url = URL(fileURLWithPath: path)

        var scopeURL: URL?
        var didStart = false
        if let bookmarkData,
           let folderURL = try? BookmarkService.resolveBookmark(bookmarkData) {
            scopeURL = folderURL
            didStart = folderURL.startAccessingSecurityScopedResource()
        }
        defer {
            if didStart, let scopeURL { scopeURL.stopAccessingSecurityScopedResource() }
        }

        let asset = AVURLAsset(url: url)
        var hdrType: VideoHDRType?
        var hdrComposition: AVVideoComposition?
        var sdrComposition: AVVideoComposition?
        let canPlayHDR = AVPlayer.eligibleForHDRPlayback

        if canPlayHDR,
           let videoTracks = try? await asset.loadTracks(withMediaType: .video),
           let track = videoTracks.first {
            if let descriptions = try? await track.load(.formatDescriptions) {
                for desc in descriptions {
                    // 1. Codec FourCC 'dvh1' → Dolby Vision (dedicated DV codec)
                    let codecType = CMFormatDescriptionGetMediaSubType(desc)
                    if codecType == kCMVideoCodecType_DolbyVisionHEVC {
                        hdrType = .dolbyVision
                        break
                    }

                    guard let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] else { continue }

                    // 2. DV Profile 8 (cross-compatible): standard HEVC with dvcC/dvvC config box
                    if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
                       atoms["dvcC"] != nil || atoms["dvvC"] != nil {
                        hdrType = .dolbyVision
                        break
                    }

                    // 3. Transfer function: HLG or PQ (HDR10)
                    if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
                        if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                            hdrType = .hlg
                        } else if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                            hdrType = .hdr10
                        }
                    }
                }
            }

            if hdrType != nil {
                let size = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let fps = (try? await track.load(.nominalFrameRate)) ?? 30
                let duration = (try? await asset.load(.duration)) ?? .indefinite

                let transformedSize = size.applying(transform)
                let renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps : 30))

                func makeInstruction() -> AVMutableVideoCompositionInstruction {
                    let inst = AVMutableVideoCompositionInstruction()
                    inst.timeRange = CMTimeRange(start: .zero, duration: duration)
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                    layer.setTransform(transform, at: .zero)
                    inst.layerInstructions = [layer]
                    return inst
                }

                // HDR composition: explicit BT.2020 + correct transfer function
                let hdrComp = AVMutableVideoComposition()
                hdrComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
                hdrComp.colorTransferFunction = (hdrType == .hlg || hdrType == .dolbyVision)
                    ? AVVideoTransferFunction_ITU_R_2100_HLG
                    : AVVideoTransferFunction_SMPTE_ST_2084_PQ
                hdrComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
                hdrComp.renderSize = renderSize
                hdrComp.frameDuration = frameDuration
                hdrComp.instructions = [makeInstruction()]
                hdrComposition = hdrComp

                // SDR composition: force BT.709
                let sdrComp = AVMutableVideoComposition()
                sdrComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
                sdrComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
                sdrComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
                sdrComp.renderSize = renderSize
                sdrComp.frameDuration = frameDuration
                sdrComp.instructions = [makeInstruction()]
                sdrComposition = sdrComp
            }
        }

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        return CachedVideoEntry(player: player, hdrType: hdrType, hdrComposition: hdrComposition, sdrComposition: sdrComposition)
    }

    // MARK: - Standalone image loading (no UI state)

    nonisolated static func loadImageEntry(
        path: String,
        bookmarkData: Data?,
        screenHeadroom: Float,
        maxPixelSize: Int? = nil,
        hlgToneMapMode: HLGToneMapMode = .iccTRC
    ) async -> CachedImageEntry {
        await Task.detached {
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
                        let rendered = spec.render(url: url, filePath: path, screenHeadroom: screenHeadroom, maxPixelSize: maxPixelSize, hlgToneMapMode: hlgToneMapMode)
                        img = rendered.hdr
                        sdr = rendered.sdr
                        return
                    }
                }

                // Sony PP files (HLG1-3, S-Log3, S-Log2) — container mislabeled as BT.709
                if let ppSpec = SonyPPDetector.detect(url: url) {
                    matchedSpec = ppSpec
                    let rendered = ppSpec.render(url: url, filePath: path, screenHeadroom: screenHeadroom, maxPixelSize: maxPixelSize, hlgToneMapMode: hlgToneMapMode)
                    img = rendered.hdr
                    sdr = rendered.sdr
                    return
                }

                img = NSImage(contentsOfFile: path)
            }

            if let bookmarkData,
               let folderURL = try? BookmarkService.resolveBookmark(bookmarkData) {
                BookmarkService.withSecurityScope(folderURL, body: load)
            } else {
                load()
            }

            return CachedImageEntry(
                image: Self.forceDecoded(img),
                spec: matchedSpec,
                hdrImage: Self.forceDecoded(img),
                sdrImage: Self.forceDecoded(sdr)
            )
        }.value
    }

    /// Force-decode an NSImage so JPEG/HEIC decode happens here (background thread),
    /// not lazily on the main thread when NSImageView displays it.
    private nonisolated static func forceDecoded(_ image: NSImage?) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return image }
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        return result
    }
}
