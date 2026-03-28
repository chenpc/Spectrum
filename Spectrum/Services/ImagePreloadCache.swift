import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import os

// MARK: - HDR Format

enum HDRFormat: Equatable {
    case gainMap
    case hlg
    var badgeLabel: String {
        switch self { case .gainMap: return "HDR"; case .hlg: return "HLG" }
    }
}

// MARK: - Cache entry types

enum VideoHDRType: String, CaseIterable {
    case dolbyVision = "Dolby Vision"
    case hlg = "HLG"
    case hdr10 = "HDR10"
    case slog2 = "S-Log2"
    case slog3 = "S-Log3"

}

struct CachedImageEntry: @unchecked Sendable {
    let image: NSImage?
    let hlgCGImage: CGImage?    // non-nil for HLG: raw CGImage for CALayer direct rendering
    let hdrFormat: HDRFormat?   // nil = SDR
}

enum ImagePreloadCache {

    // MARK: - LRU Cache

    @MainActor private static var cache: [String: CachedImageEntry] = [:]
    @MainActor private static var cacheOrder: [String] = []
    private static let maxCacheSize = 5

    @MainActor static func cachedEntry(for path: String) -> CachedImageEntry? {
        cache[path]
    }

    @MainActor static func prefetch(path: String, bookmarkData: Data?) {
        guard cache[path] == nil else { return }
        Task.detached {
            _ = await loadImageEntry(path: path, bookmarkData: bookmarkData)
        }
    }

    @MainActor private static func storeInCache(path: String, entry: CachedImageEntry) {
        if let idx = cacheOrder.firstIndex(of: path) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(path)
        cache[path] = entry
        while cacheOrder.count > maxCacheSize {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    // MARK: - Lightweight HDR type detection (no AVPlayer created)

    static func detectVideoHDRType(
        path: String,
        bookmarkData: Data?
    ) async -> VideoHDRType? {
        let url = URL(fileURLWithPath: path)

        var scopeURL: URL?
        var didStart = false
        if let bookmarkData {
            do {
                let folderURL = try BookmarkService.resolveBookmark(bookmarkData)
                scopeURL = folderURL
                didStart = folderURL.startAccessingSecurityScopedResource()
            } catch {
                Log.bookmark.warning("Failed to resolve bookmark for HDR detection \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        defer {
            if didStart, let scopeURL { scopeURL.stopAccessingSecurityScopedResource() }
        }

        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            Log.video.warning("Failed to load video tracks for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let track = videoTracks.first else { return nil }

        let descriptions: [CMFormatDescription]
        do {
            descriptions = try await track.load(.formatDescriptions)
        } catch {
            Log.video.warning("Failed to load format descriptions for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        for desc in descriptions {
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            if codecType == kCMVideoCodecType_DolbyVisionHEVC {
                return .dolbyVision
            }

            guard let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] else { continue }

            if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
               atoms["dvcC"] != nil || atoms["dvvC"] != nil {
                return .dolbyVision
            }

            if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
                if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                    return .hlg
                } else if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                    return .hdr10
                }
            }
        }
        return nil
    }

    // MARK: - Image loading

    @MainActor static func loadImageEntry(
        path: String,
        bookmarkData: Data?
    ) async -> CachedImageEntry {
        if let cached = cache[path] {
            // Move to end of LRU order
            if let idx = cacheOrder.firstIndex(of: path) {
                cacheOrder.remove(at: idx)
                cacheOrder.append(path)
            }
            return cached
        }
        let entry = await Task.detached {
            // Skip if the source file no longer exists — avoids IIOImageSource errors
            guard FileManager.default.fileExists(atPath: path) else {
                Log.debug(Log.video, "[preload] file missing: \(URL(fileURLWithPath: path).lastPathComponent)")
                return CachedImageEntry(image: nil, hlgCGImage: nil, hdrFormat: nil)
            }

            let url = URL(fileURLWithPath: path)

            var scopeURL: URL?
            var didStart = false
            if let bookmarkData {
                do {
                    let folderURL = try BookmarkService.resolveBookmark(bookmarkData)
                    scopeURL = folderURL
                    didStart = folderURL.startAccessingSecurityScopedResource()
                } catch {
                    Log.bookmark.warning("Failed to resolve bookmark for image \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            defer { if didStart, let scopeURL { scopeURL.stopAccessingSecurityScopedResource() } }

            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                let img = NSImage(contentsOfFile: path)
                return CachedImageEntry(image: img, hlgCGImage: nil, hdrFormat: nil)
            }

            let hdrFormat = detectHDR(source: source)
            Log.debug(Log.video, "[preload] \(url.lastPathComponent) hdr=\(hdrFormat.map(\.badgeLabel) ?? "none") raw=\(url.isCameraRawFile)")

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
        storeInCache(path: path, entry: entry)
        return entry
    }

    // MARK: - Private helpers

    static func detectHDR(source: CGImageSource) -> HDRFormat? {
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
        // 用 8×8 縮圖取代完整解析度圖像（colorspace 會被保留，記憶體從 ~200MB 降為幾百 bytes）
        let tinyOpts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 8,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, tinyOpts as CFDictionary),
           let cs = cg.colorSpace,
           CGColorSpaceUsesITUR_2100TF(cs) {
            return .hlg
        }
        return nil
    }

    private static func loadCameraRaw(source: CGImageSource, path: String) -> NSImage? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let subCount = CGImageSourceGetCount(source)
        if subCount > 1 {
            for i in 1..<subCount {
                if let cgImg = CGImageSourceCreateImageAtIndex(source, i, nil),
                   cgImg.width > 1000 {
                    Log.debug(Log.video, "[preload] RAW \(name): using sub-image[\(i)] \(cgImg.width)x\(cgImg.height)")
                    return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                }
            }
        }
        Log.debug(Log.video, "[preload] RAW \(name): no large sub-image found (subCount=\(subCount)) — falling back to thumbnail")

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
