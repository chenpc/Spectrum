import SwiftUI
import SwiftData

enum SidebarItem: Hashable {
    case folder(ScannedFolder)
    case subfolder(ScannedFolder, String)  // (root folder for bookmark, subfolder path)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .folder(let f): hasher.combine("folder"); hasher.combine(f.persistentModelID)
        case .subfolder(let f, let path): hasher.combine("subfolder"); hasher.combine(f.persistentModelID); hasher.combine(path)
        }
    }

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
        switch (lhs, rhs) {
        case (.folder(let a), .folder(let b)): return a.persistentModelID == b.persistentModelID
        case (.subfolder(let a, let ap), .subfolder(let b, let bp)): return a.persistentModelID == b.persistentModelID && ap == bp
        default: return false
        }
    }
}

// FocusedValues for photo navigation from menu commands
struct PhotoNavigationAction {
    let navigateLeft: () -> Void
    let navigateRight: () -> Void
    let navigateUp: () -> Void
    let navigateDown: () -> Void
    let pageUp: () -> Void
    let pageDown: () -> Void
    let enter: () -> Void
}

struct PhotoNavigationKey: FocusedValueKey {
    typealias Value = PhotoNavigationAction
}

struct AddFolderActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Actions for keyboard-driven folder clipboard (Cmd+C / Cmd+X / Cmd+V).
/// Each closure is nil when the action is not currently applicable.
struct FolderEditAction {
    var copy: (() -> Void)?
    var cut: (() -> Void)?
    var paste: (() -> Void)?
}

struct FolderEditActionKey: FocusedValueKey {
    typealias Value = FolderEditAction
}

struct DeletePhotoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct SelectAllActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct MpvPlayPauseKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct GyroConfigBindingKey: FocusedValueKey {
    typealias Value = Binding<String?>
}

struct VideoControllerKey: FocusedValueKey {
    typealias Value = VideoController
}

extension FocusedValues {
    var gyroConfigBinding: Binding<String?>? {
        get { self[GyroConfigBindingKey.self] }
        set { self[GyroConfigBindingKey.self] = newValue }
    }
    var videoController: VideoController? {
        get { self[VideoControllerKey.self] }
        set { self[VideoControllerKey.self] = newValue }
    }
    var photoNavigation: PhotoNavigationAction? {
        get { self[PhotoNavigationKey.self] }
        set { self[PhotoNavigationKey.self] = newValue }
    }
    var addFolderAction: (() -> Void)? {
        get { self[AddFolderActionKey.self] }
        set { self[AddFolderActionKey.self] = newValue }
    }
    var folderEditAction: FolderEditAction? {
        get { self[FolderEditActionKey.self] }
        set { self[FolderEditActionKey.self] = newValue }
    }
    var deletePhotoAction: (() -> Void)? {
        get { self[DeletePhotoActionKey.self] }
        set { self[DeletePhotoActionKey.self] = newValue }
    }
    var selectAllAction: (() -> Void)? {
        get { self[SelectAllActionKey.self] }
        set { self[SelectAllActionKey.self] = newValue }
    }
    var videoPlayPause: (() -> Void)? {
        get { self[MpvPlayPauseKey.self] }
        set { self[MpvPlayPauseKey.self] = newValue }
    }
}

/// Untracked box for storing the opaque NSEvent monitor token outside of
/// `@Observable` synthesis and off the main actor.
private final class MonitorBox: @unchecked Sendable {
    var value: Any?
}

/// Bridges NSEvent Escape key presses into SwiftUI via an observable toggle.
@Observable
@MainActor
private final class EscapeKeyMonitor {
    var escaped = false
    // Stored as a nonisolated-safe wrapper to avoid @Observable macro conflicts
    // with @MainActor on mutable stored properties.
    private let monitorBox = MonitorBox()

    func start() {
        guard monitorBox.value == nil else { return }
        monitorBox.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                self?.escaped.toggle()
            }
            return nil
        }
    }

    deinit {
        if let monitor = monitorBox.value { NSEvent.removeMonitor(monitor) }
    }
}

struct ContentView: View {
    @State private var selectedSidebarItem: SidebarItem?
    @State private var selectedPhoto: PhotoItem?
    @State private var detailPhoto: PhotoItem?
    /// Retains the last non-nil detailPhoto so in-flight async Tasks in PhotoDetailView
    /// can still read the binding safely after the user exits detail view (detailPhoto → nil).
    /// Without this, the force-unwrap in photoDetail()'s Binding would crash on any
    /// late Task that reads photo.filePath after teardown begins.
    @State private var lastDetailPhoto: PhotoItem?
    @State private var showInspector = false
    @State private var showImportPanel = false
    private let importModel = ImportPanelModel.shared
    @State private var isPhotoHDR = false
    @State private var isFullScreen = false
    @State private var viewModel = LibraryViewModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var savedColumnVisibility = NavigationSplitViewVisibility.all
    @State private var thumbnailCacheState = ThumbnailCacheState.shared
    @State private var escapeMonitor = EscapeKeyMonitor()
    @State private var searchText = ""
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("lastFolderPath") private var lastFolderPath: String = ""
    @AppStorage("lastSubfolderPath") private var lastSubfolderPath: String = ""
    /// Path to pre-select when grid appears (after leaving detail or navigating to parent).
    @State private var returnToSelection: String?
    @Query(sort: \ScannedFolder.sortOrder) private var allFolders: [ScannedFolder]

    private var detailNavigation: PhotoNavigationAction {
        let current = detailPhoto
        return PhotoNavigationAction(
            navigateLeft: {
                if let nav = viewModel.navigatePhoto(from: current, direction: -1) {
                    detailPhoto = nav
                }
            },
            navigateRight: {
                if let nav = viewModel.navigatePhoto(from: current, direction: 1) {
                    detailPhoto = nav
                }
            },
            navigateUp: {},
            navigateDown: {},
            pageUp: {},
            pageDown: {},
            enter: {}
        )
    }

    var body: some View {
        normalContent
        .onAppear { escapeMonitor.start() }
        .onChange(of: escapeMonitor.escaped) { _, _ in handleEscape() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            guard !isFullScreen else { return }
            savedColumnVisibility = columnVisibility
            isFullScreen = true
            // Force sidebar collapse — columnVisibility alone is unreliable on macOS
            if columnVisibility != .detailOnly {
                columnVisibility = .detailOnly
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            showInspector = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            if let window = notification.object as? NSWindow {
                window.toolbar?.isVisible = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            guard isFullScreen else { return }
            isFullScreen = false
            columnVisibility = savedColumnVisibility
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            if let window = notification.object as? NSWindow {
                window.toolbar?.isVisible = true
            }
        }
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
        .environment(\.thumbnailCacheState, thumbnailCacheState)
        .onChange(of: detailPhoto?.filePath) { _, _ in
            // Keep lastDetailPhoto in sync whenever a new photo opens — ensures
            // the Binding fallback in photoDetail() always has a valid reference.
            if let new = detailPhoto { lastDetailPhoto = new }
        }
        .onChange(of: selectedSidebarItem) { _, newItem in
            detailPhoto = nil
            selectedPhoto = nil
            // Persist last browsed location
            switch newItem {
            case .folder(let f):
                lastFolderPath = f.path
                lastSubfolderPath = ""
            case .subfolder(let f, let sub):
                lastFolderPath = f.path
                lastSubfolderPath = sub
            case nil:
                break
            }
        }
        .onChange(of: importModel.sourceURL) { _, newURL in
            if newURL != nil { showImportPanel = true }
        }
        .task {
            // Start FSEvents monitoring for all folders
            for folder in allFolders {
                FolderMonitor.shared.startMonitoring(path: folder.path)
            }

            // Restore last browsed location
            if selectedSidebarItem == nil, !lastFolderPath.isEmpty,
               let folder = allFolders.first(where: { $0.path == lastFolderPath }) {
                if lastSubfolderPath.isEmpty {
                    selectedSidebarItem = .folder(folder)
                } else {
                    selectedSidebarItem = .subfolder(folder, lastSubfolderPath)
                }
            }
        }
        .onChange(of: allFolders.map(\.path)) { old, new in
            let added = Set(new).subtracting(old)
            let removed = Set(old).subtracting(new)
            for path in added { FolderMonitor.shared.startMonitoring(path: path) }
            for path in removed { FolderMonitor.shared.stopMonitoring(path: path) }
        }
    }

    @ViewBuilder
    private var normalContent: some View {
        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(selection: $selectedSidebarItem)
            } detail: {
                Group {
                    if !searchText.isEmpty {
                        SearchResultsView(
                            query: searchText,
                            folders: allFolders,
                            onSelectPhoto: { item, folder in
                                searchText = ""
                                selectedSidebarItem = .subfolder(folder, URL(fileURLWithPath: item.filePath).deletingLastPathComponent().path)
                                returnToSelection = item.filePath
                                detailPhoto = item
                            },
                            onSelectFolder: { folder, path in
                                searchText = ""
                                if path == folder.path {
                                    selectedSidebarItem = .folder(folder)
                                } else {
                                    selectedSidebarItem = .subfolder(folder, path)
                                }
                            }
                        )
                        .navigationTitle("Search: \(searchText)")
                    } else if detailPhoto != nil {
                        photoDetail(showInspector: $showInspector)
                            .toolbar {
                                ToolbarItem(placement: .navigation) {
                                    Button {
                                        returnToSelection = detailPhoto?.filePath
                                        detailPhoto = nil
                                    } label: {
                                        Label("Back", systemImage: "chevron.left")
                                    }
                                }
                                ToolbarItem {
                                    importToolbarButton
                                }
                                ToolbarItem {
                                    Button {
                                        enterFullScreen()
                                    } label: {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right.square")
                                    }
                                    .help("Full Screen")
                                    .keyboardShortcut("f", modifiers: .command)
                                    .accessibilityIdentifier(AccessibilityID.fullScreenButton)
                                }
                            }
                    } else if case .subfolder(let folder, let subPath) = selectedSidebarItem {
                        gridContent
                            .toolbar {
                                ToolbarItem(placement: .navigation) {
                                    Button {
                                        navigateToParent(folder: folder, subPath: subPath)
                                    } label: {
                                        Label("Back", systemImage: "chevron.left")
                                    }
                                }
                                ToolbarItem {
                                    importToolbarButton
                                }
                            }
                    } else {
                        gridContent
                            .toolbar {
                                ToolbarItem {
                                    importToolbarButton
                                }
                            }
                    }
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search photos & folders")
            .inspector(isPresented: $showInspector) {
                if let photo = detailPhoto ?? selectedPhoto {
                    PhotoInfoPanel(item: photo, isHDR: isPhotoHDR)
                        .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
                }
            }

            if showImportPanel {
                Divider()
                ImportPanelView(model: importModel) {
                    showImportPanel = false
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TaskProgressBar()
        }
    }

    private var importToolbarButton: some View {
        Button {
            showImportPanel.toggle()
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .help("Import")
        .accessibilityIdentifier(AccessibilityID.importButton)
    }

    private func handleEscape() {
        if isFullScreen {
            exitFullScreen()
        } else if detailPhoto != nil {
            returnToSelection = detailPhoto?.filePath
            detailPhoto = nil
        } else if case .subfolder(let folder, let subPath) = selectedSidebarItem {
            navigateToParent(folder: folder, subPath: subPath)
        }
    }

    private func enterFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func exitFullScreen() {
        guard let window = NSApp.keyWindow,
              window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private func navigateToParent(folder: ScannedFolder, subPath: String) {
        returnToSelection = subPath
        let parentPath = URL(fileURLWithPath: subPath).deletingLastPathComponent().path
        if parentPath == folder.path || parentPath.count < folder.path.count {
            selectedSidebarItem = .folder(folder)
        } else {
            selectedSidebarItem = .subfolder(folder, parentPath)
        }
    }

    private func breadcrumb(root: String, current: String) -> String {
        let rootName = URL(fileURLWithPath: root).lastPathComponent
        let suffix = current.dropFirst(root.count)
        let components = suffix.split(separator: "/").map(String.init)
        return ([rootName] + components).joined(separator: " › ")
    }

    private func photoDetail(showInspector: Binding<Bool>) -> some View {
        PhotoDetailView(
            photo: Binding(
                // Fallback to lastDetailPhoto when detailPhoto briefly becomes nil
                // (user exited detail view while an async Task is still in flight).
                get: { detailPhoto ?? lastDetailPhoto! },
                set: {
                    detailPhoto = $0
                    lastDetailPhoto = $0
                }
            ),
            showInspector: showInspector,
            isHDR: $isPhotoHDR,
            viewModel: viewModel
        )
        .focusedSceneValue(\.photoNavigation, detailNavigation)
    }

    @ViewBuilder
    private var gridContent: some View {
        switch selectedSidebarItem {
        case .folder(let folder):
            PhotoGridView(
                viewModel: viewModel,
                selectedPhoto: $selectedPhoto,
                initialSelection: $returnToSelection,
                onDoubleClick: { detailPhoto = $0 },
                onNavigateToSubfolder: { path in
                    selectedSidebarItem = .subfolder(folder, path)
                },
                folder: folder
            )
            .id(folder.path)   // 路徑改變時重建 view，讓 @Query predicate 更新
            .navigationTitle(URL(fileURLWithPath: folder.path).lastPathComponent)
        case .subfolder(let folder, let subPath):
            PhotoGridView(
                viewModel: viewModel,
                selectedPhoto: $selectedPhoto,
                initialSelection: $returnToSelection,
                onDoubleClick: { detailPhoto = $0 },
                onNavigateToSubfolder: { path in
                    selectedSidebarItem = .subfolder(folder, path)
                },
                folder: folder,
                folderPath: subPath
            )
            .id(subPath)   // 路徑改變時重建 view，讓 @Query predicate 更新
            .navigationTitle(breadcrumb(root: folder.path, current: subPath))
        case nil:
            ContentUnavailableView(
                "Select a Folder",
                systemImage: "folder",
                description: Text("Choose a folder from the sidebar to browse photos.")
            )
            .accessibilityIdentifier(AccessibilityID.gridEmptyState)
        }
    }
}

/// 全視窗底部進度條：僅顯示 Remove / Reset 等 StatusBarModel 任務。
/// 縮圖掃描進度已移至 sidebar 底部。
private struct TaskProgressBar: View {
    @State private var statusModel = StatusBarModel.shared

    var body: some View {
        if statusModel.isVisible {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    if let task = statusModel.activeTasks.first {
                        if task.isDeterminate {
                            ProgressView(value: Double(task.done), total: Double(max(1, task.total)))
                                .progressViewStyle(.linear).frame(maxWidth: .infinity)
                        } else {
                            ProgressView().controlSize(.small).frame(width: 20)
                        }
                        Text(task.label).font(.caption2).foregroundStyle(.secondary)
                    } else if let msg = statusModel.doneMessage {
                        Text(msg).font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .background(.bar)
        }
    }
}
