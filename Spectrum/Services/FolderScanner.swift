import SwiftData
import Foundation
import ImageIO
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
    /// - `clearAll`: if true, delete ALL photos for this folder first (used on app launch)
    func scanFolder(id: PersistentIdentifier, subPath: String? = nil, clearAll: Bool = false) async throws {
        guard let folder = fetchFolder(id),
              let bookmarkData = folder.bookmarkData else { return }
        let scanTarget = subPath ?? folder.path
        Log.scanner.info("[scanner] start scan \(scanTarget, privacy: .public) clearAll=\(clearAll)")

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

        if clearAll {
            // Delete all photos belonging to this folder
            let folderPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            let allPhotos: [Photo]
            do {
                allPhotos = try modelContext.fetch(FetchDescriptor<Photo>())
            } catch {
                Log.scanner.warning("Failed to fetch photos for clearAll: \(error.localizedDescription, privacy: .public)")
                allPhotos = []
            }
            for photo in allPhotos where photo.filePath.hasPrefix(folderPrefix) || photo.filePath == rootPath {
                modelContext.delete(photo)
            }
            do {
                try modelContext.save()
            } catch {
                Log.scanner.warning("Failed to save after clearAll: \(error.localizedDescription, privacy: .public)")
            }
        }

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

            if batch.count >= batchSize {
                do {
                    try modelContext.save()
                } catch {
                    Log.scanner.warning("Failed to save batch: \(error.localizedDescription, privacy: .public)")
                }
                batch.removeAll(keepingCapacity: true)
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

        // Delta removal: when not doing a full clear, remove DB entries for files
        // that existed at this level in the previous scan but are no longer on disk.
        if !clearAll {
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
            // Find short companion .mov (< 5 seconds)
            guard let companion = videos.first(where: { ($0.duration ?? 999) < 5 }) else { continue }
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
            return videosByBase[base]?.first(where: { ($0.duration ?? 999) < 5 }) != nil
        }.count
        Log.debug(Log.scanner, "[scanner] live photo pairing: \(pairedCount) pairs found out of \(imagesByBase.count) images")
        if changed {
            do { try modelContext.save() } catch {
                Log.scanner.warning("Failed to save Live Photo pairing: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Recursively cache the entire folder tree under a scanned folder.
    /// Calls `onProgress` on each newly cached directory (name).
    func prefetchFolderTree(id: PersistentIdentifier, onProgress: @Sendable @escaping (String) -> Void = { _ in }) {
        guard let folder = fetchFolder(id),
              let bookmarkData = folder.bookmarkData else { return }
        let rootURL: URL
        do {
            rootURL = try BookmarkService.resolveBookmark(bookmarkData)
        } catch { return }

        BookmarkService.withSecurityScope(rootURL) {
            prefetchRecursive(url: rootURL, rootURL: rootURL, onProgress: onProgress)
        }
    }

    private func prefetchRecursive(url: URL, rootURL: URL, onProgress: (String) -> Void) {
        let fm = FileManager.default
        let cache = FolderListCache.shared
        let parentPath = url.path

        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        let dirs = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !dirs.isEmpty else {
            cache.setEntries([], for: parentPath)
            return
        }

        var entries: [FolderListEntry] = []
        for dirURL in dirs {
            // Use cached entry if available AND it has a valid cover; re-evaluate nil or stale covers
            if let cached = cache.entry(forChildPath: dirURL.path, underParent: parentPath),
               let cp = cached.coverPath,
               fm.fileExists(atPath: cp) {
                entries.append(cached)
            } else {
                let coverURL = findCoverFile(in: dirURL)
                let coverPath = coverURL?.path
                let coverDate = coverPath.flatMap {
                    try? URL(fileURLWithPath: $0)
                        .resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                }
                entries.append(FolderListEntry(name: dirURL.lastPathComponent, path: dirURL.path,
                                               coverPath: coverPath, coverDate: coverDate))
            }
        }

        cache.setEntries(entries, for: parentPath)
        onProgress(url.lastPathComponent)

        // Recurse into subdirectories
        for dirURL in dirs {
            prefetchRecursive(url: dirURL, rootURL: rootURL, onProgress: onProgress)
        }
    }

    /// Recursively find the first media file under a directory (depth-first).
    private func findCoverFile(in url: URL, maxDepth: Int = 5) -> URL? {
        guard maxDepth > 0 else {
            Log.debug(Log.scanner, "[cover] maxDepth reached at \(url.lastPathComponent) — no cover found within depth limit")
            return nil
        }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            Log.debug(Log.scanner, "[cover] contentsOfDirectory failed at \(url.path) — permission or mount issue?")
            return nil
        }

        // Check direct media files first
        let imageFiles = contents.filter { $0.isImageFile }
        if let first = imageFiles.first { return first }
        if let first = contents.first(where: { $0.isMediaFile }) { return first }

        // Recurse into subdirectories
        let dirs = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        Log.debug(Log.scanner, "[cover] \(url.lastPathComponent): 0 media, \(dirs.count) subdirs → recursing (depth=\(maxDepth-1))")
        for dir in dirs {
            if let found = findCoverFile(in: dir, maxDepth: maxDepth - 1) {
                return found
            }
        }
        Log.debug(Log.scanner, "[cover] no media found anywhere under \(url.lastPathComponent)")
        return nil
    }

    /// List immediate subdirectories at a path within a scanned folder.
    /// Uses FolderListCache to skip the inner contentsOfDirectory on cache hits.
    /// Always performs the outer directory listing to detect added/removed folders.
    func listSubfolders(id: PersistentIdentifier, path: String? = nil) -> [(name: String, path: String, coverPath: String?, coverDate: Date?)] {
        guard let folder = fetchFolder(id),
              let bookmarkData = folder.bookmarkData else { return [] }

        let rootURL: URL
        do {
            rootURL = try BookmarkService.resolveBookmark(bookmarkData)
        } catch {
            Log.bookmark.warning("Failed to resolve bookmark for listSubfolders \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        let rootPath = rootURL.path
        let targetURL = path.map { childURL(rootURL: rootURL, rootPath: rootPath, childPath: $0) } ?? rootURL
        let targetPath = targetURL.path
        let cache = FolderListCache.shared

        // Already scanned this session — return cache directly (FolderMonitor invalidates on changes).
        // Skip session cache if any entry has nil coverPath — re-evaluate those in case files were added.
        let isSessionScanned = cache.isScannedThisSession(targetPath)
        let cachedEntries = cache.entries(for: targetPath)
        let allHaveCovers = cachedEntries?.allSatisfy({ cp in
            guard let p = cp.coverPath else { return false }
            return FileManager.default.fileExists(atPath: p)
        }) ?? false
        Log.debug(Log.scanner, "[listSubfolders] enter: \(targetURL.lastPathComponent) isSessionScanned=\(isSessionScanned) cachedCount=\(cachedEntries?.count ?? -1) allHaveCovers=\(allHaveCovers)")
        if let cachedEntries, isSessionScanned, allHaveCovers {
            Log.debug(Log.scanner, "[listSubfolders] early-return (session cache hit): \(targetURL.lastPathComponent)")
            return cachedEntries.map { (name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate) }
        }

        return BookmarkService.withSecurityScope(rootURL) {
            let fm = FileManager.default
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: targetURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            } catch {
                Log.scanner.warning("Failed to list subdirectories at \(targetPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return []
            }

            let dirs = contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

            let fm2 = fm
            let results = dirs.map { dirURL -> (name: String, path: String, coverPath: String?, coverDate: Date?) in
                // Cache hit: skip inner contentsOfDirectory entirely (but re-evaluate nil or stale covers)
                if let cached = cache.entry(forChildPath: dirURL.path, underParent: targetPath),
                   let cp = cached.coverPath,
                   fm2.fileExists(atPath: cp) {
                    return (name: cached.name, path: cached.path,
                            coverPath: cached.coverPath, coverDate: cached.coverDate)
                }

                // Cache miss or nil cover: recursively find cover file
                let coverURL = findCoverFile(in: dirURL)
                let coverPath = coverURL?.path
                Log.debug(Log.scanner, "[listSubfolders] \(dirURL.lastPathComponent): coverPath=\(coverPath ?? "nil")")

                let coverDate = coverPath.flatMap {
                    try? URL(fileURLWithPath: $0)
                        .resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                }

                return (name: dirURL.lastPathComponent, path: dirURL.path,
                        coverPath: coverPath, coverDate: coverDate)
            }

            // Update cache with full results for this parent
            let entries = results.map {
                FolderListEntry(name: $0.name, path: $0.path,
                                coverPath: $0.coverPath, coverDate: $0.coverDate)
            }
            cache.setEntries(entries, for: targetPath)

            return results
        }
    }
}
