import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SubfolderInfo: Identifiable {
    let name: String
    let path: String
    let coverPath: String?
    let coverDate: Date?
    var id: String { path }
}

struct PhotoGridView: View {
    var viewModel: LibraryViewModel
    @Binding var selectedPhoto: PhotoItem?
    @Binding var initialSelection: String?
    var onDoubleClick: ((PhotoItem) -> Void)? = nil
    var onNavigateToSubfolder: ((String) -> Void)? = nil
    var folder: ScannedFolder? = nil
    var folderPath: String? = nil

    @Query(sort: \ScannedFolder.sortOrder) private var allFolders: [ScannedFolder]

    // Filesystem state
    @State private var allItems: [PhotoItem] = []
    @State private var displayPhotos: [PhotoItem] = []
    @State private var scannedSubfolders: [SubfolderInfo] = []
    @State private var isLoading = true
    @State private var isMounting = false

    // Selection state
    @State private var selectedItemIds: Set<String> = []
    @State private var lastSelectedId: String?

    // Delete dialogs
    @State private var itemToDelete: PhotoItem? = nil
    @State private var itemsToDelete: [PhotoItem] = []
    @State private var foldersToDelete: [SubfolderInfo] = []
    @State private var subfolderToDelete: SubfolderInfo? = nil

    // Clipboard, rename, error
    private let clipboard = FolderClipboard.shared
    private let importModel = ImportPanelModel.shared
    @State private var renamingInfo: SubfolderInfo? = nil
    @State private var renameText = ""
    @State private var errorMessage: String? = nil
    @State private var folderChangeToken = 0

    private var effectivePath: String? {
        folderPath ?? folder?.path
    }

    private var subfolders: [SubfolderInfo] { scannedSubfolders }

    private var selectedSubfolder: SubfolderInfo? {
        guard let id = lastSelectedId else { return nil }
        return subfolders.first(where: { $0.path == id })
    }

    private var currentFolderEditAction: FolderEditAction {
        guard renamingInfo == nil else { return FolderEditAction() }
        let bm = folder?.bookmarkData ?? Data()
        let sf = selectedSubfolder
        let sp = selectedPhoto

        let copyAction: (() -> Void)?
        let cutAction: (() -> Void)?
        if let sf {
            copyAction = { self.clipboard.copy(path: sf.path, bookmarkData: bm) }
            cutAction  = { self.clipboard.cut(path: sf.path, bookmarkData: bm) }
        } else if selectedItemIds.count == 1, let sp {
            copyAction = { self.clipboard.copy(path: sp.filePath, bookmarkData: bm) }
            cutAction  = { self.clipboard.cut(path: sp.filePath, bookmarkData: bm) }
        } else {
            copyAction = nil
            cutAction = nil
        }

        let canPaste = clipboard.hasContent || importModel.draggedGroup != nil
        return FolderEditAction(
            copy:  copyAction,
            cut:   cutAction,
            paste: canPaste ? { Task { await self.performPasteAny() } } : nil
        )
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 2)
    ]

    var body: some View {
        gridWithModifiers
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
            .confirmationDialog("Move to Trash?", isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            ), presenting: itemToDelete) { item in
                Button("Move to Trash", role: .destructive) { performTrash(item: item) }
                Button("Cancel", role: .cancel) { itemToDelete = nil }
            } message: { item in
                Text("\"\(item.fileName)\" will be moved to the Trash.")
            }
            .confirmationDialog("Move to Trash?", isPresented: Binding(
                get: { subfolderToDelete != nil },
                set: { if !$0 { subfolderToDelete = nil } }
            ), presenting: subfolderToDelete) { info in
                Button("Move to Trash", role: .destructive) { Task { await performTrashSubfolder(info: info) } }
                Button("Cancel", role: .cancel) { subfolderToDelete = nil }
            } message: { info in
                Text("Folder \"\(info.name)\" and all its contents will be moved to the Trash.")
            }
            .confirmationDialog("Move to Trash?", isPresented: Binding(
                get: { !itemsToDelete.isEmpty || !foldersToDelete.isEmpty },
                set: { if !$0 { itemsToDelete = []; foldersToDelete = [] } }
            )) {
                Button("Move \(itemsToDelete.count + foldersToDelete.count) Items to Trash", role: .destructive) {
                    let p = itemsToDelete; let f = foldersToDelete
                    itemsToDelete = []; foldersToDelete = []
                    for item in p { performTrash(item: item) }
                    for folder in f { Task { await performTrashSubfolder(info: folder) } }
                }
                Button("Cancel", role: .cancel) { itemsToDelete = []; foldersToDelete = [] }
            } message: {
                Text("\(itemsToDelete.count + foldersToDelete.count) items will be moved to the Trash.")
            }
    }

    private var gridWithModifiers: some View {
        gridBody
            .frame(minWidth: 400)
            .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
                guard let destPath = effectivePath else { return false }
                handleDrop(providers, destinationPath: destPath)
                return true
            }
            .contextMenu { gridContextMenu }
            .overlay { loadingOverlay }
            .task(id: "\(effectivePath ?? "")_\(folderChangeToken)") {
                await loadCurrentLevel()
            }
            .onAppear {
                if let sel = initialSelection {
                    initialSelection = nil
                    selectSingle(sel)
                }
            }
            .onChange(of: effectivePath) { _, _ in
                if let sel = initialSelection {
                    initialSelection = nil
                    selectedItemIds = [sel]
                    lastSelectedId = sel
                } else {
                    selectedItemIds = []
                    lastSelectedId = nil
                }
                isMounting = false
                isLoading = true
                allItems = []
                displayPhotos = []
                scannedSubfolders = []
            }
            .onReceive(NotificationCenter.default.publisher(for: FolderMonitor.folderDidChange)) { note in
                guard let changedPath = note.userInfo?["path"] as? String,
                      let ep = effectivePath,
                      ep.hasPrefix(changedPath) || changedPath.hasPrefix(ep)
                else { return }
                folderChangeToken += 1
            }
    }

    @ViewBuilder
    private var gridContextMenu: some View {
        Button("New Folder") {
            Task { await createNewFolder() }
        }
        if let item = clipboard.content {
            Divider()
            Button("Paste \"\(item.name)\"") {
                Task { await performPaste() }
            }
        } else if let f = clipboard.files {
            Divider()
            Button("\(f.isCut ? "Move" : "Paste") \(f.count) Items") {
                Task { await performPasteFiles() }
            }
        }
        if let group = importModel.draggedGroup {
            Divider()
            let label = importModel.draggedGroupIsCut ? "Move" : "Paste"
            Button("\(label) \"\(group.folderName)\"") {
                let isCut = importModel.draggedGroupIsCut
                importModel.draggedGroup = nil
                importModel.draggedGroupIsCut = false
                if let bm = folder?.bookmarkData, let destPath = effectivePath {
                    Task {
                        await performGroupDrop(group: group, isCut: isCut,
                                               destinationPath: destPath, bookmarkData: bm)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if isMounting && displayPhotos.isEmpty && subfolders.isEmpty {
            ProgressView("Connecting…")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var gridBody: some View {
        let flatItems = buildFlatItems()

        return GeometryReader { geo in
            let columnCount = max(1, Int((geo.size.width + 2) / 152))

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        subfolderSection
                        emptyPlaceholder
                        photoGridSection
                    }
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedItemIds = []
                                lastSelectedId = nil
                                syncSelection()
                            }
                    }
                }
                .id(effectivePath)
                .onChange(of: lastSelectedId) { _, newId in
                    if let newId {
                        withAnimation { scrollProxy.scrollTo(newId, anchor: .center) }
                    }
                }
            }
            .focusedSceneValue(\.photoNavigation, navigationAction(
                flatItems: flatItems, columnCount: columnCount, viewHeight: geo.size.height
            ))
            .focusedSceneValue(\.folderEditAction, currentFolderEditAction)
            .focusedSceneValue(\.deletePhotoAction, !selectedItemIds.isEmpty ? { triggerDeleteSelected() } : nil)
            .focusedSceneValue(\.selectAllAction, { selectAll(flatItems: flatItems) })
        }
    }

    @ViewBuilder
    private var subfolderSection: some View {
        if !subfolders.isEmpty {
            Section {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(subfolders) { info in
                        SubfolderTileView(
                            name: info.name,
                            path: info.path,
                            coverPath: info.coverPath,
                            coverDate: info.coverDate,
                            bookmarkData: folder?.bookmarkData,
                            isSelected: selectedItemIds.contains(info.path)
                        )
                        .id(info.path)
                        .onTapGesture {
                            handleTap(id: info.path, isFolder: true, event: NSApp.currentEvent)
                        }
                        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
                            handleDrop(providers, destinationPath: info.path)
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") {
                                renamingInfo = info
                                renameText = info.name
                            }
                            Divider()
                            Button("Copy") {
                                clipboard.copy(path: info.path, bookmarkData: folder?.bookmarkData ?? Data())
                            }
                            Button("Cut") {
                                clipboard.cut(path: info.path, bookmarkData: folder?.bookmarkData ?? Data())
                            }
                            Divider()
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: info.path)
                            }
                            Button("Add to Import") {
                                importModel.openFolder(url: URL(fileURLWithPath: info.path))
                            }
                            Divider()
                            if selectedItemIds.contains(info.path) && selectedItemIds.count > 1 {
                                Button("Move \(selectedItemIds.count) Items to Trash", role: .destructive) {
                                    triggerDeleteSelected()
                                }
                            } else {
                                Button("Move to Trash", role: .destructive) {
                                    subfolderToDelete = info
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            } header: {
                TimelineSectionHeader(localizedLabel: "Folders", count: subfolders.count, unit: .folders)
            }
        }
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        if displayPhotos.isEmpty && subfolders.isEmpty && !isLoading {
            ContentUnavailableView(
                "No Photos",
                systemImage: "photo.on.rectangle.angled",
                description: Text("This folder has no photos.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private var photoGridSection: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(displayPhotos) { item in
                PhotoThumbnailView(
                    item: item,
                    isSelected: selectedItemIds.contains(item.filePath),
                    folderBookmarkData: folder?.bookmarkData
                )
                .id(item.filePath)
                .onTapGesture {
                    handleTap(id: item.filePath, isFolder: false, event: NSApp.currentEvent)
                }
                .contextMenu {
                    if selectedItemIds.contains(item.filePath) && selectedItemIds.count > 1 {
                        let count = selectedItemIds.count
                        let bm = folder?.bookmarkData ?? Data()
                        let paths = Array(selectedItemIds)
                        Button("Copy \(count) Items") {
                            clipboard.copyFiles(paths: paths, bookmarkData: bm)
                        }
                        Button("Cut \(count) Items") {
                            clipboard.cutFiles(paths: paths, bookmarkData: bm)
                        }
                        Divider()
                        Button("Show in Finder") {
                            for path in paths {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                        }
                        Divider()
                        Button("Move \(count) Items to Trash", role: .destructive) {
                            triggerDeleteSelected()
                        }
                    } else {
                        PhotoContextMenu(
                            item: item,
                            bookmarkData: folder?.bookmarkData,
                            allFolders: Array(allFolders),
                            onDelete: { itemToDelete = item }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Filesystem loading

    private func loadCurrentLevel() async {
        guard let folder else { return }
        isLoading = true

        if !NetworkVolumeService.isVolumeMounted(path: folder.path) {
            isMounting = true
            _ = await NetworkVolumeService.ensureMounted(folder: folder)
            isMounting = false
        }

        let currentPath = effectivePath ?? folder.path
        let bookmarkData = folder.bookmarkData

        let (items, subs) = await Task.detached(priority: .userInitiated) {
            let items = FolderReader.listLevel(folderPath: currentPath, bookmarkData: bookmarkData)
            let subs = FolderReader.listSubfolders(folderPath: currentPath, bookmarkData: bookmarkData)
            return (items, subs)
        }.value

        guard !Task.isCancelled else { return }

        allItems = items
        displayPhotos = items.filter { !$0.isLivePhotoMov }
        scannedSubfolders = subs
            .map { SubfolderInfo(name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate) }
            .sorted { subfoldersAreInOrder($0, $1) }
        viewModel.flatPhotos = displayPhotos
        isLoading = false
    }

    // MARK: - Flat item list for navigation

    private func buildFlatItems() -> [String] {
        var items: [String] = subfolders.map(\.path)
        items.append(contentsOf: displayPhotos.map(\.filePath))
        return items
    }

    // MARK: - Navigation

    private func navigationAction(flatItems: [String], columnCount: Int, viewHeight: CGFloat) -> PhotoNavigationAction {
        let rowsPerPage = max(1, Int(viewHeight / 152))
        let pageSize = rowsPerPage * columnCount
        return PhotoNavigationAction(
            navigateLeft:  { navigate(by: -1, in: flatItems) },
            navigateRight: { navigate(by:  1, in: flatItems) },
            navigateUp:    { navigate(by: -columnCount, in: flatItems, clamp: false) },
            navigateDown:  { navigate(by:  columnCount, in: flatItems, clamp: false) },
            pageUp:        { navigate(by: -pageSize, in: flatItems) },
            pageDown:      { navigate(by:  pageSize, in: flatItems) },
            enter:         { activateSelection() }
        )
    }

    private func navigate(by offset: Int, in flatItems: [String], clamp: Bool = true) {
        guard !flatItems.isEmpty else { return }
        guard let current = lastSelectedId,
              let index = flatItems.firstIndex(of: current) else {
            selectSingle(flatItems.first!)
            return
        }
        let newIndex = index + offset
        guard newIndex >= 0 && newIndex < flatItems.count else {
            if clamp {
                selectSingle(flatItems[min(max(0, newIndex), flatItems.count - 1)])
            }
            return
        }
        selectSingle(flatItems[newIndex])
    }

    private func selectSingle(_ id: String) {
        selectedItemIds = [id]
        lastSelectedId = id
        syncSelection()
    }

    private func selectAll(flatItems: [String]) {
        guard !flatItems.isEmpty else { return }
        selectedItemIds = Set(flatItems)
        lastSelectedId = flatItems.last
        syncSelection()
    }

    private func syncSelection() {
        if let id = lastSelectedId,
           let item = displayPhotos.first(where: { $0.filePath == id }) {
            selectedPhoto = item
        } else {
            selectedPhoto = nil
        }
    }

    private func activateSelection() {
        guard let id = lastSelectedId else { return }
        if let sf = subfolders.first(where: { $0.path == id }) {
            onNavigateToSubfolder?(sf.path)
        } else if let item = displayPhotos.first(where: { $0.filePath == id }) {
            onDoubleClick?(item)
        }
    }

    private func handleTap(id: String, isFolder: Bool, event: NSEvent?) {
        let cmd = event?.modifierFlags.contains(.command) ?? false
        let shift = event?.modifierFlags.contains(.shift) ?? false

        if !cmd && !shift {
            if selectedItemIds == [id] {
                activateItem(id: id)
                return
            }
            selectSingle(id)
        } else if cmd {
            if selectedItemIds.contains(id) {
                selectedItemIds.remove(id)
                if lastSelectedId == id { lastSelectedId = selectedItemIds.first }
            } else {
                selectedItemIds.insert(id)
                lastSelectedId = id
            }
            syncSelection()
        } else if shift {
            let flatItems = buildFlatItems()
            let anchor = lastSelectedId ?? flatItems.first ?? id
            if let startIdx = flatItems.firstIndex(of: anchor),
               let endIdx = flatItems.firstIndex(of: id) {
                let range = min(startIdx, endIdx)...max(startIdx, endIdx)
                selectedItemIds = Set(flatItems[range])
                lastSelectedId = id
            } else {
                selectSingle(id)
            }
            syncSelection()
        }
    }

    private func activateItem(id: String) {
        if let sf = subfolders.first(where: { $0.path == id }) {
            onNavigateToSubfolder?(sf.path)
        } else if let item = displayPhotos.first(where: { $0.filePath == id }) {
            onDoubleClick?(item)
        }
    }

    private func triggerDeleteSelected() {
        let selItems = displayPhotos.filter { selectedItemIds.contains($0.filePath) }
        let selFolders = subfolders.filter { selectedItemIds.contains($0.path) }
        let totalCount = selItems.count + selFolders.count
        if totalCount == 0 { return }
        if totalCount == 1 && selFolders.count == 1 {
            subfolderToDelete = selFolders.first
        } else if totalCount == 1 && selItems.count == 1 {
            itemToDelete = selItems.first
        } else {
            itemsToDelete = selItems
            foldersToDelete = selFolders
        }
    }

    // MARK: - Folder operations

    private func createNewFolder() async {
        guard let destPath = effectivePath,
              let bm = folder?.bookmarkData,
              let rootURL = try? BookmarkService.resolveBookmark(bm) else { return }
        let base = URL(fileURLWithPath: destPath)
        var name = "untitled folder"
        var dst = base.appendingPathComponent(name)
        var counter = 2
        let started = rootURL.startAccessingSecurityScopedResource()
        defer { if started { rootURL.stopAccessingSecurityScopedResource() } }
        while FileManager.default.fileExists(atPath: dst.path) {
            name = "untitled folder \(counter)"
            dst = base.appendingPathComponent(name)
            counter += 1
        }
        do {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: false)
            await loadCurrentLevel()
            let newPath = dst.path
            selectSingle(newPath)
            selectedPhoto = nil
            if let info = subfolders.first(where: { $0.path == newPath }) {
                renamingInfo = info
                renameText = info.name
            }
        } catch {
            errorMessage = fileErrorMessage(error)
        }
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
            await loadCurrentLevel()
        } catch {
            errorMessage = fileErrorMessage(error)
        }
    }

    private func performPasteAny() async {
        if let group = importModel.draggedGroup,
           let destPath = effectivePath,
           let bm = folder?.bookmarkData {
            let isCut = importModel.draggedGroupIsCut
            importModel.draggedGroup = nil
            importModel.draggedGroupIsCut = false
            await performGroupDrop(group: group, isCut: isCut, destinationPath: destPath, bookmarkData: bm)
            return
        }
        await performPaste()
    }

    private func performPaste() async {
        guard let item = clipboard.content,
              let destPath = effectivePath,
              let dstBM = folder?.bookmarkData else { return }

        guard let srcRootURL = try? BookmarkService.resolveBookmark(item.bookmarkData),
              let dstRootURL = try? BookmarkService.resolveBookmark(dstBM) else {
            errorMessage = String(localized: "Cannot access folder. Remove and re-add it in the sidebar.")
            return
        }

        let src = URL(fileURLWithPath: item.sourcePath)
        let dst = URL(fileURLWithPath: destPath).appendingPathComponent(src.lastPathComponent)
        let crossScope = srcRootURL.standardizedFileURL != dstRootURL.standardizedFileURL

        let srcStarted = srcRootURL.startAccessingSecurityScopedResource()
        let dstStarted = crossScope ? dstRootURL.startAccessingSecurityScopedResource() : false
        defer {
            if srcStarted { srcRootURL.stopAccessingSecurityScopedResource() }
            if dstStarted { dstRootURL.stopAccessingSecurityScopedResource() }
        }

        guard !FileManager.default.fileExists(atPath: dst.path) else {
            errorMessage = String(localized: "\"\(src.lastPathComponent)\" already exists in this folder.")
            return
        }

        do {
            if item.isCut {
                if crossScope {
                    try FileManager.default.copyItem(at: src, to: dst)
                    do {
                        try FileManager.default.removeItem(at: src)
                    } catch {
                        try? FileManager.default.removeItem(at: dst)
                        throw error
                    }
                } else {
                    try FileManager.default.moveItem(at: src, to: dst)
                }
                clipboard.clear()
            } else {
                try FileManager.default.copyItem(at: src, to: dst)
            }
            await loadCurrentLevel()
        } catch {
            errorMessage = fileErrorMessage(error)
        }
    }

    private func performPasteFiles() async {
        guard let item = clipboard.files,
              let destPath = effectivePath,
              let dstBM = folder?.bookmarkData else { return }

        guard let srcRootURL = try? BookmarkService.resolveBookmark(item.bookmarkData),
              let dstRootURL = try? BookmarkService.resolveBookmark(dstBM) else {
            errorMessage = String(localized: "Cannot access folder. Remove and re-add it in the sidebar.")
            return
        }

        let crossScope = srcRootURL.standardizedFileURL != dstRootURL.standardizedFileURL
        let srcStarted = srcRootURL.startAccessingSecurityScopedResource()
        let dstStarted = crossScope ? dstRootURL.startAccessingSecurityScopedResource() : false
        defer {
            if srcStarted { srcRootURL.stopAccessingSecurityScopedResource() }
            if dstStarted { dstRootURL.stopAccessingSecurityScopedResource() }
        }

        var encounteredError: Error?
        for path in item.paths {
            let src = URL(fileURLWithPath: path)
            let dst = URL(fileURLWithPath: destPath).appendingPathComponent(src.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: dst.path) else { continue }
            do {
                if item.isCut {
                    if crossScope {
                        try FileManager.default.copyItem(at: src, to: dst)
                        do { try FileManager.default.removeItem(at: src) } catch {
                            try? FileManager.default.removeItem(at: dst)
                            throw error
                        }
                    } else {
                        try FileManager.default.moveItem(at: src, to: dst)
                    }
                } else {
                    try FileManager.default.copyItem(at: src, to: dst)
                }
            } catch {
                encounteredError = error
            }
        }

        if item.isCut { clipboard.clear() }
        await loadCurrentLevel()
        if let err = encounteredError { errorMessage = fileErrorMessage(err) }
    }

    private func handleDrop(_ providers: [NSItemProvider], destinationPath: String) {
        guard let bm = folder?.bookmarkData else { return }

        let isGroupDrop = providers.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        if isGroupDrop, let group = importModel.draggedGroup {
            let isCut = importModel.draggedGroupIsCut
            importModel.draggedGroup = nil
            importModel.draggedGroupIsCut = false
            Task {
                await performGroupDrop(group: group, isCut: isCut,
                                       destinationPath: destinationPath, bookmarkData: bm)
            }
            return
        }
        importModel.draggedGroup = nil
        importModel.draggedGroupIsCut = false

        for provider in providers {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let srcURL = object as? URL else { return }
                Task { @MainActor in
                    await performDropCopy(srcURL: srcURL, destinationPath: destinationPath, bookmarkData: bm)
                }
            }
        }
    }

    private func performGroupDrop(group: ImportDateGroup, isCut: Bool,
                                   destinationPath: String, bookmarkData: Data) async {
        guard let dstRootURL = try? BookmarkService.resolveBookmark(bookmarkData) else {
            errorMessage = String(localized: "Cannot access folder. Remove and re-add it in the sidebar.")
            return
        }
        let srcURL = importModel.sourceURL
        let srcScopeStarted = srcURL?.startAccessingSecurityScopedResource() ?? false
        let dstStarted = dstRootURL.startAccessingSecurityScopedResource()

        let folderURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(group.folderName)
        var processedURLs = Set<URL>()
        var encounteredError: Error?

        let taskLabel = "\(isCut ? "Moving" : "Copying") \(group.folderName)"
        let taskId = importModel.beginImportTask(label: taskLabel, total: group.items.count)

        for item in group.items {
            let dst = folderURL.appendingPathComponent(item.url.lastPathComponent)
            do {
                try await Task.detached {
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: folderURL.path) {
                        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    }
                    guard !fm.fileExists(atPath: dst.path) else { return }
                    if isCut {
                        try fm.moveItem(at: item.url, to: dst)
                    } else {
                        try fm.copyItem(at: item.url, to: dst)
                    }
                }.value
                processedURLs.insert(item.url)
            } catch {
                encounteredError = error
            }
            importModel.updateImportTask(taskId, done: processedURLs.count)
        }
        if srcScopeStarted { srcURL?.stopAccessingSecurityScopedResource() }
        if dstStarted { dstRootURL.stopAccessingSecurityScopedResource() }

        importModel.finishImportTask(taskId)

        if let error = encounteredError {
            errorMessage = fileErrorMessage(error)
        } else {
            if isCut { importModel.removeItems(processedURLs) }
            folderChangeToken += 1
        }
    }

    private func performDropCopy(srcURL: URL, destinationPath: String, bookmarkData: Data) async {
        let dst = URL(fileURLWithPath: destinationPath).appendingPathComponent(srcURL.lastPathComponent)
        guard let dstRootURL = try? BookmarkService.resolveBookmark(bookmarkData) else {
            errorMessage = String(localized: "Cannot access folder. Remove and re-add it in the sidebar.")
            return
        }
        let dstStarted = dstRootURL.startAccessingSecurityScopedResource()
        let srcStarted = srcURL.startAccessingSecurityScopedResource()
        let srcName = srcURL.lastPathComponent

        let copyResult: Result<Void, Error> = await Task.detached {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: dst.path) else {
                return .failure(CocoaError(.fileWriteFileExists))
            }
            do {
                try fm.copyItem(at: srcURL, to: dst)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        if dstStarted { dstRootURL.stopAccessingSecurityScopedResource() }
        if srcStarted { srcURL.stopAccessingSecurityScopedResource() }

        switch copyResult {
        case .success:
            folderChangeToken += 1
        case .failure(let error):
            if (error as? CocoaError)?.code == .fileWriteFileExists {
                errorMessage = String(localized: "\"\(srcName)\" already exists in this folder.")
            } else {
                errorMessage = fileErrorMessage(error)
            }
        }
    }

    private func performTrashSubfolder(info: SubfolderInfo) async {
        guard let bm = folder?.bookmarkData,
              let rootURL = try? BookmarkService.resolveBookmark(bm) else {
            errorMessage = String(localized: "Cannot access folder. Remove and re-add it in the sidebar.")
            return
        }
        let started = rootURL.startAccessingSecurityScopedResource()
        defer { if started { rootURL.stopAccessingSecurityScopedResource() } }
        let url = URL(fileURLWithPath: info.path)
        do {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try FileManager.default.removeItem(at: url)
            }
            selectedItemIds.remove(info.path)
            if lastSelectedId == info.path {
                lastSelectedId = selectedItemIds.first
                selectedPhoto = nil
            }
            await loadCurrentLevel()
        } catch {
            errorMessage = fileErrorMessage(error)
        }
    }

    private func performTrash(item: PhotoItem) {
        let url = URL(fileURLWithPath: item.filePath)
        let bm = item.resolveBookmarkData(from: Array(allFolders)) ?? folder?.bookmarkData
        var scopeURL: URL?
        var didStart = false
        if let bm {
            do {
                let resolved = try BookmarkService.resolveBookmark(bm)
                scopeURL = resolved
                didStart = resolved.startAccessingSecurityScopedResource()
            } catch {
                errorMessage = String(localized: "Cannot access folder. Remove and re-add it in the sidebar.")
                return
            }
        }
        defer { if didStart, let scopeURL { scopeURL.stopAccessingSecurityScopedResource() } }
        do {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try FileManager.default.removeItem(at: url)
            }
            // Remove from local state (no DB to update)
            allItems.removeAll { $0.filePath == item.filePath }
            displayPhotos.removeAll { $0.filePath == item.filePath }
            viewModel.flatPhotos = displayPhotos
            selectedItemIds.remove(item.filePath)
            if lastSelectedId == item.filePath { lastSelectedId = selectedItemIds.first }
            if selectedPhoto?.filePath == item.filePath { selectedPhoto = nil }
        } catch {
            errorMessage = fileErrorMessage(error)
        }
    }

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
            return String(localized: "Write permission denied. Remove and re-add this folder in the sidebar to enable write operations.")
        }
        return error.localizedDescription
    }
}

// MARK: - SubfolderTileView

private struct SubfolderTileView: View {
    let name: String
    let path: String
    let coverPath: String?
    let coverDate: Date?
    let bookmarkData: Data?
    var isSelected: Bool = false

    @State private var coverImage: NSImage?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
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
        .task(id: coverPath) {
            guard let coverPath else { return }
            if let cached = ThumbnailService.shared.cachedThumbnail(for: coverPath) {
                coverImage = cached
            } else {
                coverImage = await ThumbnailService.shared.thumbnail(for: coverPath, bookmarkData: bookmarkData)
            }
        }
    }
}

// MARK: - PhotoContextMenu

struct PhotoContextMenu: View {
    let item: PhotoItem
    var bookmarkData: Data? = nil
    var allFolders: [ScannedFolder] = []
    var onDelete: (() -> Void)? = nil
    private let clipboard = FolderClipboard.shared

    var body: some View {
        Button("Copy") {
            clipboard.copy(path: item.filePath, bookmarkData: bookmarkData ?? Data())
        }
        Button("Cut") {
            clipboard.cut(path: item.filePath, bookmarkData: bookmarkData ?? Data())
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(item.filePath, inFileViewerRootedAtPath: "")
        }
        Divider()
        Button("Share...") { shareFile() }
        Divider()
        Button("Move to Trash", role: .destructive) { onDelete?() }
    }

    private func shareFile() {
        let url = URL(fileURLWithPath: item.filePath)
        let bm = item.resolveBookmarkData(from: allFolders) ?? bookmarkData
        var scopeURL: URL?
        if let bm, let resolved = try? BookmarkService.resolveBookmark(bm) {
            scopeURL = resolved
            _ = resolved.startAccessingSecurityScopedResource()
        }
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            if let scopeURL { scopeURL.stopAccessingSecurityScopedResource() }
            return
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        if let scopeURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                scopeURL.stopAccessingSecurityScopedResource()
            }
        }
    }
}
