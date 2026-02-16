import SwiftUI
import SwiftData

enum SidebarItem: Hashable {
    case folder(ScannedFolder)
    case subfolder(ScannedFolder, String)  // (root folder for bookmark, subfolder path)
    case tag(Tag)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .folder(let f): hasher.combine("folder"); hasher.combine(f.persistentModelID)
        case .subfolder(let f, let path): hasher.combine("subfolder"); hasher.combine(f.persistentModelID); hasher.combine(path)
        case .tag(let t): hasher.combine("tag"); hasher.combine(t.persistentModelID)
        }
    }

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
        switch (lhs, rhs) {
        case (.folder(let a), .folder(let b)): return a.persistentModelID == b.persistentModelID
        case (.subfolder(let a, let ap), .subfolder(let b, let bp)): return a.persistentModelID == b.persistentModelID && ap == bp
        case (.tag(let a), .tag(let b)): return a.persistentModelID == b.persistentModelID
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
    let enter: () -> Void
}

struct PhotoNavigationKey: FocusedValueKey {
    typealias Value = PhotoNavigationAction
}

struct AddFolderActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var photoNavigation: PhotoNavigationAction? {
        get { self[PhotoNavigationKey.self] }
        set { self[PhotoNavigationKey.self] = newValue }
    }
    var addFolderAction: (() -> Void)? {
        get { self[AddFolderActionKey.self] }
        set { self[AddFolderActionKey.self] = newValue }
    }
}

struct ContentView: View {
    @State private var selectedSidebarItem: SidebarItem?
    @State private var selectedPhoto: Photo?
    @State private var detailPhoto: Photo?
    @State private var showInspector = false
    @State private var isPhotoHDR = false
    @State private var isFullScreen = false
    @State private var viewModel = LibraryViewModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var savedColumnVisibility = NavigationSplitViewVisibility.all
    @State private var thumbnailCacheState = ThumbnailCacheState.shared
    @State private var preloadCache = ImagePreloadCache()
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
            enter: {}
        )
    }

    var body: some View {
        Group {
            if isFullScreen, let photo = detailPhoto {
                // Fullscreen: just the photo, no NavigationSplitView
                photoDetail(photo, showInspector: .constant(false))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                normalContent
            }
        }
        .onExitCommand {
            handleEscape()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { notification in
            guard isFullScreen else { return }
            // User exited fullscreen via green button or gesture — restore state
            if let window = notification.object as? NSWindow {
                window.toolbar?.isVisible = true
            }
            isFullScreen = false
            columnVisibility = savedColumnVisibility
        }
        .environment(\.thumbnailCacheState, thumbnailCacheState)
        .onChange(of: selectedSidebarItem) { _, _ in
            detailPhoto = nil
            selectedPhoto = nil
        }
        .task {
            // On app launch: clear all photos and rescan root level of each folder
            let scanner = FolderScanner(modelContainer: modelContext.container)
            for folder in allFolders {
                try? await scanner.scanFolder(id: folder.persistentModelID, clearAll: true)
            }
        }
    }

    @ViewBuilder
    private var normalContent: some View {
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
                        }
                } else {
                    gridContent
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            if let photo = detailPhoto ?? selectedPhoto {
                PhotoInfoPanel(photo: photo, isHDR: isPhotoHDR)
                    .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
            }
        }
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
        guard let window = NSApp.keyWindow else { return }
        savedColumnVisibility = columnVisibility
        isFullScreen = true
        window.toolbar?.isVisible = false
        window.toggleFullScreen(nil)
    }

    private func exitFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        isFullScreen = false
        columnVisibility = savedColumnVisibility
        window.toolbar?.isVisible = true
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    private func navigateToParent(folder: ScannedFolder, subPath: String) {
        let parentPath = URL(fileURLWithPath: subPath).deletingLastPathComponent().path
        if parentPath == folder.path || parentPath.count < folder.path.count {
            selectedSidebarItem = .folder(folder)
        } else {
            selectedSidebarItem = .subfolder(folder, parentPath)
        }
    }

    private func photoDetail(_ photo: Photo, showInspector: Binding<Bool>) -> some View {
        PhotoDetailView(photo: photo, showInspector: showInspector, isHDR: $isPhotoHDR, viewModel: viewModel, preloadCache: preloadCache)
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
        case .tag(let tag):
            PhotoGridView(
                viewModel: viewModel,
                selectedPhoto: $selectedPhoto,
                onDoubleClick: { detailPhoto = $0 },
                tagFilter: tag
            )
        case nil:
            ContentUnavailableView(
                "Select a Folder",
                systemImage: "folder",
                description: Text("Choose a folder from the sidebar to browse photos.")
            )
        }
    }
}
