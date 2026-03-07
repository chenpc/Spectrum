import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Marquee Selection

private struct ItemFramePreference: Equatable {
    let id: String
    let frame: CGRect
}

private struct ItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [ItemFramePreference] = []
    static func reduce(value: inout [ItemFramePreference], nextValue: () -> [ItemFramePreference]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func reportFrame(id: String) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ItemFramePreferenceKey.self,
                    value: [ItemFramePreference(id: id, frame: geo.frame(in: .global))]
                )
            }
        )
    }
}

/// NSView overlay for marquee selection.
/// Intercepts ALL left mouseDown. Tracks mouse movement:
///  - If drag distance >= threshold → marquee mode (select items, draw rectangle)
///  - If no drag (simple click) → forwards mouseDown+mouseUp to SwiftUI via sendEvent
/// Right-clicks pass through entirely (hitTest returns nil).
private final class MarqueeNSView: NSView {
    /// (startLocal, currentLocal, startGlobal, currentGlobal)
    var onDragChanged: ((CGPoint, CGPoint, CGPoint, CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private let minDragDistance: CGFloat = 4
    private var forwarding = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While forwarding events, become invisible so SwiftUI receives them
        guard !forwarding, bounds.contains(point) else { return nil }
        // Only intercept left mouse button; right-click passes through
        guard let event = window?.currentEvent, event.type == .leftMouseDown else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let startLoc = convert(event.locationInWindow, from: nil)
        var isDragging = false
        var mouseUpEvent: NSEvent?

        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { trackEvent, stop in
            guard let trackEvent else { stop.pointee = true; return }

            switch trackEvent.type {
            case .leftMouseDragged:
                let current = self.convert(trackEvent.locationInWindow, from: nil)
                let dx = current.x - startLoc.x
                let dy = current.y - startLoc.y
                if !isDragging {
                    guard sqrt(dx * dx + dy * dy) >= self.minDragDistance else { return }
                    isDragging = true
                }
                let startGlobal = self.localToGlobal(startLoc)
                let currentGlobal = self.localToGlobal(current)
                self.onDragChanged?(
                    CGPoint(x: startLoc.x, y: startLoc.y),
                    CGPoint(x: current.x, y: current.y),
                    startGlobal, currentGlobal
                )

            case .leftMouseUp:
                if isDragging {
                    self.onDragEnded?()
                } else {
                    mouseUpEvent = trackEvent
                }
                stop.pointee = true

            default:
                break
            }
        }

        // No drag → forward the complete click to SwiftUI
        if !isDragging {
            forwarding = true
            window?.sendEvent(event)
            if let up = mouseUpEvent {
                window?.sendEvent(up)
            }
            forwarding = false
        }
    }

    /// Convert local (flipped) point to SwiftUI `.global` coordinate space.
    private func localToGlobal(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        let inWindow = convert(point, to: nil)
        let contentHeight = window.contentView?.bounds.height ?? 0
        return CGPoint(x: inWindow.x, y: contentHeight - inWindow.y)
    }
}

private struct MarqueeOverlay: NSViewRepresentable {
    var onDragChanged: (CGPoint, CGPoint, CGPoint, CGPoint) -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> MarqueeNSView {
        let view = MarqueeNSView()
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: MarqueeNSView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }
}

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
    @State private var selectedItemIds: Set<String> = []
    @State private var lastSelectedId: String?
    @State private var photoToDelete: Photo? = nil
    @State private var photosToDelete: [Photo] = []
    @State private var foldersToDelete: [SubfolderInfo] = []
    @State private var displayPhotos: [Photo] = []
    @Query(sort: \ScannedFolder.sortOrder) private var allFolders: [ScannedFolder]

    // Folder clipboard and edit state
    private let clipboard = FolderClipboard.shared
    private let importModel = ImportPanelModel.shared
    private let statusBar = StatusBarModel.shared
    @State private var renamingInfo: SubfolderInfo? = nil
    @State private var renameText = ""
    @State private var errorMessage: String? = nil
    @State private var folderChangeToken = 0
    @State private var subfolderToDelete: SubfolderInfo? = nil

    // Marquee selection (local = overlay coords for drawing, global = for hit testing)
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeEnd: CGPoint? = nil
    @State private var marqueeStartGlobal: CGPoint? = nil
    @State private var marqueeEndGlobal: CGPoint? = nil
    @State private var itemFrames: [ItemFramePreference] = []

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
        guard let id = lastSelectedId else { return nil }
        return subfolders.first(where: { $0.path == id })
    }

    private var currentFolderEditAction: FolderEditAction {
        // When the rename alert is visible, return empty action so our Cmd+C/X/V
        // are disabled and the text-field responder chain handles them instead.
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

    /// Photos directly in the current folder (one level only), computed from @Query.
    private func computeDirectPhotos() -> [Photo] {
        guard let path = effectivePath else { return [] }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return allPhotos.filter { photo in
            guard !photo.isLivePhotoMov else { return false }
            guard photo.filePath.hasPrefix(prefix) else { return false }
            let relative = String(photo.filePath.dropFirst(prefix.count))
            return !relative.contains("/")
        }
    }

    private func refreshDisplayPhotos() {
        let photos = computeDirectPhotos()
        displayPhotos = photos
        viewModel.flatPhotos = photos
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 2)
    ]

    var body: some View {
        VStack(spacing: 0) {
            gridWithModifiers
            if statusBar.isVisible {
                statusBarView
            }
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
            .confirmationDialog("Move to Trash?", isPresented: Binding(
                get: { photoToDelete != nil },
                set: { if !$0 { photoToDelete = nil } }
            ), presenting: photoToDelete) { photo in
                Button("Move to Trash", role: .destructive) { performTrash(photo: photo) }
                Button("Cancel", role: .cancel) { photoToDelete = nil }
            } message: { photo in
                Text("\"\(photo.fileName)\" will be moved to the Trash.")
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
                get: { !photosToDelete.isEmpty || !foldersToDelete.isEmpty },
                set: { if !$0 { photosToDelete = []; foldersToDelete = [] } }
            )) {
                Button("Move \(photosToDelete.count + foldersToDelete.count) Items to Trash", role: .destructive) {
                    let p = photosToDelete; let f = foldersToDelete
                    photosToDelete = []; foldersToDelete = []
                    for photo in p { performTrash(photo: photo) }
                    for folder in f { Task { await performTrashSubfolder(info: folder) } }
                }
                Button("Cancel", role: .cancel) { photosToDelete = []; foldersToDelete = [] }
            } message: {
                Text("\(photosToDelete.count + foldersToDelete.count) items will be moved to the Trash.")
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
                await scanCurrentLevel()
            }
            .onAppear { refreshDisplayPhotos() }
            .onReceive(NotificationCenter.default.publisher(for: FolderMonitor.folderDidChange)) { note in
                guard let changedPath = note.userInfo?["path"] as? String,
                      let ePath = effectivePath,
                      ePath.hasPrefix(changedPath) || changedPath.hasPrefix(ePath)
                else { return }
                folderChangeToken += 1
            }
            .onChange(of: effectivePath) { _, newPath in
                selectedItemIds = []
                lastSelectedId = nil
                pendingPaths = []
                isMounting = false
                isScanning = true
                refreshDisplayPhotos()
                let path = newPath ?? folder?.path ?? ""
                if let cached = FolderListCache.shared.entries(for: path) {
                    scannedSubfolders = cached
                        .map { SubfolderInfo(name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate) }
                        .sorted { subfoldersAreInOrder($0, $1) }
                } else {
                    scannedSubfolders = nil
                }
            }
            .onChange(of: allPhotos.count) { _, _ in
                guard !pendingPaths.isEmpty else { return }
                let currentPhotos = computeDirectPhotos()
                let scannedPaths = Set(currentPhotos.map(\.filePath))
                let remaining = pendingPaths.filter { !scannedPaths.contains($0) }
                if remaining.count != pendingPaths.count {
                    pendingPaths = remaining
                }
            }
    }

    private var statusBarView: some View {
        HStack(spacing: 8) {
            if statusBar.isActive {
                if statusBar.isDeterminate {
                    ProgressView(
                        value: Double(statusBar.progressDone),
                        total: Double(max(1, statusBar.progressTotal))
                    )
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
                    Text(statusBar.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(statusBar.progressDone)/\(statusBar.progressTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text(statusBar.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let done = statusBar.doneMessage {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(done)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
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
                        await performGroupDrop(group: group, isCut: isCut, destinationPath: destPath, bookmarkData: bm)
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
        } else if isScanning && displayPhotos.isEmpty && subfolders.isEmpty && pendingPaths.isEmpty {
            ProgressView("Scanning…")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let end = marqueeEnd else { return nil }
        return CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    private var gridBody: some View {
        let flatItems = buildFlatItems()

        return GeometryReader { geo in
            let columnCount = max(1, Int((geo.size.width + 2) / 152))

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        subfolderSection
                        pendingSection
                        emptyPlaceholder
                        photoGridSection
                    }
                    .onPreferenceChange(ItemFramePreferenceKey.self) { prefs in
                        itemFrames = prefs
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
                .overlay {
                    ZStack {
                        // Invisible NSView to capture mouse drag for marquee
                        MarqueeOverlay(
                            onDragChanged: { startLocal, currentLocal, startGlobal, currentGlobal in
                                marqueeStart = startLocal
                                marqueeEnd = currentLocal
                                marqueeStartGlobal = startGlobal
                                marqueeEndGlobal = currentGlobal
                                updateMarqueeSelection()
                            },
                            onDragEnded: {
                                marqueeStart = nil
                                marqueeEnd = nil
                                marqueeStartGlobal = nil
                                marqueeEndGlobal = nil
                            }
                        )

                        // Marquee rectangle visual
                        if let rect = marqueeRect {
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 1)
                                .background(Color.accentColor.opacity(0.1))
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .onChange(of: lastSelectedId) { _, newId in
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
                navigateUp: { navigate(by: -columnCount, in: flatItems, clamp: false) },
                navigateDown: { navigate(by: columnCount, in: flatItems, clamp: false) },
                enter: { activateSelection() }
            ))
            .focusedSceneValue(\.folderEditAction, currentFolderEditAction)
            .focusedSceneValue(\.deletePhotoAction, !selectedItemIds.isEmpty ? { triggerDeleteSelected() } : nil)
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
                            coverPath: info.coverPath,
                            coverDate: info.coverDate,
                            bookmarkData: folder?.bookmarkData,
                            isSelected: selectedItemIds.contains(info.path)
                        )
                        .id(info.path)
                        .reportFrame(id: info.path)
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
    private var pendingSection: some View {
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
                TimelineSectionHeader(localizedLabel: "Indexing", count: pendingPaths.count)
            }
        }
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        if displayPhotos.isEmpty && subfolders.isEmpty && pendingPaths.isEmpty && !isScanning {
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
            ForEach(displayPhotos) { photo in
                PhotoThumbnailView(
                    photo: photo,
                    isSelected: selectedItemIds.contains(photo.filePath),
                    folderBookmarkData: folder?.bookmarkData
                )
                .id(photo.filePath)
                .reportFrame(id: photo.filePath)
                .onTapGesture {
                    handleTap(id: photo.filePath, isFolder: false, event: NSApp.currentEvent)
                }
                .contextMenu {
                    if selectedItemIds.contains(photo.filePath) && selectedItemIds.count > 1 {
                        Button("Move \(selectedItemIds.count) Items to Trash", role: .destructive) {
                            triggerDeleteSelected()
                        }
                    } else {
                        PhotoContextMenu(
                            photo: photo,
                            bookmarkData: folder?.bookmarkData,
                            allFolders: allFolders,
                            onDelete: { photoToDelete = photo }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func buildFlatItems() -> [String] {
        var items: [String] = subfolders.map(\.path)
        items.append(contentsOf: displayPhotos.map(\.filePath))
        return items
    }

    private func navigate(by offset: Int, in flatItems: [String], clamp: Bool = true) {
        guard !flatItems.isEmpty else { return }
        guard let current = lastSelectedId,
              let index = flatItems.firstIndex(of: current) else {
            let first = flatItems.first!
            selectSingle(first)
            return
        }
        let newIndex = index + offset
        guard newIndex >= 0 && newIndex < flatItems.count else {
            if clamp {
                let clamped = flatItems[min(max(0, newIndex), flatItems.count - 1)]
                selectSingle(clamped)
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

    private func syncSelection() {
        if let id = lastSelectedId,
           let photo = displayPhotos.first(where: { $0.filePath == id }) {
            selectedPhoto = photo
        } else {
            selectedPhoto = nil
        }
    }

    private func activateSelection() {
        guard let id = lastSelectedId else { return }
        if let sf = subfolders.first(where: { $0.path == id }) {
            onNavigateToSubfolder?(sf.path)
        } else if let photo = displayPhotos.first(where: { $0.filePath == id }) {
            onDoubleClick?(photo)
        }
    }

    /// Handle single-tap with modifier keys. If item already selected, activate it.
    private func handleTap(id: String, isFolder: Bool, event: NSEvent?) {
        let cmd = event?.modifierFlags.contains(.command) ?? false
        let shift = event?.modifierFlags.contains(.shift) ?? false

        if !cmd && !shift {
            // Plain click: if already the sole selection, activate (enter folder / open photo)
            if selectedItemIds == [id] {
                activateItem(id: id)
                return
            }
            selectSingle(id)
        } else if cmd {
            // Cmd+click: toggle item in selection
            if selectedItemIds.contains(id) {
                selectedItemIds.remove(id)
                if lastSelectedId == id {
                    lastSelectedId = selectedItemIds.first
                }
            } else {
                selectedItemIds.insert(id)
                lastSelectedId = id
            }
            syncSelection()
        } else if shift {
            // Shift+click: range select from lastSelectedId to this item
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

    private func updateMarqueeSelection() {
        guard let start = marqueeStartGlobal, let end = marqueeEndGlobal else { return }
        let globalRect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        var ids = Set<String>()
        for pref in itemFrames where globalRect.intersects(pref.frame) {
            ids.insert(pref.id)
        }
        selectedItemIds = ids
        lastSelectedId = ids.first
        syncSelection()
    }

    private func activateItem(id: String) {
        if let sf = subfolders.first(where: { $0.path == id }) {
            onNavigateToSubfolder?(sf.path)
        } else if let photo = displayPhotos.first(where: { $0.filePath == id }) {
            onDoubleClick?(photo)
        }
    }

    private func triggerDeleteSelected() {
        let selPhotos = displayPhotos.filter { selectedItemIds.contains($0.filePath) }
        let selFolders = subfolders.filter { selectedItemIds.contains($0.path) }
        let totalCount = selPhotos.count + selFolders.count

        if totalCount == 0 { return }

        if totalCount == 1 && selFolders.count == 1 {
            subfolderToDelete = selFolders.first
        } else if totalCount == 1 && selPhotos.count == 1 {
            photoToDelete = selPhotos.first
        } else {
            // Bulk delete: set both lists, one dialog handles it
            photosToDelete = selPhotos
            foldersToDelete = selFolders
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
        let folderName = URL(fileURLWithPath: cachedPath).lastPathComponent

        // Step 0: Show cached subfolder list immediately (no filesystem I/O).
        if scannedSubfolders == nil,
           let cached = FolderListCache.shared.entries(for: cachedPath) {
            scannedSubfolders = cached
                .map { SubfolderInfo(name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate) }
                .sorted { subfoldersAreInOrder($0, $1) }
        }

        isScanning = true
        statusBar.begin("Scanning \(folderName)…")

        // Step 1: Fresh filesystem listing — detects additions/removals.
        let dirs = await scanner.listSubfolders(id: folder.persistentModelID, path: effectivePath)
        let freshSubfolders = dirs
            .map { SubfolderInfo(name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate) }
            .sorted { subfoldersAreInOrder($0, $1) }
        scannedSubfolders = freshSubfolders

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
                let existingPaths = Set(computeDirectPhotos().map(\.filePath))
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
        refreshDisplayPhotos()
        statusBar.finish("Scanned \(folderName)")
    }

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
            await scanCurrentLevel()
            // Select and trigger rename
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
            await scanCurrentLevel()
        } catch {
            errorMessage = fileErrorMessage(error)
        }
    }

    private func performPasteAny() async {
        // Import group paste takes priority
        if let group = importModel.draggedGroup,
           let destPath = effectivePath,
           let bm = folder?.bookmarkData {
            let isCut = importModel.draggedGroupIsCut
            importModel.draggedGroup = nil
            importModel.draggedGroupIsCut = false
            await performGroupDrop(group: group, isCut: isCut, destinationPath: destPath, bookmarkData: bm)
            return
        }
        // Fall back to folder/photo clipboard
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
        let label = item.isCut ? "Moving" : "Copying"
        statusBar.begin("\(label) \(src.lastPathComponent)…")

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
            errorMessage = String(localized: "\"\(src.lastPathComponent)\" already exists in this folder.")
            statusBar.finish()
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
            statusBar.finish("\(label.replacingOccurrences(of: "ing", with: "ed")) \(src.lastPathComponent)")
            await scanCurrentLevel()
        } catch {
            statusBar.finish()
            errorMessage = fileErrorMessage(error)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], destinationPath: String) {
        guard let bm = folder?.bookmarkData else { return }

        // Group drop: provider carries a plain-text marker from onDrag
        let isGroupDrop = providers.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        if isGroupDrop, let group = importModel.draggedGroup {
            let isCut = importModel.draggedGroupIsCut
            importModel.draggedGroup = nil
            importModel.draggedGroupIsCut = false
            Task {
                await performGroupDrop(group: group, isCut: isCut, destinationPath: destinationPath, bookmarkData: bm)
            }
            return
        }
        importModel.draggedGroup = nil
        importModel.draggedGroupIsCut = false

        // Single file drops (always copy)
        for provider in providers {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let srcURL = object as? URL else { return }
                Task { @MainActor in
                    await performDropCopy(srcURL: srcURL, destinationPath: destinationPath, bookmarkData: bm)
                }
            }
        }
    }

    private func performGroupDrop(group: ImportDateGroup, isCut: Bool, destinationPath: String, bookmarkData: Data) async {
        guard let dstRootURL = try? BookmarkService.resolveBookmark(bookmarkData) else {
            errorMessage = String(localized: "Cannot access folder. Remove and re-add it in the sidebar.")
            return
        }
        let dstStarted = dstRootURL.startAccessingSecurityScopedResource()

        let folderURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(group.folderName)
        let items = group.items
        let label = isCut ? "Moving" : "Copying"
        let doneVerb = isCut ? "Moved" : "Copied"

        statusBar.begin("\(label) \(group.folderName)…", total: items.count)

        var processedURLs = Set<URL>()
        var encounteredError: Error?

        for (i, item) in items.enumerated() {
            let dst = folderURL.appendingPathComponent(item.url.lastPathComponent)
            let result: Result<Void, Error>
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
                result = .success(())
            } catch {
                result = .failure(error)
            }

            switch result {
            case .success:
                processedURLs.insert(item.url)
            case .failure(let error):
                encounteredError = error
            }
            statusBar.update(done: i + 1)
        }
        if dstStarted { dstRootURL.stopAccessingSecurityScopedResource() }

        if let error = encounteredError {
            statusBar.finish()
            errorMessage = fileErrorMessage(error)
        } else {
            statusBar.finish("\(doneVerb) \(items.count) files")
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
        statusBar.begin("Copying \(srcName)…")

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
            statusBar.finish("Copied \(srcName)")
            folderChangeToken += 1
        case .failure(let error):
            statusBar.finish()
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
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            // Remove related Photo records
            let prefix = info.path.hasSuffix("/") ? info.path : info.path + "/"
            for photo in allPhotos where photo.filePath.hasPrefix(prefix) {
                modelContext.delete(photo)
            }
            try? modelContext.save()
            selectedItemIds.remove(info.path)
            if lastSelectedId == info.path {
                lastSelectedId = selectedItemIds.first
                selectedPhoto = nil
            }
            await scanCurrentLevel()
        } catch {
            errorMessage = fileErrorMessage(error)
        }
    }

    private func performTrash(photo: Photo) {
        let url = URL(fileURLWithPath: photo.filePath)
        let bm = photo.resolveBookmarkData(from: allFolders) ?? folder?.bookmarkData
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
        defer {
            if didStart, let scopeURL { scopeURL.stopAccessingSecurityScopedResource() }
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            modelContext.delete(photo)
            try? modelContext.save()
            selectedItemIds.remove(photo.filePath)
            if lastSelectedId == photo.filePath {
                lastSelectedId = selectedItemIds.first
            }
            if selectedPhoto?.filePath == photo.filePath {
                selectedPhoto = nil
            }
            refreshDisplayPhotos()
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
            return String(localized: "Write permission denied. Remove and re-add this folder in the sidebar to enable write operations.")
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
    var bookmarkData: Data? = nil
    var allFolders: [ScannedFolder] = []
    var onDelete: (() -> Void)? = nil
    private let clipboard = FolderClipboard.shared

    var body: some View {
        Button("Copy") {
            clipboard.copy(path: photo.filePath, bookmarkData: bookmarkData ?? Data())
        }
        Button("Cut") {
            clipboard.cut(path: photo.filePath, bookmarkData: bookmarkData ?? Data())
        }

        Divider()

        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(photo.filePath, inFileViewerRootedAtPath: "")
        }

        Divider()

        Button("Share...") {
            shareFile()
        }

        Divider()

        Button("Move to Trash", role: .destructive) {
            onDelete?()
        }
    }

    private func shareFile() {
        let url = URL(fileURLWithPath: photo.filePath)
        let bm = photo.resolveBookmarkData(from: allFolders) ?? bookmarkData
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
        // Delay scope cleanup to allow sharing services to access the file
        if let scopeURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                scopeURL.stopAccessingSecurityScopedResource()
            }
        }
    }
}
