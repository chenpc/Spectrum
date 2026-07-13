import Foundation

/// 直接從 filesystem 讀取媒體檔案清單，不使用 SwiftData DB。
enum FolderReader {

    // MARK: - Public API

    /// 列出 `folderPath` 目錄的直接媒體檔案（不遞迴）。
    /// 回傳依 dateTaken（= 檔案 mtime）降冪排列的 [PhotoItem]。
    /// 相機直寫的檔案 mtime 即拍攝時間；精確的 EXIF 拍攝時間由 detail view 按需讀取。
    /// 必須在背景 Task 呼叫（filesystem I/O）。
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

        // Separate: images (non-video), .mov files (potential Live Photo), other videos.
        // Also collect .xmp sidecar paths from the same listing so makeItem can skip
        // the per-file fileExists() stat — on network volumes those N stats dominate.
        var imageURLs: [URL] = []
        var movURLs: [URL] = []
        var otherVideoURLs: [URL] = []
        var sidecarPaths = Set<String>()

        for url in contents {
            let ext = url.pathExtension.lowercased()
            if ext == "xmp" {
                sidecarPaths.insert(url.path)
                continue
            }
            guard url.isMediaFile else { continue }
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

        // Images (+ Live Photo companion detection)
        var items: [PhotoItem] = imageURLs.map { url in
            var item = makeItem(from: url, isVideo: false, sidecarPaths: sidecarPaths)
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            if let movURL = movByBasename[base] {
                item.livePhotoMovPath = movURL.path
            }
            return item
        }

        // .mov files paired as Live Photo companions are folded into their image above.
        let companionMovPaths = Set(items.compactMap { $0.livePhotoMovPath })

        // Standalone .mov files (not Live Photo companions)
        for url in movURLs where !companionMovPaths.contains(url.path) {
            items.append(makeItem(from: url, isVideo: true, sidecarPaths: sidecarPaths))
        }

        // All other video formats (.mp4, .m4v, .avi, .mkv, etc.)
        for url in otherVideoURLs {
            items.append(makeItem(from: url, isVideo: true, sidecarPaths: sidecarPaths))
        }

        return items
    }

    private static func makeItem(from url: URL, isVideo: Bool, sidecarPaths: Set<String>) -> PhotoItem {
        // Size + mtime were prefetched by contentsOfDirectory(includingPropertiesForKeys:) —
        // no extra syscall per file.
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        let mtime = values?.contentModificationDate ?? Date.distantPast

        // EditOps from XMP sidecar — only when the directory listing saw a sidecar
        let sidecarPath = XMPSidecarService.sidecarURL(for: url).path
        let editOps = sidecarPaths.contains(sidecarPath) ? readEditOps(imageURL: url) : []

        return PhotoItem(
            filePath: url.path,
            fileName: url.lastPathComponent,
            dateTaken: mtime,
            fileSize: fileSize,
            isVideo: isVideo,
            editOps: editOps
        )
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
