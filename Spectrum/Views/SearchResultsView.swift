import SwiftUI
import SwiftData

struct SearchResultsView: View {
    let query: String
    let folders: [ScannedFolder]
    var onSelectPhoto: (Photo, ScannedFolder) -> Void
    var onSelectFolder: (ScannedFolder, String) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var matchedPhotos: [Photo] = []
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
                    ForEach(matchedPhotos) { photo in
                        if let folder = photo.resolveFolder(from: folders) {
                            Button {
                                onSelectPhoto(photo, folder)
                            } label: {
                                photoRow(photo)
                            }
                            .buttonStyle(.plain)
                        }
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

    private func photoRow(_ photo: Photo) -> some View {
        HStack(spacing: 8) {
            AsyncThumbnail(photo: photo, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.fileName)
                    .font(.body)
                    .lineLimit(1)
                Text(photo.filePath)
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

        // Search folders from cache
        let cache = FolderListCache.shared
        var folderResults: [(folder: ScannedFolder, path: String, name: String)] = []
        for folder in folders {
            searchFolderTree(cache: cache, folder: folder, parentPath: folder.path, query: lower, results: &folderResults)
        }
        matchedFolders = folderResults

        // Search photos from DB
        do {
            let allPhotos = try modelContext.fetch(FetchDescriptor<Photo>())
            matchedPhotos = allPhotos
                .filter { $0.fileName.lowercased().contains(lower) }
                .prefix(200)
                .sorted { $0.dateTaken > $1.dateTaken }
        } catch {
            matchedPhotos = []
        }
    }

    private func searchFolderTree(
        cache: FolderListCache,
        folder: ScannedFolder,
        parentPath: String,
        query: String,
        results: inout [(folder: ScannedFolder, path: String, name: String)]
    ) {
        guard let entries = cache.entries(for: parentPath) else { return }
        for entry in entries {
            if entry.name.lowercased().contains(query) {
                results.append((folder: folder, path: entry.path, name: entry.name))
            }
            searchFolderTree(cache: cache, folder: folder, parentPath: entry.path, query: query, results: &results)
        }
    }
}

private struct AsyncThumbnail: View {
    let photo: Photo
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
            image = await ThumbnailService.shared.thumbnail(for: photo.filePath)
        }
    }
}

private extension Photo {
    func resolveFolder(from folders: [ScannedFolder]) -> ScannedFolder? {
        folder ?? folders.first { filePath.hasPrefix($0.path) }
    }
}
