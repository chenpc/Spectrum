import Foundation
import AppKit
import ImageIO
import CryptoKit
import os

private let diskLogger = Logger(subsystem: "com.spectrum.Spectrum", category: "Preload")

extension Notification.Name {
    static let renderedCacheSizeDidChange = Notification.Name("renderedCacheSizeDidChange")
}

/// Disk-based cache for rendered HDR/SDR images.
/// Cache directory: ~/Library/Caches/Spectrum/RenderedImages/
/// HDR files: {sha256(filePath)}_hdr.tiff  (float16, extendedDisplayP3)
/// SDR files: {sha256(filePath)}_sdr.heic  (8-bit, displayP3, quality 0.88)
actor RenderedImageCache {
    static let shared = RenderedImageCache()

    private let cacheDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("Spectrum/RenderedImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API (nonisolated: no mutable actor state)

    /// Returns the cache file URL if it exists on disk. Filename is the cache key hash only.
    nonisolated func lookupCacheFile(for filePath: String) -> URL? {
        let url = cacheDirectory.appendingPathComponent(cacheKey(for: filePath))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Write image to disk cache.
    /// - `isHDR`: true → float16 TIFF (preserves EDR values); false → HEIC.
    nonisolated func store(filePath: String, image: NSImage?, isHDR: Bool) {
        let name = URL(fileURLWithPath: filePath).lastPathComponent
        diskLogger.info("[Disk] store called: \(name) isHDR=\(isHDR)")

        evictIfNeeded()

        guard let image else { return }
        let url = cacheDirectory.appendingPathComponent(cacheKey(for: filePath))
        let ok = isHDR ? writeHDR(image, to: url) : writeSDR(image, to: url)

        if ok {
            let dir = cacheDirectory.path
            let hash = cacheKey(for: filePath)
            diskLogger.info("[Disk] Wrote: \(name) → \(dir)/\(hash)")
        } else {
            diskLogger.error("[Disk] Write FAILED: \(name)")
        }

        // Evict again after writing to account for the newly added files.
        evictIfNeeded()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .renderedCacheSizeDidChange, object: nil)
        }
    }

    /// Total disk usage of the rendered image cache.
    nonisolated func diskCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator.allObjects {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Delete all cached rendered images.
    nonisolated func clearAll() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Private

    private nonisolated var cacheLimitBytes: Int64 {
        let mb = UserDefaults.standard.integer(forKey: "renderedCacheLimitMB")
        if mb == 0 { return Int64.max }           // unlimited
        let limit = mb > 0 ? mb : 5000            // default 5 GB
        return Int64(limit) * 1024 * 1024
    }

    /// Cache key: SHA-256 of "<fullPath>\0<modificationDate seconds>".
    /// Including the modification date ensures stale cache entries are never
    /// served after a file is overwritten, and avoids collisions between same-named
    /// files in different directories.
    private nonisolated func cacheKey(for filePath: String) -> String {
        var key = filePath
        let url = URL(fileURLWithPath: filePath)
        if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            key += "\0\(Int(mod.timeIntervalSinceReferenceDate))"
        }
        return sha256Hash(key)
    }

    private nonisolated func sha256Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Write HDR image as TIFF (preserves float16 pixel values > 1.0).
    @discardableResult
    private nonisolated func writeHDR(_ image: NSImage, to url: URL) -> Bool {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            diskLogger.error("[Disk] writeHDR: cgImage() returned nil for \(url.lastPathComponent)")
            return false
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else {
            diskLogger.error("[Disk] writeHDR: CGImageDestinationCreateWithURL failed for \(url.lastPathComponent)")
            return false
        }
        CGImageDestinationAddImage(dest, cg, nil)
        let ok = CGImageDestinationFinalize(dest)
        if !ok { diskLogger.error("[Disk] writeHDR: CGImageDestinationFinalize failed for \(url.lastPathComponent)") }
        return ok
    }

    /// Write SDR image as HEIC (8-bit, lossy quality 0.88).
    @discardableResult
    private nonisolated func writeSDR(_ image: NSImage, to url: URL) -> Bool {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            diskLogger.error("[Disk] writeSDR: cgImage() returned nil for \(url.lastPathComponent)")
            return false
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            diskLogger.error("[Disk] writeSDR: CGImageDestinationCreateWithURL failed for \(url.lastPathComponent)")
            return false
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.88]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        let ok = CGImageDestinationFinalize(dest)
        if !ok { diskLogger.error("[Disk] writeSDR: CGImageDestinationFinalize failed for \(url.lastPathComponent)") }
        return ok
    }

    /// LRU eviction: remove oldest-accessed files until under the size limit.
    private nonisolated func evictIfNeeded() {
        let limit = cacheLimitBytes
        guard limit < Int64.max else { return }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry { let url: URL; let size: Int64; let accessDate: Date }
        var entries: [Entry] = []
        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator.allObjects {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            else { continue }
            let size = Int64(values.fileSize ?? 0)
            let date = values.contentAccessDate ?? .distantPast
            entries.append(Entry(url: fileURL, size: size, accessDate: date))
            totalSize += size
        }

        guard totalSize > limit else { return }

        // Evict down to 85% of limit to leave buffer room for the next write.
        let target = limit * 85 / 100
        entries.sort { $0.accessDate < $1.accessDate }
        for entry in entries {
            guard totalSize > target else { break }
            try? fm.removeItem(at: entry.url)
            totalSize -= entry.size
        }
    }
}
