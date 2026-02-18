import SwiftUI
import SwiftData

struct SubfolderInfo: Identifiable {
    let name: String
    let path: String
    let coverPath: String?
    var id: String { path }
}

struct PhotoGridView: View {
    var viewModel: LibraryViewModel
    @Binding var selectedPhoto: Photo?
    var onDoubleClick: ((Photo) -> Void)? = nil
    var onNavigateToSubfolder: ((String) -> Void)? = nil
    var folder: ScannedFolder? = nil
    var folderPath: String? = nil

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.dateTaken, order: .reverse) private var allPhotos: [Photo]

    @State private var subfolders: [SubfolderInfo] = []
    @State private var isScanning = true
    @State private var selectedItemId: String?

    private var effectivePath: String? {
        folderPath ?? folder?.path
    }

    /// Photos directly in the current folder (one level only)
    private var directPhotos: [Photo] {
        guard let path = effectivePath else { return [] }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return allPhotos.filter { photo in
            guard photo.filePath.hasPrefix(prefix) else { return false }
            let relative = String(photo.filePath.dropFirst(prefix.count))
            return !relative.contains("/")
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 2)
    ]

    var body: some View {
        let sections = viewModel.timelineSections(from: directPhotos)
        let flatItems = buildFlatItems(sections: sections)

        GeometryReader { geo in
            let columnCount = max(1, Int((geo.size.width + 2) / 152))

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        if !subfolders.isEmpty {
                            Section {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(subfolders) { info in
                                        SubfolderTileView(
                                            name: info.name,
                                            coverPath: info.coverPath,
                                            bookmarkData: folder?.bookmarkData,
                                            isSelected: selectedItemId == info.path
                                        )
                                        .id(info.path)
                                        .onTapGesture(count: 2) {
                                            onNavigateToSubfolder?(info.path)
                                        }
                                        .onTapGesture {
                                            selectedItemId = info.path
                                            selectedPhoto = nil
                                        }
                                    }
                                }
                                .padding(.horizontal, 2)
                            } header: {
                                TimelineSectionHeader(label: "Folders", count: subfolders.count, unit: "folders")
                            }
                        }

                        if sections.isEmpty && subfolders.isEmpty && !isScanning {
                            ContentUnavailableView(
                                "No Photos",
                                systemImage: "photo.on.rectangle.angled",
                                description: Text("This folder has no photos.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            ForEach(sections) { section in
                                Section {
                                    LazyVGrid(columns: columns, spacing: 2) {
                                        ForEach(section.photos) { photo in
                                            PhotoThumbnailView(
                                                photo: photo,
                                                isSelected: selectedItemId == photo.filePath,
                                                folderBookmarkData: folder?.bookmarkData
                                            )
                                            .id(photo.filePath)
                                            .onTapGesture(count: 2) {
                                                onDoubleClick?(photo)
                                            }
                                            .onTapGesture {
                                                selectedItemId = photo.filePath
                                                selectedPhoto = photo
                                            }
                                            .contextMenu {
                                                PhotoContextMenu(photo: photo)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                } header: {
                                    TimelineSectionHeader(
                                        label: section.label,
                                        count: section.photos.count
                                    )
                                }
                            }
                        }
                    }
                }
                .onChange(of: selectedItemId) { _, newId in
                    if let newId {
                        withAnimation {
                            scrollProxy.scrollTo(newId, anchor: .center)
                        }
                    }
                }
            }
            .focusedSceneValue(\.photoNavigation, PhotoNavigationAction(
                navigateLeft: { navigate(by: -1, in: flatItems) },
                navigateRight: { navigate(by: 1, in: flatItems) },
                navigateUp: { navigate(by: -columnCount, in: flatItems) },
                navigateDown: { navigate(by: columnCount, in: flatItems) },
                enter: { activateSelection() }
            ))
        }
        .frame(minWidth: 400)
        .overlay {
            if isScanning {
                ProgressView("Scanning...")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: effectivePath) {
            await scanCurrentLevel()
        }
        .onChange(of: effectivePath) { _, _ in
            selectedItemId = nil
        }
    }

    private func buildFlatItems(sections: [TimelineSection]) -> [String] {
        var items: [String] = subfolders.map(\.path)
        for section in sections {
            items.append(contentsOf: section.photos.map(\.filePath))
        }
        return items
    }

    private func navigate(by offset: Int, in flatItems: [String]) {
        guard !flatItems.isEmpty else { return }
        guard let current = selectedItemId,
              let index = flatItems.firstIndex(of: current) else {
            selectedItemId = flatItems.first
            syncSelection()
            return
        }
        let newIndex = min(max(0, index + offset), flatItems.count - 1)
        selectedItemId = flatItems[newIndex]
        syncSelection()
    }

    private func syncSelection() {
        if let id = selectedItemId,
           let photo = directPhotos.first(where: { $0.filePath == id }) {
            selectedPhoto = photo
        } else {
            selectedPhoto = nil
        }
    }

    private func activateSelection() {
        guard let id = selectedItemId else { return }
        if let sf = subfolders.first(where: { $0.path == id }) {
            onNavigateToSubfolder?(sf.path)
        } else if let photo = directPhotos.first(where: { $0.filePath == id }) {
            onDoubleClick?(photo)
        }
    }

    private func scanCurrentLevel() async {
        guard let folder else { return }
        let scanner = FolderScanner(modelContainer: modelContext.container)

        isScanning = true
        // Scan one level of the current path
        try? await scanner.scanFolder(id: folder.persistentModelID, subPath: folderPath)
        // List filesystem subdirectories
        let dirs = await scanner.listSubfolders(id: folder.persistentModelID, path: effectivePath)
        subfolders = dirs.map { SubfolderInfo(name: $0.name, path: $0.path, coverPath: $0.coverPath) }
        isScanning = false
    }
}

private struct SubfolderTileView: View {
    let name: String
    let coverPath: String?
    let bookmarkData: Data?
    var isSelected: Bool = false
    @State private var coverImage: NSImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let coverImage {
                GeometryReader { geo in
                    Image(nsImage: coverImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .frame(height: 150)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.3))
            }

            Text(name)
                .font(.caption.bold())
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .task {
            guard let coverPath else { return }
            coverImage = await ThumbnailService.shared.thumbnail(for: coverPath, bookmarkData: bookmarkData)
        }
    }
}

struct PhotoContextMenu: View {
    let photo: Photo

    var body: some View {
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(photo.filePath, inFileViewerRootedAtPath: "")
        }
    }
}
