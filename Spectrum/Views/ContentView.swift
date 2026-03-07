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
    @State private var selectedPhoto: Photo?
    @State private var detailPhoto: Photo?
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
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("lastFolderPath") private var lastFolderPath: String = ""
    @AppStorage("lastSubfolderPath") private var lastSubfolderPath: String = ""
    @Query(sort: \ScannedFolder.sortOrder) private var allFolders: [ScannedFolder]
    @Environment(\.modelContext) private var modelContext

    private var detailNavigation: PhotoNavigationAction {
        PhotoNavigationAction(
            navigateLeft: {
                if let nav = viewModel.navigatePhoto(from: detailPhoto, direction: -1) {
                    detailPhoto = nav
                }
            },
            navigateRight: {
                if let nav = viewModel.navigatePhoto(from: detailPhoto, direction: 1) {
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
            // On app launch: delta scan — keep cached data for instant display,
            // add new files and remove deleted files in the background.
            let scanner = FolderScanner(modelContainer: modelContext.container)
            for folder in allFolders {
                // Skip folders whose bookmark cannot be resolved or directory no longer exists
                guard let bookmarkData = folder.bookmarkData,
                      let url = try? BookmarkService.resolveBookmark(bookmarkData) else { continue }
                let accessible = BookmarkService.withSecurityScope(url) {
                    FileManager.default.fileExists(atPath: url.path)
                }
                guard accessible else { continue }
                try? await scanner.scanFolder(id: folder.persistentModelID, clearAll: false)
            }

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
                    if let photo = detailPhoto {
                        photoDetail(photo, showInspector: $showInspector)
                            .toolbar {
                                ToolbarItem(placement: .navigation) {
                                    Button {
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
            .inspector(isPresented: $showInspector) {
                if let photo = detailPhoto ?? selectedPhoto {
                    PhotoInfoPanel(photo: photo, isHDR: isPhotoHDR)
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
    }

    private var importToolbarButton: some View {
        Button {
            showImportPanel.toggle()
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .help("Import")
    }

    private func handleEscape() {
        if isFullScreen {
            exitFullScreen()
        } else if detailPhoto != nil {
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

    private func photoDetail(_ photo: Photo, showInspector: Binding<Bool>) -> some View {
        PhotoDetailView(photo: photo, showInspector: showInspector, isHDR: $isPhotoHDR, viewModel: viewModel)
            .focusedSceneValue(\.photoNavigation, detailNavigation)
    }

    @ViewBuilder
    private var gridContent: some View {
        switch selectedSidebarItem {
        case .folder(let folder):
            PhotoGridView(
                viewModel: viewModel,
                selectedPhoto: $selectedPhoto,
                onDoubleClick: { detailPhoto = $0 },
                onNavigateToSubfolder: { path in
                    selectedSidebarItem = .subfolder(folder, path)
                },
                folder: folder
            )
            .navigationTitle(URL(fileURLWithPath: folder.path).lastPathComponent)
        case .subfolder(let folder, let subPath):
            PhotoGridView(
                viewModel: viewModel,
                selectedPhoto: $selectedPhoto,
                onDoubleClick: { detailPhoto = $0 },
                onNavigateToSubfolder: { path in
                    selectedSidebarItem = .subfolder(folder, path)
                },
                folder: folder,
                folderPath: subPath
            )
            .navigationTitle(breadcrumb(root: folder.path, current: subPath))
        case nil:
            ContentUnavailableView(
                "Select a Folder",
                systemImage: "folder",
                description: Text("Choose a folder from the sidebar to browse photos.")
            )
        }
    }
}
