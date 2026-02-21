import AppKit
import AVFoundation
import CoreMedia
import ImageIO

// MARK: - HDR Format

enum HDRFormat {
    case gainMap
    case hlg
    var badgeLabel: String {
        switch self { case .gainMap: return "HDR"; case .hlg: return "HLG" }
    }
}

// MARK: - Cache entry types

enum VideoHDRType: String {
    case dolbyVision = "Dolby Vision"
    case hlg = "HLG"
    case hdr10 = "HDR10"
}

struct CachedImageEntry: @unchecked Sendable {
    let image: NSImage?
    let hlgCGImage: CGImage?    // non-nil for HLG: raw CGImage for CALayer direct rendering
    let hdrFormat: HDRFormat?   // nil = SDR
}

struct CachedVideoEntry {
    let player: AVPlayer
    let hdrType: VideoHDRType?
    let hdrComposition: AVVideoComposition?
    let sdrComposition: AVVideoComposition?
}

enum ImagePreloadCache {

    // MARK: - Video loading

    static func loadVideoEntry(
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
                    let codecType = CMFormatDescriptionGetMediaSubType(desc)
                    if codecType == kCMVideoCodecType_DolbyVisionHEVC {
                        hdrType = .dolbyVision
                        break
                    }

                    guard let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] else { continue }

                    if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
                       atoms["dvcC"] != nil || atoms["dvvC"] != nil {
                        hdrType = .dolbyVision
                        break
                    }

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

    // MARK: - Image loading

    static func loadImageEntry(
        path: String,
        bookmarkData: Data?
    ) async -> CachedImageEntry {
        await Task.detached {
            let url = URL(fileURLWithPath: path)

            var scopeURL: URL?
            var didStart = false
            if let bookmarkData,
               let folderURL = try? BookmarkService.resolveBookmark(bookmarkData) {
                scopeURL = folderURL
                didStart = folderURL.startAccessingSecurityScopedResource()
            }
            defer { if didStart, let scopeURL { scopeURL.stopAccessingSecurityScopedResource() } }

            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                let img = NSImage(contentsOfFile: path)
                return CachedImageEntry(image: img, hlgCGImage: nil, hdrFormat: nil)
            }

            let hdrFormat = detectHDR(source: source)

            let img: NSImage?
            var hlgCGImage: CGImage?
            if url.isCameraRawFile {
                img = loadCameraRaw(source: source, path: path)
            } else if hdrFormat == .hlg {
                // Load raw CGImage for direct CALayer rendering (mpv-style explicit colorspace)
                let cgImg = CGImageSourceCreateImageAtIndex(source, 0, nil)
                hlgCGImage = cgImg
                img = cgImg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            } else {
                img = NSImage(contentsOf: url)
            }

            return CachedImageEntry(image: img, hlgCGImage: hlgCGImage, hdrFormat: hdrFormat)
        }.value
    }

    // MARK: - Private helpers

    private static func detectHDR(source: CGImageSource) -> HDRFormat? {
        // 1. Gain Map auxiliary data
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return .gainMap
        }
        // 2. Gain Map via EXIF CustomRendered = 3 (older iPhone)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif[kCGImagePropertyExifCustomRendered] as? Int == 3 {
            return .gainMap
        }
        // 3. HLG: color space uses ITU-R 2100 transfer function
        if let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let cs = cg.colorSpace,
           CGColorSpaceUsesITUR_2100TF(cs) {
            return .hlg
        }
        return nil
    }

    private static func loadCameraRaw(source: CGImageSource, path: String) -> NSImage? {
        let subCount = CGImageSourceGetCount(source)
        if subCount > 1 {
            for i in 1..<subCount {
                if let cgImg = CGImageSourceCreateImageAtIndex(source, i, nil),
                   cgImg.width > 1000 {
                    return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                }
            }
        }

        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        }
        return nil
    }
}
