import Foundation
import AppKit
import ImageIO
import AVFoundation
import CryptoKit
import os

actor ThumbnailService {
    static let shared = ThumbnailService()

    private nonisolated(unsafe) let memoryCache = NSCache<NSString, NSImage>()
    private let cacheDirectory: URL
    private let thumbnailSize: Int = 400

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("Spectrum/Thumbnails", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            Log.thumbnail.warning("Failed to create thumbnail cache directory: \(error.localizedDescription, privacy: .public)")
        }
        memoryCache.countLimit = 500
    }

    private var cacheLimitBytes: Int64 {
        let mb = UserDefaults.standard.object(forKey: "thumbnailCacheLimitMB") as? Int ?? 500
        if mb == 0 { return Int64.max }  // unlimited (user chose ∞)
        return Int64(max(mb, 100)) * 1024 * 1024
    }

    nonisolated func cachedThumbnail(for filePath: String) -> NSImage? {
        memoryCache.object(forKey: filePath as NSString)
    }

    func thumbnail(for filePath: String, bookmarkData: Data? = nil) async -> NSImage? {
        let key = filePath as NSString
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent

        if let cached = memoryCache.object(forKey: key) {
            Log.debug(Log.thumbnail, "[thumb] memory hit: \(fileName)")
            return cached
        }

        // Start security scope BEFORE disk cache lookup, because diskCacheURL uses
        // mtime from resourceValues which needs scope access on network volumes.
        let url = URL(fileURLWithPath: filePath)
        var folderURL: URL?
        var didStart = false
        if let bookmarkData {
            do {
                let resolved = try BookmarkService.resolveBookmark(bookmarkData)
                folderURL = resolved
                didStart = resolved.startAccessingSecurityScopedResource()
            } catch {
                Log.bookmark.warning("Failed to resolve bookmark for thumbnail \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let diskURL = diskCacheURL(for: filePath)
        if FileManager.default.fileExists(atPath: diskURL.path),
           let image = NSImage(contentsOf: diskURL) {
            Log.debug(Log.thumbnail, "[thumb] disk hit: \(fileName)")
            if didStart, let folderURL { folderURL.stopAccessingSecurityScopedResource() }
            memoryCache.setObject(image, forKey: key)
            return image
        }

        // Skip if the source file no longer exists — avoids IIOImageSource errors
        guard FileManager.default.fileExists(atPath: filePath) else {
            Log.debug(Log.thumbnail, "[thumb] source file missing: \(fileName)")
            if didStart, let folderURL { folderURL.stopAccessingSecurityScopedResource() }
            return nil
        }
        Log.debug(Log.thumbnail, "[thumb] cache miss → generating: \(fileName)")

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
        do {
            try FileManager.default.removeItem(at: cacheDirectory)
        } catch {
            Log.thumbnail.warning("Failed to remove cache directory: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            Log.thumbnail.warning("Failed to recreate cache directory: \(error.localizedDescription, privacy: .public)")
        }
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
            Log.debug(Log.thumbnail, "[thumb] eviction triggered: \(totalSize / 1024 / 1024)MB > limit \(limit / 1024 / 1024)MB, \(entries.count) entries")

            // Sort oldest-accessed first
            entries.sort { $0.accessDate < $1.accessDate }

            for entry in entries {
                guard totalSize > limit else { break }
                do {
                    try fm.removeItem(at: entry.url)
                } catch {
                    Log.thumbnail.warning("Failed to evict cache entry: \(error.localizedDescription, privacy: .public)")
                }
                totalSize -= entry.size
            }
        }
    }

    // MARK: - Thumbnail generation

    private func generateAndCacheThumbnail(from url: URL, to diskURL: URL) async -> NSImage? {
        if url.isVideoFile {
            return await generateAndCacheVideoThumbnail(from: url, to: diskURL)
        }

        // SVG: CGImageSource doesn't support vector formats; render via NSImage
        if url.pathExtension.lowercased() == "svg" {
            return generateAndCacheSVGThumbnail(from: url, to: diskURL)
        }

        return await Task.detached(priority: .medium) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: self.thumbnailSize,
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
            if !CGImageDestinationFinalize(destination) {
                Log.thumbnail.error("[thumb] CGImageDestinationFinalize failed for \(url.lastPathComponent, privacy: .public)")
            }

            return NSImage(contentsOf: diskURL)
                ?? NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }

    private func generateAndCacheSVGThumbnail(from url: URL, to diskURL: URL) -> NSImage? {
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

        if let destination = CGImageDestinationCreateWithURL(diskURL as CFURL, "public.heic" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cgImg, nil)
            CGImageDestinationFinalize(destination)
        }

        return NSImage(contentsOf: diskURL)
            ?? NSImage(cgImage: cgImg, size: newSize)
    }

    private func generateAndCacheVideoThumbnail(from url: URL, to diskURL: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: thumbnailSize, height: thumbnailSize)
        generator.appliesPreferredTrackTransform = true

        let cgImage: CGImage
        do {
            let result = try await generator.image(at: .zero)
            cgImage = result.image
        } catch {
            Log.thumbnail.warning("Failed to generate video thumbnail for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
        // Include mtime in the key so cache is automatically invalidated when file changes.
        // resourceValues works without security scope for most local/mounted files.
        let mtime = (try? URL(fileURLWithPath: filePath)
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)
            .map { Int($0.timeIntervalSince1970) }
        let key = mtime.map { "\(filePath)_\($0)" } ?? filePath
        let hash = SHA256.hash(data: Data(key.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hashString).heic")
    }
}
