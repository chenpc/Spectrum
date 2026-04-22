import Foundation
import ImageIO

/// 直接從 filesystem 讀取媒體檔案清單，不使用 SwiftData DB。
enum FolderReader {

    // MARK: - Public API

    /// 列出 `folderPath` 目錄的直接媒體檔案（不遞迴）。
    /// 回傳依 dateTaken 降冪排列的 [PhotoItem]。
    /// 必須在背景 Task 呼叫（可能進行 filesystem I/O 和 CGImageSource EXIF 讀取）。
    static func listLevel(folderPath: String, bookmarkData: Data?) -> [PhotoItem] {
        var items = withScope(bookmarkData) {
            readLevel(folderPath: folderPath)
        }
        items.sort { $0.dateTaken > $1.dateTaken }
        return items
    }

    /// 列出 `folderPath` 的直接子目錄。
    /// 每個子目錄附帶 coverPath（第一張圖的路徑）和 coverDate（封面圖的 mtime）。
    static func listSubfolders(folderPath: String, bookmarkData: Data?)
        -> [(name: String, path: String, coverPath: String?, coverDate: Date?)]
    {
        withScope(bookmarkData) {
            readSubfolders(folderPath: folderPath)
        }
    }

    // MARK: - Security scope helper

    private static func withScope<T>(_ bookmarkData: Data?, _ body: () -> T) -> T {
        guard let data = bookmarkData,
              let url = try? BookmarkService.resolveBookmark(data) else {
            return body()
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return body()
    }

    // MARK: - File listing

    private static func readLevel(folderPath: String) -> [PhotoItem] {
        let fm = FileManager.default
        let folderURL = URL(fileURLWithPath: folderPath)
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Separate: images (non-video), .mov files (potential Live Photo), other videos
        var imageURLs: [URL] = []
        var movURLs: [URL] = []
        var otherVideoURLs: [URL] = []

        for url in contents {
            guard url.isMediaFile else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "mov" {
                movURLs.append(url)
            } else if url.isVideoFile {
                otherVideoURLs.append(url)
            } else {
                imageURLs.append(url)
            }
        }

        // basename → .mov mapping for Live Photo pairing
        var movByBasename: [String: URL] = [:]
        for mov in movURLs {
            let base = mov.deletingPathExtension().lastPathComponent.lowercased()
            movByBasename[base] = mov
        }

        var items: [PhotoItem] = []
        var companionMovPaths = Set<String>()

        // Images (+ Live Photo companion detection)
        for url in imageURLs {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            var item = makeItem(from: url, isVideo: false)
            if let movURL = movByBasename[base] {
                item.livePhotoMovPath = movURL.path
                companionMovPaths.insert(movURL.path)
            }
            items.append(item)
        }

        // Standalone .mov files (not Live Photo companions)
        for url in movURLs where !companionMovPaths.contains(url.path) {
            items.append(makeItem(from: url, isVideo: true))
        }

        // All other video formats (.mp4, .m4v, .avi, .mkv, etc.)
        for url in otherVideoURLs {
            items.append(makeItem(from: url, isVideo: true))
        }

        return items
    }

    private static func makeItem(from url: URL, isVideo: Bool) -> PhotoItem {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast

        // Quick EXIF date for images only
        var dateTaken = mtime
        if !isVideo, let exifDate = readExifDate(url: url) {
            dateTaken = exifDate
        }

        // EditOps from XMP sidecar (orientation=1 default — acceptable for most landscape photos)
        let editOps = readEditOps(imageURL: url)

        return PhotoItem(
            filePath: url.path,
            fileName: url.lastPathComponent,
            dateTaken: dateTaken,
            fileSize: fileSize,
            isVideo: isVideo,
            editOps: editOps
        )
    }

    // MARK: - EXIF date (quick read)

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func readExifDate(url: URL) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }

        let exifDict = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiffDict = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateStr = exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiffDict?[kCGImagePropertyTIFFDateTime] as? String
        guard let dateStr else { return nil }
        return exifDateFormatter.date(from: dateStr)
    }

    // MARK: - XMP edit ops

    private static func readEditOps(imageURL: URL) -> [EditOp] {
        guard let sidecar = XMPSidecarService.read(for: imageURL, originalOrientation: 1) else { return [] }
        var ops: [EditOp] = []
        if sidecar.rotation != 0 { ops.append(.rotate(sidecar.rotation)) }
        if sidecar.flipH { ops.append(.flipH) }
        if let crop = sidecar.crop { ops.append(.crop(crop)) }
        return ops
    }

    // MARK: - Subfolders

    private static func readSubfolders(folderPath: String)
        -> [(name: String, path: String, coverPath: String?, coverDate: Date?)]
    {
        let fm = FileManager.default
        let folderURL = URL(fileURLWithPath: folderPath)
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !url.isSkippedCameraDirectory else { return nil }
            let (coverPath, coverDate) = firstImageFile(in: url.path)
            return (name: url.lastPathComponent, path: url.path,
                    coverPath: coverPath, coverDate: coverDate)
        }
    }

    /// Find the first image file in a directory (non-recursive) for use as cover.
    private static func firstImageFile(in dirPath: String) -> (String?, Date?) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (nil, nil) }

        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in sorted where url.isImageFile {
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (url.path, date)
        }
        // Fallback: any media file
        for url in sorted where url.isMediaFile {
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (url.path, date)
        }
        return (nil, nil)
    }
}
