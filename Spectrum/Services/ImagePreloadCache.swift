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
    /// Loads in progress, keyed by path — concurrent callers await the same task
    /// instead of decoding the same image twice.
    @MainActor private static var inFlight: [String: Task<CachedImageEntry, Never>] = [:]
    static let maxCacheSize = 13

    /// Entries hold full-resolution decoded images (up to ~240MB each for 61MP files),
    /// so the cache must release everything under system memory pressure.
    /// Lazy static — first touched from storeInCache().
    private static let memoryPressureSource: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        source.setEventHandler {
            Log.video.info("[preload] memory pressure — clearing preload cache")
            Task { @MainActor in clearCache() }
        }
        source.resume()
        return source
    }()

    @MainActor static func cachedEntry(for path: String) -> CachedImageEntry? {
        cache[path]
    }

    /// 影片播放期間暫停 prefetch：全解析度影像的預載會佔用 NAS 頻寬，
    /// 與高碼率影片的串流讀取競爭造成播放卡頓。
    @MainActor private static var prefetchSuspended = false
    /// 由 prefetch 發起的 in-flight 載入（inFlight 的子集），暫停時取消
    @MainActor private static var prefetchTasks: [String: Task<CachedImageEntry, Never>] = [:]

    @MainActor static func setPrefetchSuspended(_ suspended: Bool) {
        guard prefetchSuspended != suspended else { return }
        prefetchSuspended = suspended
        guard suspended else { return }
        if !prefetchTasks.isEmpty {
            Log.video.info("[preload] suspending prefetch — cancelling \(prefetchTasks.count) in-flight loads")
        }
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
    }

    @MainActor static func prefetch(path: String, bookmarkData: Data?) {
        guard !prefetchSuspended else { return }
        guard cache[path] == nil, inFlight[path] == nil else { return }
        Task { _ = await loadImageEntry(path: path, bookmarkData: bookmarkData, isPrefetch: true) }
    }

    @MainActor static func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    @MainActor private static func storeInCache(path: String, entry: CachedImageEntry) {
        _ = memoryPressureSource
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
        bookmarkData: Data?,
        isPrefetch: Bool = false
    ) async -> CachedImageEntry {
        if let cached = cache[path] {
            // Move to end of LRU order
            if let idx = cacheOrder.firstIndex(of: path) {
                cacheOrder.remove(at: idx)
                cacheOrder.append(path)
            }
            return cached
        }
        // Join an in-progress load instead of decoding the same image again
        // （已取消的 prefetch task 不加入 — 直接載入的呼叫者需要完整結果）
        if let pending = inFlight[path], !pending.isCancelled {
            return await pending.value
        }
        let task = Task.detached { () -> CachedImageEntry in
            // 取消（prefetch 暫停）時盡早退出，不再讀檔
            guard !Task.isCancelled else {
                return CachedImageEntry(image: nil, hlgCGImage: nil, hdrFormat: nil)
            }
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

            guard !Task.isCancelled else {
                return CachedImageEntry(image: nil, hlgCGImage: nil, hdrFormat: nil)
            }
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
                // HLG images: keep the raw CGImage as-is (preserve bpc=10 + HLG color space).
                // Orientation is handled at the CALayer level in HLGNSView to avoid
                // pixel-level rotation which drops bit depth via CIContext/CGContext.
                hlgCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                // Use oriented pixel dimensions for the NSImage size so the SwiftUI
                // frame calculation gets the correct aspect ratio. Orientation 6/8
                // swaps width↔height; others keep raw dimensions.
                let rawW = hlgCGImage.map { CGFloat($0.width) } ?? 0
                let rawH = hlgCGImage.map { CGFloat($0.height) } ?? 0
                let orientedW: CGFloat
                let orientedH: CGFloat
                if let oriInt = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int,
                   oriInt == 6 || oriInt == 8 {
                    orientedW = rawH; orientedH = rawW
                } else {
                    orientedW = rawW; orientedH = rawH
                }
                img = hlgCGImage.map { NSImage(cgImage: $0, size: NSSize(width: orientedW, height: orientedH)) }
            } else {
                img = NSImage(contentsOf: url)
            }

            return CachedImageEntry(image: img, hlgCGImage: hlgCGImage, hdrFormat: hdrFormat)
        }
        inFlight[path] = task
        if isPrefetch { prefetchTasks[path] = task }
        let entry = await task.value
        // 只清掉仍指向本 task 的登錄——它可能已被後續的載入取代
        if prefetchTasks[path] == task { prefetchTasks[path] = nil }
        if inFlight[path] == task { inFlight[path] = nil }
        if task.isCancelled {
            // 取消的載入結果不完整，不能存 cache
            return entry
        }
        storeInCache(path: path, entry: entry)
        return entry
    }

    // MARK: - Private helpers

    static func detectHDR(source: CGImageSource) -> HDRFormat? {
        // 1. Gain Map auxiliary data
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return .gainMap
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        // 2. Gain Map via EXIF CustomRendered = 3 (older iPhone)
        if let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif[kCGImagePropertyExifCustomRendered] as? Int == 3 {
            return .gainMap
        }
        // 3. HLG/PQ: ICC profile 名稱含 BT.2100（如「Rec. ITU-R BT.2100 HLG」）。
        // 只讀 header，免解碼像素；之前用 8×8 縮圖 + FromImageAlways 判斷會
        // 強制解碼整張主圖（JPEG/HEIC/RAW 每張 ~120ms），grid 大量縮圖時
        // 是最大的 CPU 熱點（Time Profiler 實測佔 25%）
        if let profile = props?[kCGImagePropertyProfileName] as? String {
            return (profile.contains("2100") || profile.contains("HLG")) ? .hlg : nil
        }
        // 4. 沒有 profile 名稱才退回縮圖解碼，從 colorspace 判斷
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
