import SwiftData
import Foundation

@ModelActor
actor FolderScanner {
    private let batchSize = 100

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

    /// Scan one level of a folder (non-recursive).
    /// - `subPath`: optional subfolder path to scan instead of root
    /// - `clearAll`: if true, delete ALL photos for this folder first (used on app launch)
    func scanFolder(id: PersistentIdentifier, subPath: String? = nil, clearAll: Bool = false) async throws {
        guard let folder = modelContext.model(for: id) as? ScannedFolder else { return }
        guard let bookmarkData = folder.bookmarkData,
              let rootURL = try? BookmarkService.resolveBookmark(bookmarkData) else { return }

        let rootPath = rootURL.path
        let targetURL = subPath.map { childURL(rootURL: rootURL, rootPath: rootPath, childPath: $0) } ?? rootURL

        let didStart = rootURL.startAccessingSecurityScopedResource()
        defer { if didStart { rootURL.stopAccessingSecurityScopedResource() } }

        if clearAll {
            // Delete all photos belonging to this folder
            let folderPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            let descriptor = FetchDescriptor<Photo>()
            let allPhotos = (try? modelContext.fetch(descriptor)) ?? []
            for photo in allPhotos where photo.filePath.hasPrefix(folderPrefix) || photo.filePath == rootPath {
                modelContext.delete(photo)
            }
            try? modelContext.save()
        }

        // Collect media URLs — one level only
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        // Skip duplicates
        let existingPaths: Set<String> = {
            let descriptor = FetchDescriptor<Photo>()
            let photos = (try? modelContext.fetch(descriptor)) ?? []
            return Set(photos.map(\.filePath))
        }()

        let mediaURLs = contents.filter { url in
            url.isMediaFile && !existingPaths.contains(url.path)
        }

        // Process collected URLs
        var batch: [Photo] = []

        for fileURL in mediaURLs {
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
            }

            modelContext.insert(photo)
            batch.append(photo)

            if batch.count >= batchSize {
                try? modelContext.save()
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            try? modelContext.save()
        }
    }

    /// List immediate subdirectories at a path within a scanned folder.
    /// Returns name, path, and the first media file path (for cover thumbnail).
    func listSubfolders(id: PersistentIdentifier, path: String? = nil) -> [(name: String, path: String, coverPath: String?)] {
        guard let folder = modelContext.model(for: id) as? ScannedFolder else { return [] }
        guard let bookmarkData = folder.bookmarkData,
              let rootURL = try? BookmarkService.resolveBookmark(bookmarkData) else { return [] }

        let rootPath = rootURL.path
        let targetURL = path.map { childURL(rootURL: rootURL, rootPath: rootPath, childPath: $0) } ?? rootURL

        return BookmarkService.withSecurityScope(rootURL) {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            let dirs = contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            return dirs.map { dirURL in
                // Find first media file in this subdirectory (one level only)
                let coverPath: String? = {
                    guard let subContents = try? fm.contentsOfDirectory(
                        at: dirURL,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) else { return nil }
                    return subContents.first { $0.isMediaFile }?.path
                }()
                return (name: dirURL.lastPathComponent, path: dirURL.path, coverPath: coverPath)
            }
        }
    }
}
