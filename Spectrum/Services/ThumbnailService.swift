import Foundation
import AppKit
import ImageIO
import AVFoundation
import CryptoKit

actor ThumbnailService {
    static let shared = ThumbnailService()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let cacheDirectory: URL
    private let thumbnailSize: Int = 300

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("Spectrum/Thumbnails", isDirectory: true)

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        memoryCache.countLimit = 500
    }

    private var cacheLimitBytes: Int64 {
        let mb = UserDefaults.standard.integer(forKey: "thumbnailCacheLimitMB")
        if mb == 0 { return Int64.max }  // unlimited
        let limit = mb > 0 ? mb : 500   // default 500 MB
        return Int64(limit) * 1024 * 1024
    }

    func thumbnail(for filePath: String, bookmarkData: Data? = nil) async -> NSImage? {
        let key = filePath as NSString

        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        let diskURL = diskCacheURL(for: filePath)
        if FileManager.default.fileExists(atPath: diskURL.path),
           let image = NSImage(contentsOf: diskURL) {
            memoryCache.setObject(image, forKey: key)
            return image
        }

        let url = URL(fileURLWithPath: filePath)
        var folderURL: URL?
        var didStart = false
        if let bookmarkData,
           let resolved = try? BookmarkService.resolveBookmark(bookmarkData) {
            folderURL = resolved
            didStart = resolved.startAccessingSecurityScopedResource()
        }
        let image = await generateAndCacheThumbnail(from: url, to: diskURL)
        if didStart, let folderURL {
            folderURL.stopAccessingSecurityScopedResource()
        }

        guard let image else { return nil }

        memoryCache.setObject(image, forKey: key)
        evictIfNeeded()
        return image
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func diskCacheSize() async -> Int64 {
        let directory = cacheDirectory
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }

            var total: Int64 = 0
            for case let fileURL as URL in enumerator.allObjects {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
            return total
        }.value
    }

    // MARK: - Cache eviction

    private func evictIfNeeded() {
        let limit = cacheLimitBytes
        guard limit < Int64.max else { return }

        let directory = cacheDirectory
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            struct CacheEntry {
                let url: URL
                let size: Int64
                let accessDate: Date
            }

            var entries: [CacheEntry] = []
            var totalSize: Int64 = 0

            for case let fileURL as URL in enumerator.allObjects {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]) else { continue }
                let size = Int64(values.fileSize ?? 0)
                let date = values.contentAccessDate ?? .distantPast
                entries.append(CacheEntry(url: fileURL, size: size, accessDate: date))
                totalSize += size
            }

            guard totalSize > limit else { return }

            // Sort oldest-accessed first
            entries.sort { $0.accessDate < $1.accessDate }

            for entry in entries {
                guard totalSize > limit else { break }
                try? fm.removeItem(at: entry.url)
                totalSize -= entry.size
            }
        }
    }

    // MARK: - Thumbnail generation

    private func generateAndCacheThumbnail(from url: URL, to diskURL: URL) async -> NSImage? {
        if url.isVideoFile {
            return await generateAndCacheVideoThumbnail(from: url, to: diskURL)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        // Strip alpha for opaque photos to avoid "AlphaPremulLast" warnings
        let opaqueImage: CGImage
        if cgImage.alphaInfo != .none && cgImage.alphaInfo != .noneSkipLast && cgImage.alphaInfo != .noneSkipFirst,
           let colorSpace = cgImage.colorSpace,
           let ctx = CGContext(
               data: nil,
               width: cgImage.width,
               height: cgImage.height,
               bitsPerComponent: cgImage.bitsPerComponent,
               bytesPerRow: 0,
               space: colorSpace,
               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
           ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            opaqueImage = ctx.makeImage() ?? cgImage
        } else {
            opaqueImage = cgImage
        }

        guard let destination = CGImageDestinationCreateWithURL(
            diskURL as CFURL, "public.heic" as CFString, 1, nil
        ) else {
            return NSImage(cgImage: opaqueImage, size: NSSize(width: opaqueImage.width, height: opaqueImage.height))
        }

        CGImageDestinationAddImage(destination, opaqueImage, nil)
        CGImageDestinationFinalize(destination)

        return NSImage(contentsOf: diskURL)
            ?? NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func generateAndCacheVideoThumbnail(from url: URL, to diskURL: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: thumbnailSize, height: thumbnailSize)
        generator.appliesPreferredTrackTransform = true

        guard let result = try? await generator.image(at: .zero),
              case let cgImage = result.image else {
            return nil
        }

        if let destination = CGImageDestinationCreateWithURL(
            diskURL as CFURL, "public.heic" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
        }

        return NSImage(contentsOf: diskURL)
            ?? NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func diskCacheURL(for filePath: String) -> URL {
        let data = Data(filePath.utf8)
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hashString).heic")
    }
}
