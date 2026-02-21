import SwiftUI
import SwiftData

struct SubfolderInfo: Identifiable {
    let name: String
    let path: String
    let coverPath: String?
    let coverDate: Date?
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

    /// Live subfolders from filesystem scan (nil = not yet scanned).
    @State private var scannedSubfolders: [SubfolderInfo]? = nil
    @State private var isScanning = true
    @State private var isMounting = false
    @State private var pendingPaths: [String] = []
    @State private var selectedItemId: String?

    // Folder clipboard and edit state
    private let clipboard = FolderClipboard.shared
    @State private var renamingInfo: SubfolderInfo? = nil
    @State private var renameText = ""
    @State private var errorMessage: String? = nil

    /// Subfolders inferred from existing Photo records — available instantly without scanning.
    private var inferredSubfolders: [SubfolderInfo] {
        guard let path = effectivePath else { return [] }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var seen = [String: (path: String, date: Date)]()  // subfolder name → (cover path, cover date)
        for photo in allPhotos {
            guard photo.filePath.hasPrefix(prefix) else { continue }
            let relative = String(photo.filePath.dropFirst(prefix.count))
            if let slashIndex = relative.firstIndex(of: "/") {
                let name = String(relative[..<slashIndex])
                if seen[name] == nil { seen[name] = (path: photo.filePath, date: photo.dateTaken) }
            }
        }
        return seen.map { SubfolderInfo(name: $0, path: prefix + $0, coverPath: $1.path, coverDate: $1.date) }
                   .sorted { subfoldersAreInOrder($0, $1) }
    }

    /// Subfolders to display: live scan results when available, otherwise infer from DB.
    private var subfolders: [SubfolderInfo] {
        scannedSubfolders ?? inferredSubfolders
    }

    private var effectivePath: String? {
        folderPath ?? folder?.path
    }

    private var selectedSubfolder: SubfolderInfo? {
        guard let id = selectedItemId else { return nil }
        return subfolders.first(where: { $0.path == id })
    }

    private var currentFolderEditAction: FolderEditAction {
        // When the rename alert is visible, return empty action so our Cmd+C/X/V
        // are disabled and the text-field responder chain handles them instead.
        guard renamingInfo == nil else { return FolderEditAction() }
        let bm = folder?.bookmarkData ?? Data()
        let sf = selectedSubfolder
        return FolderEditAction(
            copy:  sf.map { info in { self.clipboard.copy(path: info.path, bookmarkData: bm) } },
            cut:   sf.map { info in { self.clipboard.cut(path:  info.path, bookmarkData: bm) } },
            paste: clipboard.hasContent ? { Task { await self.performPaste() } } : nil
        )
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
                                            coverDate: info.coverDate,
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
                                        .contextMenu {
                                            Button("Rename…") {
                                                renamingInfo = info
                                                renameText = info.name
                                            }
                                            Divider()
                                            Button("Copy") {
                                                clipboard.copy(
                                                    path: info.path,
                                                    bookmarkData: folder?.bookmarkData ?? Data()
                                                )
                                            }
                                            Button("Cut") {
                                                clipboard.cut(
                                                    path: info.path,
                                                    bookmarkData: folder?.bookmarkData ?? Data()
                                                )
                                            }
                                            Divider()
                                            Button("Show in Finder") {
                                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: info.path)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 2)
                            } header: {
                                TimelineSectionHeader(label: "Folders", count: subfolders.count, unit: "folders")
                            }
                        }

                        if !pendingPaths.isEmpty {
                            Section {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(pendingPaths, id: \.self) { path in
                                        PlaceholderTileView(
                                            filePath: path,
                                            bookmarkData: folder?.bookmarkData
                                        )
                                    }
                                }
                                .padding(.horizontal, 2)
                            } header: {
                                TimelineSectionHeader(label: "Indexing", count: pendingPaths.count)
                            }
                        }

                        if sections.isEmpty && subfolders.isEmpty && pendingPaths.isEmpty && !isScanning {
                            ContentUnavailableView(
                                "No Photos",
                                systemImage: "photo.on.rectangle.angled",
                                description: Text("This folder has no photos.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 200)
                        }

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
            .focusedSceneValue(\.folderEditAction, currentFolderEditAction)
        }
        .frame(minWidth: 400)
        .contextMenu {
            if let item = clipboard.content {
                Button("Paste \"\(item.name)\"") {
                    Task { await performPaste() }
                }
            }
        }
        .overlay {
            if isMounting && directPhotos.isEmpty && subfolders.isEmpty {
                ProgressView("Connecting…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if isScanning && directPhotos.isEmpty && subfolders.isEmpty && pendingPaths.isEmpty {
                ProgressView("Scanning…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: effectivePath) {
            await scanCurrentLevel()
        }
        .onChange(of: effectivePath) { _, newPath in
            selectedItemId = nil
            pendingPaths = []
            isMounting = false
            isScanning = true
            // Load from cache synchronously to avoid a flash of inferredSubfolders
            let path = newPath ?? folder?.path ?? ""
            if let cached = FolderListCache.shared.entries(for: path) {
                scannedSubfolders = cached
                    .map { SubfolderInfo(name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate) }
                    .sorted { subfoldersAreInOrder($0, $1) }
            } else {
                scannedSubfolders = nil
            }
        }
        .onChange(of: directPhotos) { _, newPhotos in
            guard !pendingPaths.isEmpty else { return }
            let scannedPaths = Set(newPhotos.map(\.filePath))
            pendingPaths = pendingPaths.filter { !scannedPaths.contains($0) }
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renamingInfo != nil },
            set: { if !$0 { renamingInfo = nil } }
        )) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let info = renamingInfo {
                    Task { await performRename(info: info, newName: renameText) }
                }
            }
            Button("Cancel", role: .cancel) { renamingInfo = nil }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        ), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { msg in
            Text(msg)
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

        // If the folder lives on a network volume that isn't mounted, trigger mount first.
        if !NetworkVolumeService.isVolumeMounted(path: folder.path) {
            isMounting = true
            _ = await NetworkVolumeService.ensureMounted(folder: folder)
            isMounting = false
        }

        let scanner = FolderScanner(modelContainer: modelContext.container)
        let cachedPath = effectivePath ?? folder.path

        // Step 0: Show cached subfolder list immediately (no filesystem I/O).
        if scannedSubfolders == nil,
           let cached = FolderListCache.shared.entries(for: cachedPath) {
            scannedSubfolders = cached
                .map { SubfolderInfo(name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate) }
                .sorted { subfoldersAreInOrder($0, $1) }
        }

        isScanning = true

        // Step 1: Fresh filesystem listing — detects additions/removals.
        let dirs = await scanner.listSubfolders(id: folder.persistentModelID, path: effectivePath)
        let freshSubfolders = dirs
            .map { SubfolderInfo(name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate) }
            .sorted { subfoldersAreInOrder($0, $1) }
        // Only update UI if the list actually changed
        if freshSubfolders.map(\.path) != scannedSubfolders?.map(\.path) {
            scannedSubfolders = freshSubfolders
        }

        // Step 2: Quick filesystem listing — show placeholder cells for files not yet indexed.
        if let bm = folder.bookmarkData,
           let rootURL = try? BookmarkService.resolveBookmark(bm) {
            let targetURL = folderPath.map { URL(fileURLWithPath: $0) } ?? rootURL
            let started = rootURL.startAccessingSecurityScopedResource()
            defer { if started { rootURL.stopAccessingSecurityScopedResource() } }
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                let existingPaths = Set(directPhotos.map(\.filePath))
                pendingPaths = contents
                    .filter { $0.isMediaFile && !existingPaths.contains($0.path) }
                    .map(\.path)
                    .sorted()
            }
        }

        // Step 3: Delta scan — reads EXIF, inserts Photo records, removes deleted files.
        // Photos trickle into the grid as @Query propagates each batch save.
        try? await scanner.scanFolder(id: folder.persistentModelID, subPath: folderPath)
        pendingPaths = []
        isScanning = false
    }

    private func performRename(info: SubfolderInfo, newName: String) async {
        guard let bm = folder?.bookmarkData,
              let rootURL = try? BookmarkService.resolveBookmark(bm),
              !newName.isEmpty, newName != info.name else { return }
        let src = URL(fileURLWithPath: info.path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try BookmarkService.withSecurityScope(rootURL) {
                try FileManager.default.moveItem(at: src, to: dst)
            }
            await scanCurrentLevel()
        } catch {
            errorMessage = fileErrorMessage(error)
        }
    }

    private func performPaste() async {
        guard let item = clipboard.content,
              let destPath = effectivePath,
              let dstBM = folder?.bookmarkData else { return }

        guard let srcRootURL = try? BookmarkService.resolveBookmark(item.bookmarkData),
              let dstRootURL = try? BookmarkService.resolveBookmark(dstBM) else {
            errorMessage = "Cannot access folder. Remove and re-add it in the sidebar."
            return
        }

        let src = URL(fileURLWithPath: item.sourcePath)
        let dst = URL(fileURLWithPath: destPath).appendingPathComponent(src.lastPathComponent)

        // Determine if src and dst are under the same security scope
        let crossScope = srcRootURL.standardizedFileURL != dstRootURL.standardizedFileURL

        let srcStarted = srcRootURL.startAccessingSecurityScopedResource()
        // Only start a second scope when the destination root is genuinely different
        let dstStarted = crossScope ? dstRootURL.startAccessingSecurityScopedResource() : false
        defer {
            if srcStarted { srcRootURL.stopAccessingSecurityScopedResource() }
            if dstStarted { dstRootURL.stopAccessingSecurityScopedResource() }
        }

        // fileExists check must happen inside the security scope
        guard !FileManager.default.fileExists(atPath: dst.path) else {
            errorMessage = "\"\(src.lastPathComponent)\" already exists in this folder."
            return
        }

        do {
            if item.isCut {
                if crossScope {
                    // rename() syscall may not span two separate security scopes —
                    // use explicit copy + remove so each operation uses the correct scope.
                    try FileManager.default.copyItem(at: src, to: dst)
                    do {
                        try FileManager.default.removeItem(at: src)
                    } catch {
                        try? FileManager.default.removeItem(at: dst) // roll back
                        throw error
                    }
                } else {
                    try FileManager.default.moveItem(at: src, to: dst)
                }
                clipboard.clear()
            } else {
                try FileManager.default.copyItem(at: src, to: dst)
            }
            await scanCurrentLevel()
        } catch {
            errorMessage = fileErrorMessage(error)
        }
    }

    /// Sort subfolders most-recent first, falling back to alphabetical when dates are equal or absent.
    private func subfoldersAreInOrder(_ a: SubfolderInfo, _ b: SubfolderInfo) -> Bool {
        switch (a.coverDate, b.coverDate) {
        case let (ad?, bd?): return ad == bd ? a.name < b.name : ad > bd
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return a.name < b.name
        }
    }

    private func fileErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        let isPermission = (nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileWriteNoPermissionError ||
             nsError.code == NSFileReadNoPermissionError)) ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EACCES))
        if isPermission {
            return "Write permission denied. Remove and re-add this folder in the sidebar to enable write operations."
        }
        return error.localizedDescription
    }
}

private struct SubfolderTileView: View {
    let name: String
    let coverPath: String?
    let coverDate: Date?
    let bookmarkData: Data?
    var isSelected: Bool = false
    @State private var coverImage: NSImage?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

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

            VStack(spacing: 1) {
                Text(name)
                    .font(.caption.bold())
                    .lineLimit(1)
                if let coverDate {
                    Text(Self.dateFormatter.string(from: coverDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
            if let cached = ThumbnailService.shared.cachedThumbnail(for: coverPath) {
                coverImage = cached
                return
            }
            coverImage = await ThumbnailService.shared.thumbnail(for: coverPath, bookmarkData: bookmarkData)
        }
    }
}

private struct PlaceholderTileView: View {
    let filePath: String
    let bookmarkData: Data?
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                GeometryReader { geo in
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                }
            } else {
                Color.secondary.opacity(0.12)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            if let cached = ThumbnailService.shared.cachedThumbnail(for: filePath) {
                thumbnail = cached
                return
            }
            thumbnail = await ThumbnailService.shared.thumbnail(for: filePath, bookmarkData: bookmarkData)
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
