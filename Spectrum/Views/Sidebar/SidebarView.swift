import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A sidebar row for a subfolder that lazily loads its children only when expanded.
private struct SubfolderSidebarRow: View {
    let folder: ScannedFolder
    let path: String
    let name: String
    @Environment(\.modelContext) private var modelContext
    @State private var children: [(name: String, path: String, coverPath: String?, coverDate: Date?)] = []
    @State private var loaded = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if loaded {
                ForEach(children, id: \.path) { child in
                    SubfolderSidebarRow(folder: folder, path: child.path, name: child.name)
                }
            } else {
                ProgressView().scaleEffect(0.6)
            }
        } label: {
            label
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, !loaded else { return }
            Task { await loadChildren() }
        }
    }

    private var label: some View {
        Label(name, systemImage: "folder")
            .tag(SidebarItem.subfolder(folder, path))
    }

    private func loadChildren() async {
        let scanner = FolderScanner(modelContainer: modelContext.container)
        children = await scanner.listSubfolders(id: folder.persistentModelID, path: path)
        loaded = true
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Query private var folders: [ScannedFolder]
    @Query(sort: \Photo.dateTaken, order: .reverse) private var allPhotos: [Photo]
    @Environment(\.modelContext) private var modelContext

    @State private var isScanning = false
    /// folder.persistentModelID -> immediate subfolders
    @State private var folderChildren: [String: [(name: String, path: String, coverPath: String?, coverDate: Date?)]] = [:]
    @State private var dropTargeted = false
    /// Paths of folders whose bookmark cannot be resolved or whose directory no longer exists.
    @State private var missingFolders: Set<String> = []

    /// Folders sorted by latest photo dateTaken (most recent first).
    /// Falls back to folder path alphabetically when no photos are indexed yet.
    private var sortedFolders: [ScannedFolder] {
        // Build a map of folder.path -> latest dateTaken using one pass over sorted allPhotos.
        var latestDate: [String: Date] = [:]
        let paths = Set(folders.map(\.path))
        for photo in allPhotos {
            for path in paths {
                if photo.filePath.hasPrefix(path.hasSuffix("/") ? path : path + "/") || photo.filePath == path {
                    if latestDate[path] == nil { latestDate[path] = photo.dateTaken }
                }
            }
            if latestDate.count == paths.count { break }
        }
        return folders.sorted { a, b in
            switch (latestDate[a.path], latestDate[b.path]) {
            case let (ad?, bd?): return ad > bd
            case (nil, _?):     return false
            case (_?, nil):     return true
            case (nil, nil):    return a.path < b.path
            }
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Folders") {
                ForEach(sortedFolders) { folder in
                    folderRow(folder)
                }
            }

        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView {
                    Label("No Folders", systemImage: "folder.badge.plus")
                } description: {
                    Text("Drag folders here or use File → Add Folder...")
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .focusedSceneValue(\.addFolderAction, addFolder)
        .task {
            await loadAllFolderChildren()
        }
    }

    private func loadAllFolderChildren() async {
        var nowMissing: Set<String> = []

        // Show cached children immediately (no filesystem I/O)
        for folder in folders {
            if let cached = FolderListCache.shared.entries(for: folder.path) {
                folderChildren[folder.path] = cached.map {
                    (name: $0.name, path: $0.path, coverPath: $0.coverPath, coverDate: $0.coverDate)
                }
            }
        }

        // Async refresh from filesystem — updates if folders were added/removed
        let scanner = FolderScanner(modelContainer: modelContext.container)
        for folder in folders {
            // Check if the folder is still accessible
            guard let bookmarkData = folder.bookmarkData,
                  let url = try? BookmarkService.resolveBookmark(bookmarkData) else {
                nowMissing.insert(folder.path)
                folderChildren[folder.path] = nil
                FolderListCache.shared.invalidate(parentPath: folder.path)
                continue
            }
            let accessible = BookmarkService.withSecurityScope(url) {
                FileManager.default.fileExists(atPath: url.path)
            }
            guard accessible else {
                nowMissing.insert(folder.path)
                folderChildren[folder.path] = nil
                FolderListCache.shared.invalidate(parentPath: folder.path)
                continue
            }

            let children = await scanner.listSubfolders(id: folder.persistentModelID)
            folderChildren[folder.path] = children
        }

        missingFolders = nowMissing
    }

    @ViewBuilder
    private func folderRow(_ folder: ScannedFolder) -> some View {
        let isMissing = missingFolders.contains(folder.path)
        let children = folderChildren[folder.path] ?? []
        if isMissing || children.isEmpty {
            folderLabel(folder, isMissing: isMissing)
        } else {
            DisclosureGroup {
                ForEach(children, id: \.path) { child in
                    SubfolderSidebarRow(folder: folder, path: child.path, name: child.name)
                }
            } label: {
                folderLabel(folder, isMissing: false)
            }
        }
    }

    @ViewBuilder
    private func folderLabel(_ folder: ScannedFolder, isMissing: Bool) -> some View {
        Label(URL(fileURLWithPath: folder.path).lastPathComponent,
              systemImage: isMissing ? "folder.badge.questionmark" : "folder")
        .foregroundStyle(isMissing ? .secondary : .primary)
        .tag(SidebarItem.folder(folder))
        .contextMenu {
            Button("Rescan") {
                Task { await rescanFolder(folder) }
            }
            .disabled(isScanning || isMissing)
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            }
            .disabled(isMissing)
            Divider()
            Button("Remove", role: .destructive) {
                FolderMonitor.shared.stopMonitoring(path: folder.path)
                if selection == .folder(folder) {
                    selection = nil
                }
                modelContext.delete(folder)
                try? modelContext.save()
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Select a folder to scan for photos")
        panel.prompt = String(localized: "Scan")

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            addFolderURL(url)
        }
    }

    private func addFolderURL(_ url: URL) {
        // Skip if already added
        guard !folders.contains(where: { $0.path == url.path }) else { return }

        do {
            let bookmarkData = try BookmarkService.createBookmark(for: url)
            let remountURL = BookmarkService.remountURL(for: url)?.absoluteString
            let folder = ScannedFolder(path: url.path, bookmarkData: bookmarkData, remountURL: remountURL, sortOrder: folders.count)
            modelContext.insert(folder)
            try modelContext.save()

            selection = .folder(folder)

            Task {
                await rescanFolder(folder)
                await loadAllFolderChildren()
            }
        } catch {
            Log.bookmark.warning("Failed to create bookmark: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { return }

                DispatchQueue.main.async {
                    addFolderURL(url)
                }
            }
        }
    }

    private func rescanFolder(_ folder: ScannedFolder) async {
        isScanning = true
        let scanner = FolderScanner(modelContainer: modelContext.container)
        try? await scanner.scanFolder(id: folder.persistentModelID, clearAll: true)
        isScanning = false
    }
}
