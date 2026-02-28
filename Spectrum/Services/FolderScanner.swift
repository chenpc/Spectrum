import SwiftData
import Foundation
import ImageIO
import os

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
        guard let bookmarkData = folder.bookmarkData else { return }

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
            let descriptor = FetchDescriptor<Photo>()
            let allPhotos: [Photo]
            do {
                allPhotos = try modelContext.fetch(descriptor)
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

        // Skip duplicates already in DB
        let existingPaths: Set<String> = {
            let descriptor = FetchDescriptor<Photo>()
            let photos: [Photo]
            do {
                photos = try modelContext.fetch(descriptor)
            } catch {
                Log.scanner.warning("Failed to fetch existing photos: \(error.localizedDescription, privacy: .public)")
                photos = []
            }
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

        // Delta removal: when not doing a full clear, remove DB entries for files
        // that existed at this level in the previous scan but are no longer on disk.
        if !clearAll {
            let levelPrefix = targetURL.path + "/"
            let allDbPhotos: [Photo]
            do {
                allDbPhotos = try modelContext.fetch(FetchDescriptor<Photo>())
            } catch {
                Log.scanner.warning("Failed to fetch photos for delta removal: \(error.localizedDescription, privacy: .public)")
                allDbPhotos = []
            }
            var deletedAny = false
            for photo in allDbPhotos {
                guard photo.filePath.hasPrefix(levelPrefix) else { continue }
                let relative = String(photo.filePath.dropFirst(levelPrefix.count))
                guard !relative.contains("/") else { continue }   // direct children only
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

    /// List immediate subdirectories at a path within a scanned folder.
    /// Uses FolderListCache to skip the inner contentsOfDirectory on cache hits.
    /// Always performs the outer directory listing to detect added/removed folders.
    func listSubfolders(id: PersistentIdentifier, path: String? = nil) -> [(name: String, path: String, coverPath: String?, coverDate: Date?)] {
        guard let folder = modelContext.model(for: id) as? ScannedFolder else { return [] }
        guard let bookmarkData = folder.bookmarkData else { return [] }

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

            let results = dirs.map { dirURL -> (name: String, path: String, coverPath: String?, coverDate: Date?) in
                // Cache hit: skip inner contentsOfDirectory entirely
                if let cached = cache.entry(forChildPath: dirURL.path, underParent: targetPath) {
                    return (name: cached.name, path: cached.path,
                            coverPath: cached.coverPath, coverDate: cached.coverDate)
                }

                // Cache miss: read inner directory to find cover file
                let subContents: [URL]
                do {
                    subContents = try fm.contentsOfDirectory(
                        at: dirURL,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                } catch {
                    Log.scanner.warning("Failed to list contents of \(dirURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    subContents = []
                }
                let imageFiles = subContents.filter { $0.isImageFile }
                let coverURL: URL? = imageFiles.first ?? subContents.first { $0.isMediaFile }
                let coverPath = coverURL?.path

                // Read EXIF date from cover image
                var coverDate: Date?
                if let cp = coverPath,
                   let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: cp) as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy:MM:dd HH:mm:ss"
                    df.locale = Locale(identifier: "en_US_POSIX")
                    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                    let candidates: [String?] = [
                        exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                        exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                        tiff?[kCGImagePropertyTIFFDateTime] as? String,
                    ]
                    for str in candidates.compactMap({ $0 }) {
                        if let d = df.date(from: str) { coverDate = d; break }
                    }
                }
                // Fallback: use cover file modification time
                if coverDate == nil, let cp = coverPath {
                    coverDate = try? URL(fileURLWithPath: cp)
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
