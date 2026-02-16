import AppKit
import AVFoundation

struct CachedImageEntry {
    let image: NSImage?
    let spec: (any HDRRenderSpec)?
    let hdrImage: NSImage?
    let sdrImage: NSImage?
}

struct CachedVideoEntry {
    let player: AVPlayer
    let isHDR: Bool
    let sdrComposition: AVVideoComposition?
}

@Observable
@MainActor
final class ImagePreloadCache {
    private var imageCache: [String: CachedImageEntry] = [:]
    private var videoCache: [String: CachedVideoEntry] = [:]
    private var loading: Set<String> = []

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

    /// Keep only the specified paths, evict everything else
    func evict(keeping paths: Set<String>) {
        for (key, entry) in videoCache where !paths.contains(key) {
            entry.player.pause()
        }
        imageCache = imageCache.filter { paths.contains($0.key) }
        videoCache = videoCache.filter { paths.contains($0.key) }
        loading = loading.filter { paths.contains($0) }
    }

    // MARK: - Standalone video loading (no UI state)

    nonisolated static func loadVideoEntry(
        path: String,
        bookmarkData: Data?
    ) async -> CachedVideoEntry? {
        let url = URL(fileURLWithPath: path)

        if let bookmarkData,
           let folderURL = try? BookmarkService.resolveBookmark(bookmarkData) {
            _ = folderURL.startAccessingSecurityScopedResource()
        }

        let asset = AVURLAsset(url: url)
        var isHDR = false
        var sdrComposition: AVVideoComposition?

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

                sdrComposition = composition
            }
        }

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        return CachedVideoEntry(player: player, isHDR: isHDR, sdrComposition: sdrComposition)
    }

    // MARK: - Standalone image loading (no UI state)

    nonisolated static func loadImageEntry(
        path: String,
        bookmarkData: Data?,
        screenHeadroom: Float
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
                        let rendered = spec.render(url: url, filePath: path, screenHeadroom: screenHeadroom)
                        img = rendered.hdr
                        sdr = rendered.sdr
                        return
                    }
                }

                img = NSImage(contentsOfFile: path)
            }

            if let bookmarkData,
               let folderURL = try? BookmarkService.resolveBookmark(bookmarkData) {
                BookmarkService.withSecurityScope(folderURL, body: load)
            } else {
                load()
            }

            return CachedImageEntry(image: img, spec: matchedSpec, hdrImage: img, sdrImage: sdr)
        }.value
    }
}
