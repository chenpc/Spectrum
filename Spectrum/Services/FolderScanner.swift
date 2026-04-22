import SwiftData
import Foundation
import ImageIO
import AVFoundation
import os


@ModelActor
actor FolderScanner {
    private let batchSize = 100

    /// Safely fetch a ScannedFolder by PersistentIdentifier.
    /// Unlike `modelContext.model(for:)`, this returns nil if the object has been deleted,
    /// preventing SwiftData assertion failures on property access.
    private func fetchFolder(_ id: PersistentIdentifier) -> ScannedFolder? {
        guard let folders = try? modelContext.fetch(FetchDescriptor<ScannedFolder>()) else { return nil }
        return folders.first { $0.persistentModelID == id }
    }

    /// Derive a child URL from the bookmark-resolved rootURL to stay within its security scope.
    private func childURL(rootURL: URL, rootPath: String, childPath: String) -> URL {
        if childPath == rootPath || childPath.isEmpty {
            return rootURL
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard childPath.hasPrefix(prefix) else { return rootURL }
        let relative = String(childPath.dropFirst(prefix.count))
        return relative.isEmpty ? rootURL : rootURL.appendingPathComponent(relative)
    }

    /// Fetch direct-child photos for a given directory prefix (one DB fetch, reused for multiple purposes).
    private func directChildPhotos(levelPrefix: String) -> [Photo] {
        let allPhotos: [Photo]
        do {
            allPhotos = try modelContext.fetch(FetchDescriptor<Photo>())
        } catch {
            Log.scanner.warning("Failed to fetch photos: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return allPhotos.filter { photo in
            guard photo.filePath.hasPrefix(levelPrefix) else { return false }
            let relative = String(photo.filePath.dropFirst(levelPrefix.count))
            return !relative.contains("/")
        }
    }

    /// Scan one level of a folder (non-recursive).
    /// - `subPath`: optional subfolder path to scan instead of root
    func scanFolder(id: PersistentIdentifier, subPath: String? = nil) async throws {
        guard let folder = fetchFolder(id),
              let bookmarkData = folder.bookmarkData else { return }
        let scanTarget = subPath ?? folder.path
        Log.scanner.info("[scanner] start scan \(scanTarget, privacy: .public)")

        let rootURL: URL
        do {
            rootURL = try BookmarkService.resolveBookmark(bookmarkData)
        } catch {
            Log.bookmark.warning("Failed to resolve bookmark for folder \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let rootPath = rootURL.path
        let targetURL = subPath.map { childURL(rootURL: rootURL, rootPath: rootPath, childPath: $0) } ?? rootURL

        let didStart = rootURL.startAccessingSecurityScopedResource()
        defer { if didStart { rootURL.stopAccessingSecurityScopedResource() } }

        try Task.checkCancellation()

        // Collect media URLs — one level only
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            Log.scanner.warning("Failed to list directory \(targetURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        // All media paths at this level (used for delta removal later)
        let allDiskMediaPaths = Set(contents.filter { $0.isMediaFile }.map(\.path))

        // Fetch level photos once — reused for existing-check, delta removal, and live photo pairing
        let levelPrefix = targetURL.path.hasSuffix("/") ? targetURL.path : targetURL.path + "/"
        let levelPhotos = directChildPhotos(levelPrefix: levelPrefix)
        let existingPaths = Set(levelPhotos.map(\.filePath))

        let mediaURLs = contents.filter { url in
            url.isMediaFile && !existingPaths.contains(url.path)
        }
        Log.debug(Log.scanner, "[scanner] \(targetURL.lastPathComponent): \(contents.count) entries, \(allDiskMediaPaths.count) media on disk, \(existingPaths.count) already in DB, \(mediaURLs.count) new to insert")

        try Task.checkCancellation()

        // Process collected URLs
        var batch: [Photo] = []
        var batchStart = ContinuousClock.now

        for fileURL in mediaURLs {
            guard !Task.isCancelled else { break }
            let filePath = fileURL.path
            let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            let isVideo = fileURL.isVideoFile

            let photo: Photo
            if isVideo {
                let videoMeta = await VideoMetadataService.readMetadata(from: fileURL)
                let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

                photo = Photo(
                    filePath: filePath,
                    fileName: fileURL.lastPathComponent,
                    dateTaken: videoMeta.creationDate ?? modDate,
                    fileSize: Int64(resourceValues?.fileSize ?? 0),
                    pixelWidth: videoMeta.pixelWidth ?? 0,
                    pixelHeight: videoMeta.pixelHeight ?? 0,
                    folder: folder
                )
                photo.isVideo = true
                photo.duration = videoMeta.duration
                photo.videoCodec = videoMeta.videoCodec
                photo.audioCodec = videoMeta.audioCodec
                photo.latitude = videoMeta.latitude
                photo.longitude = videoMeta.longitude
            } else {
                let exif = EXIFService.readEXIF(from: fileURL)
                if exif.dateTaken == nil {
                    Log.debug(Log.scanner, "[scanner] no EXIF date for \(fileURL.lastPathComponent) — falling back to mtime")
                }

                photo = Photo(
                    filePath: filePath,
                    fileName: fileURL.lastPathComponent,
                    dateTaken: exif.dateTaken ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(),
                    fileSize: Int64(resourceValues?.fileSize ?? 0),
                    pixelWidth: exif.pixelWidth ?? 0,
                    pixelHeight: exif.pixelHeight ?? 0,
                    folder: folder
                )
                photo.cameraMake = exif.cameraMake
                photo.cameraModel = exif.cameraModel
                photo.lensModel = exif.lensModel
                photo.focalLength = exif.focalLength
                photo.aperture = exif.aperture
                photo.shutterSpeed = exif.shutterSpeed
                photo.iso = exif.iso
                photo.latitude = exif.latitude
                photo.longitude = exif.longitude

                photo.exposureBias = exif.exposureBias
                photo.exposureProgram = exif.exposureProgram
                photo.meteringMode = exif.meteringMode
                photo.flash = exif.flash
                photo.whiteBalance = exif.whiteBalance
                photo.brightnessValue = exif.brightnessValue
                photo.focalLenIn35mm = exif.focalLenIn35mm
                photo.sceneCaptureType = exif.sceneCaptureType
                photo.lightSource = exif.lightSource
                photo.digitalZoomRatio = exif.digitalZoomRatio
                photo.contrast = exif.contrast
                photo.saturation = exif.saturation
                photo.sharpness = exif.sharpness
                photo.lensSpecification = exif.lensSpecification
                photo.offsetTimeOriginal = exif.offsetTimeOriginal
                photo.subsecTimeOriginal = exif.subsecTimeOriginal
                photo.exifVersion = exif.exifVersion

                photo.headroom = exif.headroom
                photo.profileName = exif.profileName
                photo.colorDepth = exif.colorDepth
                photo.orientation = exif.orientation
                photo.dpiWidth = exif.dpiWidth
                photo.dpiHeight = exif.dpiHeight

                photo.software = exif.software
                photo.imageStabilization = exif.imageStabilization

                // Read XMP sidecar for edits + gyro config
                if let xmp = XMPSidecarService.read(
                    for: fileURL,
                    originalOrientation: photo.orientation ?? 1
                ) {
                    var ops: [EditOp] = []
                    if xmp.flipH { ops.append(.flipH) }
                    if xmp.rotation != 0 { ops.append(.rotate(xmp.rotation)) }
                    if let crop = xmp.crop { ops.append(.crop(crop)) }
                    if !ops.isEmpty { photo.editOps = ops }
                }
            }

            modelContext.insert(photo)
            batch.append(photo)

            if batch.count >= batchSize || ContinuousClock.now - batchStart >= .seconds(1) {
                do {
                    try modelContext.save()
                } catch {
                    Log.scanner.warning("Failed to save batch: \(error.localizedDescription, privacy: .public)")
                }
                batch.removeAll(keepingCapacity: true)
                batchStart = ContinuousClock.now
            }
        }

        if !batch.isEmpty {
            do {
                try modelContext.save()
            } catch {
                Log.scanner.warning("Failed to save final batch: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard !Task.isCancelled else { return }

        Log.scanner.info("[scanner] done \(targetURL.lastPathComponent, privacy: .public): inserted \(mediaURLs.count) files")

        // Re-fetch level photos after inserts for live photo pairing + delta removal
        let updatedLevelPhotos = directChildPhotos(levelPrefix: levelPrefix)

        // Live Photo pairing: match image + short .mov by base filename
        pairLivePhotos(levelPhotos: updatedLevelPhotos)

        // Delta removal: remove DB entries for files that existed at this level
        // in the previous scan but are no longer on disk.
        var deletedAny = false
        for photo in updatedLevelPhotos {
            guard !allDiskMediaPaths.contains(photo.filePath) else { continue }
            modelContext.delete(photo)
            deletedAny = true
        }
        if deletedAny {
            do {
                try modelContext.save()
            } catch {
                Log.scanner.warning("Failed to save after delta removal: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Recursively scan a folder and ALL subdirectories, inserting every media file into the DB.
    /// Used when adding a new folder for the first time.
    func scanFolderDeep(id: PersistentIdentifier) async throws {
        // E: fetch folder once
        guard let folder = fetchFolder(id),
              let bookmarkData = folder.bookmarkData else { return }
        let folderPath = folder.path

        // D: resolve bookmark + open scope ONCE for entire scan
        let rootURL: URL
        do {
            rootURL = try BookmarkService.resolveBookmark(bookmarkData)
        } catch {
            Log.bookmark.warning("Failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
            return
        }
        let didStart = rootURL.startAccessingSecurityScopedResource()
        defer { if didStart { rootURL.stopAccessingSecurityScopedResource() } }

        let t0 = ContinuousClock.now
        Log.info(Log.scanner, "[scanner] scanning: \(rootURL.lastPathComponent)")

        // A: Delete all existing photos for this folder ONCE
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let allExisting = (try? modelContext.fetch(FetchDescriptor<Photo>())) ?? []
        let toDelete = allExisting.filter { $0.filePath.hasPrefix(prefix) || $0.filePath == rootURL.path }
        for photo in toDelete { modelContext.delete(photo) }
        if !toDelete.isEmpty { try? modelContext.save() }
        Log.info(Log.scanner, "[scanner] deep scan: deleted \(toDelete.count) existing photos in \(fmtDur(ContinuousClock.now - t0))")

        try Task.checkCancellation()

        // A: Enumerate ALL media files in ONE recursive pass
        let t1 = ContinuousClock.now
        var mediaURLs: [URL] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            // .allObjects 會把整個目錄樹所有 CFURL 一次性載入記憶體；
            // 改用同步 helper（非 async context）做 lazy for-in，
            // 非媒體檔的 URL 迭代後立即釋放，只保留媒體檔。
            mediaURLs = Self.collectMediaURLs(from: enumerator)
        }
        Log.info(Log.scanner, "[scanner] deep scan: found \(mediaURLs.count) media files in \(fmtDur(ContinuousClock.now - t1))")
        let foundCount = mediaURLs.count
        Task { @MainActor in
            ThumbnailProgress.shared.addScanCount(foundCount)
            ThumbnailProgress.shared.addTotal(foundCount)  // 分母即時增長，UI 顯示 0/N
            ThumbnailProgress.shared.markScanFinished()    // 列舉完成即清 Scanning，DB 寫入不算 scan
        }

        try Task.checkCancellation()

        // C: Insert with filesystem attributes only (no EXIF, no video metadata)
        let t2 = ContinuousClock.now
        var batch: [Photo] = []
        var batchStart = ContinuousClock.now

        for url in mediaURLs {
            guard !Task.isCancelled else { break }
            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let photo = Photo(
                filePath: url.path,
                fileName: url.lastPathComponent,
                dateTaken: resourceValues?.contentModificationDate ?? Date(),
                fileSize: Int64(resourceValues?.fileSize ?? 0),
                pixelWidth: 0,
                pixelHeight: 0,
                folder: folder
            )
            photo.isVideo = url.isVideoFile
            modelContext.insert(photo)
            batch.append(photo)

            // 純時間觸發：避免 count-based save 在快速掃描時觸發 O(N²) 的 @Query 主執行緒更新
            // 每秒存一次，讓 grid 即時反映新增照片
            if ContinuousClock.now - batchStart >= .seconds(1) {
                try? modelContext.save()
                batch.removeAll(keepingCapacity: true)
                batchStart = ContinuousClock.now
                ThumbnailScheduler.shared.schedule(container: modelContext.container, priority: .utility)
            }
        }
        if !batch.isEmpty { try? modelContext.save() }
        ThumbnailScheduler.shared.schedule(container: modelContext.container, priority: .utility)
        Log.info(Log.scanner, "[scanner] deep scan: inserted \(mediaURLs.count) photos in \(fmtDur(ContinuousClock.now - t2))")

        guard !Task.isCancelled else { return }

        // Live photo pairing (after all inserts; duration=nil treated as potential live photo)
        let allInserted = (try? modelContext.fetch(FetchDescriptor<Photo>())) ?? []
        let folderPhotos = allInserted.filter { $0.filePath.hasPrefix(prefix) || $0.filePath == rootURL.path }
        pairLivePhotos(levelPhotos: folderPhotos)

        Log.info(Log.scanner, "[scanner] deep scan TOTAL: \(folderPath) in \(fmtDur(ContinuousClock.now - t0))")
    }

    /// 同步枚舉媒體檔，只保留媒體 URL，其餘即時釋放。
    /// 必須在非 async 函數中執行，否則 Swift 6 禁止在 async context 對非 Sendable
    /// 的 NSDirectoryEnumerator 呼叫 makeIterator()。
    private static func collectMediaURLs(from enumerator: FileManager.DirectoryEnumerator) -> [URL] {
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.hasDirectoryPath && url.isSkippedCameraDirectory {
                enumerator.skipDescendants()
                continue
            }
            if url.isMediaFile { result.append(url) }
        }
        return result
    }

    /// Pair Live Photos: for each image, if a short .mov with the same base name exists, link them.
    private func pairLivePhotos(levelPhotos: [Photo]) {
        // Build lookup by lowercase base name (without extension)
        var imagesByBase: [String: [Photo]] = [:]
        var videosByBase: [String: [Photo]] = [:]

        for photo in levelPhotos {
            let url = URL(fileURLWithPath: photo.filePath)
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            if photo.isVideo {
                videosByBase[base, default: []].append(photo)
            } else {
                imagesByBase[base, default: []].append(photo)
            }
        }

        var changed = false
        for (base, images) in imagesByBase {
            guard let videos = videosByBase[base] else { continue }
            // Find short companion .mov (< 5 seconds, or nil duration = not yet read)
            guard let companion = videos.first(where: { $0.duration == nil || $0.duration! < 5 }) else { continue }
            // Pair with the first image
            let image = images[0]
            if image.livePhotoMovPath != companion.filePath {
                image.livePhotoMovPath = companion.filePath
                changed = true
            }
            if !companion.isLivePhotoMov {
                companion.isLivePhotoMov = true
                changed = true
            }
        }

        let pairedCount = imagesByBase.values.filter { images in
            guard let base = images.first.map({ URL(fileURLWithPath: $0.filePath).deletingPathExtension().lastPathComponent.lowercased() }) else { return false }
            return videosByBase[base]?.first(where: { $0.duration == nil || $0.duration! < 5 }) != nil
        }.count
        Log.debug(Log.scanner, "[scanner] live photo pairing: \(pairedCount) pairs found out of \(imagesByBase.count) images")
        if changed {
            do { try modelContext.save() } catch {
                Log.scanner.warning("Failed to save Live Photo pairing: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 從 DB 查詢直接子目錄，封面使用該子目錄下最新的 Photo filePath。
    /// 完全不讀 filesystem，依賴 ThumbnailScheduler 已生成的 disk cache 顯示封面。
    func listSubfolders(id: PersistentIdentifier, path: String? = nil) -> [(name: String, path: String, coverPath: String?, coverDate: Date?)] {
        guard let folder = fetchFolder(id) else { return [] }
        let targetPath = path ?? folder.path
        let prefix = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"

        guard let allPhotos = try? modelContext.fetch(FetchDescriptor<Photo>()) else { return [] }

        // 按子目錄分組，每組保留最新照片作為封面
        var subdirs: [String: (coverPath: String, coverDate: Date)] = [:]
        for photo in allPhotos where !photo.isLivePhotoMov {
            guard photo.filePath.hasPrefix(prefix) else { continue }
            let relative = String(photo.filePath.dropFirst(prefix.count))
            guard let slash = relative.firstIndex(of: "/") else { continue }
            let subdirPath = prefix + String(relative[..<slash])
            if let existing = subdirs[subdirPath] {
                if photo.dateTaken > existing.coverDate {
                    subdirs[subdirPath] = (photo.filePath, photo.dateTaken)
                }
            } else {
                subdirs[subdirPath] = (photo.filePath, photo.dateTaken)
            }
        }

        Log.debug(Log.scanner, "[listSubfolders] DB: \(subdirs.count) subdirs under \(URL(fileURLWithPath: targetPath).lastPathComponent)")

        return subdirs.map { subdirPath, cover in
            (name: URL(fileURLWithPath: subdirPath).lastPathComponent,
             path: subdirPath,
             coverPath: cover.coverPath,
             coverDate: cover.coverDate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Back-fill `duration` for any video records that were scanned before metadata was available.
    /// Runs in the background; writes directly to the model context.
    func fillMissingDurations(id: PersistentIdentifier) async {
        guard let folder = fetchFolder(id),
              let bookmarkData = folder.bookmarkData,
              let rootURL = try? BookmarkService.resolveBookmark(bookmarkData) else { return }

        let allPhotos = (try? modelContext.fetch(FetchDescriptor<Photo>())) ?? []
        let missing = allPhotos.filter {
            $0.isVideo && $0.duration == nil &&
            $0.filePath.hasPrefix(folder.path)
        }
        guard !missing.isEmpty else { return }
        Log.debug(Log.scanner, "[duration] fillMissing: \(missing.count) videos without duration in \(folder.path)")

        let started = rootURL.startAccessingSecurityScopedResource()
        defer { if started { rootURL.stopAccessingSecurityScopedResource() } }

        var filled = 0
        for photo in missing {
            let fileURL = URL(fileURLWithPath: photo.filePath)
            guard let t = try? await AVURLAsset(url: fileURL).load(.duration),
                  t.seconds.isFinite, t.seconds > 0 else {
                Log.debug(Log.scanner, "[duration] fillMissing: failed for \(fileURL.lastPathComponent)")
                continue
            }
            photo.duration = t.seconds
            filled += 1
        }
        if filled > 0 {
            try? modelContext.save()
            Log.debug(Log.scanner, "[duration] fillMissing: filled \(filled)/\(missing.count) durations in \(folder.path)")
        }
    }

    /// 不再使用：filesystem-first 架構不使用 DB 縮圖記錄。
    func allUncachedPhotos() -> [UncachedPhotoInfo] { return [] }

    /// 不再使用：ThumbnailScheduler 已停用（filesystem-first 架構）。
    func markThumbnailsReady(items: [String]) {}

/// 刪除指定 folder 下的所有 Photo 記錄。
    /// ScannedFolder 記錄本身不刪除，由 removeFolderRecord(id:) 在縮圖清理後呼叫。
    func removePhotos(forFolder id: PersistentIdentifier) {
        let totalStart = ContinuousClock.now
        guard let folder = fetchFolder(id) else { return }
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let folderPath = folder.path
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
        Log.info(Log.scanner, "[removeFolder] start: \(folderName) prefix=\(prefix)")

        // #Predicate 不支援 hasPrefix；delete(model:where:) 有 Swift 6 Sendable 限制
        // → fetch-all + in-memory filter + 個別 delete（save() 包在一個 transaction 裡）
        let t1 = ContinuousClock.now
        let allPhotos = (try? modelContext.fetch(FetchDescriptor<Photo>())) ?? []
        let toRemove = allPhotos.filter { $0.filePath.hasPrefix(prefix) || $0.filePath == folderPath }
        Log.info(Log.scanner, "[removeFolder] fetch+filter → \(toRemove.count) photos: \(fmtDur(ContinuousClock.now - t1))")

        let t2 = ContinuousClock.now
        for photo in toRemove { modelContext.delete(photo) }
        try? modelContext.save()
        Log.info(Log.scanner, "[removePhotos] delete + save \(toRemove.count) photos: \(fmtDur(ContinuousClock.now - t2))")

        Log.info(Log.scanner, "[removePhotos] TOTAL \(folderName): \(toRemove.count) photos in \(fmtDur(ContinuousClock.now - totalStart))")
    }

    /// 不再使用：filesystem-first 架構不需要 disk cache 遷移。
    func migrateToThumbnailCacheV2() async {}

    /// 所有縮圖已生成完畢後呼叫：清除 needsThumbnails 旗標，避免下次啟動時重複 schedule。
    func clearNeedsThumbnails() {
        let folders = (try? modelContext.fetch(FetchDescriptor<ScannedFolder>())) ?? []
        var changed = false
        for folder in folders where folder.needsThumbnails && !folder.isPendingDeletion {
            folder.needsThumbnails = false
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    /// ScannedFolder 記錄最終刪除（在 removePhotos + 縮圖清理完成後呼叫）。
    func removeFolderRecord(id: PersistentIdentifier) {
        guard let folder = fetchFolder(id) else { return }
        let path = folder.path
        modelContext.delete(folder)
        try? modelContext.save()
        Log.info(Log.scanner, "[removeFolderRecord] ScannedFolder deleted: \(path)")
    }
}

// MARK: - Supporting Types

struct UncachedPhotoInfo: Sendable {
    let path: String
    let folderPath: String
    let bookmarkData: Data?
}

// MARK: - Timing helper (file-private)

private func fmtDur(_ d: Duration) -> String {
    let ms = Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1_000_000_000_000_000
    return ms < 1_000 ? String(format: "%.1fms", ms) : String(format: "%.2fs", ms / 1_000)
}
