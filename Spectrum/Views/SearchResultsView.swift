import SwiftUI
import SwiftData

struct SearchResultsView: View {
    let query: String
    let folders: [ScannedFolder]
    var onSelectPhoto: (PhotoItem, ScannedFolder) -> Void
    var onSelectFolder: (ScannedFolder, String) -> Void

    @State private var matchedPhotos: [PhotoItem] = []
    @State private var matchedFolders: [(folder: ScannedFolder, path: String, name: String)] = []

    var body: some View {
        List {
            if !matchedFolders.isEmpty {
                Section("Folders") {
                    ForEach(matchedFolders, id: \.path) { item in
                        Button {
                            onSelectFolder(item.folder, item.path)
                        } label: {
                            Label(item.name, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !matchedPhotos.isEmpty {
                Section("Photos (\(matchedPhotos.count))") {
                    ForEach(matchedPhotos) { item in
                        Button {
                            if let folder = folders.first(where: { item.filePath.hasPrefix($0.path) }) {
                                onSelectPhoto(item, folder)
                            }
                        } label: {
                            photoRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if matchedPhotos.isEmpty && matchedFolders.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: query) {
            await search(query)
        }
    }

    private func photoRow(_ item: PhotoItem) -> some View {
        HStack(spacing: 8) {
            AsyncThumbnail(item: item, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.body)
                    .lineLimit(1)
                Text(item.filePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            matchedPhotos = []
            matchedFolders = []
            return
        }
        let lower = trimmed.lowercased()

        // Extract Sendable data from SwiftData models before entering detached task
        let folderInfos: [(path: String, bookmarkData: Data?)] = folders.map {
            (path: $0.path, bookmarkData: $0.bookmarkData)
        }

        let (photos, folderResults) = await Task.detached(priority: .userInitiated) { @Sendable () -> ([PhotoItem], [(path: String, name: String)]) in
            var photos: [PhotoItem] = []
            var folderMatches: [(path: String, name: String)] = []
            var seenFolderPaths = Set<String>()

            for folderInfo in folderInfos {
                guard let bm = folderInfo.bookmarkData,
                      let rootURL = try? BookmarkService.resolveBookmark(bm) else { continue }
                let started = rootURL.startAccessingSecurityScopedResource()
                defer { if started { rootURL.stopAccessingSecurityScopedResource() } }

                walkDirectory(url: URL(fileURLWithPath: folderInfo.path),
                              lower: lower,
                              photos: &photos,
                              folderMatches: &folderMatches,
                              seenFolderPaths: &seenFolderPaths)
            }
            photos = Array(photos.prefix(200)).sorted { $0.dateTaken > $1.dateTaken }
            return (photos, folderMatches)
        }.value

        matchedPhotos = photos
        // Re-associate folder paths with ScannedFolder objects
        matchedFolders = folderResults.compactMap { match -> (folder: ScannedFolder, path: String, name: String)? in
            guard let folder = folders.first(where: { match.path.hasPrefix($0.path) }) else { return nil }
            return (folder: folder, path: match.path, name: match.name)
        }
    }
}

private func walkDirectory(url: URL, lower: String,
                            photos: inout [PhotoItem],
                            folderMatches: inout [(path: String, name: String)],
                            seenFolderPaths: inout Set<String>) {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return }

    for item in contents {
        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDir {
            let name = item.lastPathComponent
            if name.lowercased().contains(lower), seenFolderPaths.insert(item.path).inserted {
                folderMatches.append((path: item.path, name: name))
            }
            walkDirectory(url: item, lower: lower,
                          photos: &photos, folderMatches: &folderMatches,
                          seenFolderPaths: &seenFolderPaths)
        } else if item.isMediaFile, item.lastPathComponent.lowercased().contains(lower) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: item.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            let fileSize = (attrs?[.size] as? Int64) ?? 0
            let photoItem = PhotoItem(
                filePath: item.path,
                fileName: item.lastPathComponent,
                dateTaken: mtime,
                fileSize: fileSize,
                isVideo: item.isVideoFile
            )
            photos.append(photoItem)
        }
    }
}

private struct AsyncThumbnail: View {
    let item: PhotoItem
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: size, height: size)
            }
        }
        .task {
            image = ThumbnailService.shared.cachedThumbnail(for: item.filePath)
        }
    }
}
