import Foundation
import AppKit
import ImageIO
import AVFoundation
import QuickLookThumbnailing
import os

// MARK: - ThumbnailSemaphore

/// 非同步信號量，用來限制同時執行的影片縮圖數量。
private actor ThumbnailSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { self.available = count }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

// MARK: - ThumbnailService

/// 純記憶體縮圖 cache。不寫入磁碟；進入 grid view 時按需生成，
/// 在記憶體受壓時自動清除。Cache 上限可在 Settings 調整（單位：GB）。
actor ThumbnailService {
    static let shared = ThumbnailService()
    nonisolated(unsafe) private static var _pressureSource: DispatchSourceMemoryPressure?

    private nonisolated(unsafe) let memoryCache = NSCache<NSString, NSImage>()
    nonisolated let thumbnailSize: Int = 400

    // 影片縮圖：AVURLAsset + CoreMedia，限制 2 個並行
    private let videoSemaphore = ThumbnailSemaphore(count: 2)

    init() {
        let gb = UserDefaults.standard.object(forKey: "thumbnailCacheSizeGB") as? Double ?? 1.0
        memoryCache.totalCostLimit = Int(gb * 1_073_741_824)  // 1 GB = 1024^3 bytes

        // 只在 critical 才清：warning 級別由 ImagePreloadCache 釋放大宗
        // （全解析度影像，單張可達數百 MB）；縮圖總量受 totalCostLimit 管制，
        // 但重生成成本高（回到 grid 會整頁空白重載）
        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.critical], queue: .global()
        )
        pressureSource.setEventHandler { [weak memoryCache] in
            Log.thumbnail.info("[thumb] critical memory pressure — clearing memory cache")
            memoryCache?.removeAllObjects()
        }
        pressureSource.resume()
        ThumbnailService._pressureSource = pressureSource
    }

    // MARK: - Cache access

    nonisolated func cachedThumbnail(for filePath: String) -> NSImage? {
        memoryCache.object(forKey: filePath as NSString)
    }

    /// 取得或生成縮圖。先查 memory cache；未命中則即時生成並存入 cache。
    /// 回傳 nil 表示檔案不存在或生成失敗。
    func thumbnail(for filePath: String, bookmarkData: Data? = nil) async -> NSImage? {
        let key = filePath as NSString

        if let cached = memoryCache.object(forKey: key) {
            Log.debug(Log.thumbnail, "[thumb] hit: \(URL(fileURLWithPath: filePath).lastPathComponent)")
            return cached
        }

        var folderURL: URL?
        var didStart = false
        if let bookmarkData {
            do {
                let resolved = try BookmarkService.resolveBookmark(bookmarkData)
                folderURL = resolved
                didStart = resolved.startAccessingSecurityScopedResource()
            } catch {
                Log.bookmark.warning("[thumb] bookmark resolve failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        defer { if didStart, let folderURL { folderURL.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: filePath) else {
            Log.debug(Log.thumbnail, "[thumb] source missing: \(URL(fileURLWithPath: filePath).lastPathComponent)")
            return nil
        }

        Log.debug(Log.thumbnail, "[thumb] generating: \(URL(fileURLWithPath: filePath).lastPathComponent)")
        let image = await generateThumbnail(from: URL(fileURLWithPath: filePath))
        if let image {
            memoryCache.setObject(image, forKey: key, cost: imageCost(image))
        }
        return image
    }

    /// 清除所有記憶體縮圖（例如 folder 刪除或 Reset All Data）。
    func clearCache() {
        memoryCache.removeAllObjects()
    }

    /// 更新記憶體 cache 上限（Settings 變更時呼叫）。
    nonisolated func updateMemoryCacheLimit(gb: Double) {
        memoryCache.totalCostLimit = Int(gb * 1_073_741_824)
    }

    // MARK: - Generation

    private nonisolated func generateViaQL(from url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: thumbnailSize, height: thumbnailSize),
            scale: 1.0,
            representationTypes: .thumbnail
        )

        let t0 = ContinuousClock.now
        do {
            let cgImage: CGImage = try await withCheckedThrowingContinuation { cont in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumb, error in
                    if let thumb { cont.resume(returning: thumb.cgImage) }
                    else { cont.resume(throwing: error ?? CancellationError()) }
                }
            }
            let dt = ContinuousClock.now - t0
            Log.info(Log.thumbnail, "[thumb] \(url.pathExtension.uppercased()) ql=\(fmtDur(dt)) \(url.lastPathComponent)")
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            Log.debug(Log.thumbnail, "[thumb] QL failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func generateThumbnail(from url: URL) async -> NSImage? {
        if url.isVideoFile { return await generateVideoThumbnail(from: url) }
        if url.pathExtension.lowercased() == "svg" { return generateSVGThumbnail(from: url) }
        // HLG 照片不能走 QuickLook：它輸出 SDR 縮圖，HLG→SDR tone mapping 會壓暗。
        // 改用 ImageIO 產生保留 HLG colorspace 的縮圖，顯示端以 EDR 呈現。
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           ImagePreloadCache.detectHDR(source: source) == .hlg,
           let img = generateHLGThumbnail(source: source, url: url) {
            return img
        }
        return await generateViaQL(from: url)
    }

    private nonisolated func generateHLGThumbnail(source: CGImageSource, url: URL) -> NSImage? {
        let t0 = ContinuousClock.now
        // 先用內嵌縮圖：Sony HIF 的內嵌縮圖本身就是 HLG（實測 8bpc
        // itur_2100_HLG），成本遠低於解碼 4K 主圖
        let embeddedOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize
        ]
        var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOpts as CFDictionary)
        var how = "embedded"
        // 內嵌縮圖若是 SDR（其他相機可能如此），退回從主圖重新縮放
        if cg == nil || !(cg!.colorSpace.map(CGColorSpaceUsesITUR_2100TF) ?? false) {
            let fullOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSize
            ]
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, fullOpts as CFDictionary)
            how = "fullimage"
        }
        guard let cg else { return nil }
        Log.info(Log.thumbnail, "[thumb] HLG \(how)=\(fmtDur(ContinuousClock.now - t0)) \(url.lastPathComponent)")
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func generateSVGThumbnail(from url: URL) -> NSImage? {
        guard let svgImage = NSImage(contentsOf: url) else { return nil }
        let size = svgImage.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = CGFloat(thumbnailSize) / max(size.width, size.height)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        guard let outputSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: Int(newSize.width), height: Int(newSize.height),
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: outputSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return svgImage }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        svgImage.draw(in: NSRect(origin: .zero, size: newSize))
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImg = ctx.makeImage() else { return svgImage }
        return NSImage(cgImage: cgImg, size: newSize)
    }

    private func generateVideoThumbnail(from url: URL) async -> NSImage? {
        await videoSemaphore.wait()
        defer { Task { await self.videoSemaphore.signal() } }

        let t0 = ContinuousClock.now
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: thumbnailSize, height: thumbnailSize)
        generator.appliesPreferredTrackTransform = true
        // 預設 .forceSDR 會把 HLG 影格 tone map 壓暗；.matchSource 保留來源
        // colorspace，HDR 影格由顯示端（HDRThumbnailImageView）以 EDR 呈現
        if #available(macOS 15.0, *) {
            generator.dynamicRangePolicy = .matchSource
        }

        do {
            let result = try await generator.image(at: .zero)
            let cgImage = result.image
            Log.debug(Log.thumbnail, "[thumb] video \(url.lastPathComponent): \(fmtDur(ContinuousClock.now - t0))")
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            Log.thumbnail.warning("[thumb] video failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    private nonisolated func imageCost(_ image: NSImage) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return max(1, Int(image.size.width) * Int(image.size.height) * 4)
        }
        let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
        return max(1, cg.width * cg.height * bytesPerPixel)
    }
}

// MARK: - Timing helper (file-private)

private func fmtDur(_ d: Duration) -> String {
    let ms = Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1_000_000_000_000_000
    return ms < 1_000 ? String(format: "%.1fms", ms) : String(format: "%.2fs", ms / 1_000)
}
