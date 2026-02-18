import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A sidebar row for a subfolder that lazily loads its children from the filesystem.
private struct SubfolderSidebarRow: View {
    let folder: ScannedFolder
    let path: String
    let name: String
    @Environment(\.modelContext) private var modelContext
    @State private var children: [(name: String, path: String, coverPath: String?)] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                label
                    .task { await loadChildren() }
            } else if children.isEmpty {
                label
            } else {
                DisclosureGroup {
                    ForEach(children, id: \.path) { child in
                        SubfolderSidebarRow(folder: folder, path: child.path, name: child.name)
                    }
                } label: {
                    label
                }
            }
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
    @Query(sort: \ScannedFolder.sortOrder) private var folders: [ScannedFolder]
    @Environment(\.modelContext) private var modelContext

    @State private var isScanning = false
    /// folder.persistentModelID -> immediate subfolders
    @State private var folderChildren: [String: [(name: String, path: String, coverPath: String?)]] = [:]
    @State private var dropTargeted = false

    var body: some View {
        List(selection: $selection) {
            Section("Folders") {
                ForEach(folders) { folder in
                    folderRow(folder)
                }
                .onMove(perform: moveFolder)
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
        let scanner = FolderScanner(modelContainer: modelContext.container)
        for folder in folders {
            let children = await scanner.listSubfolders(id: folder.persistentModelID)
            folderChildren[folder.path] = children
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: ScannedFolder) -> some View {
        let children = folderChildren[folder.path] ?? []
        if children.isEmpty {
            folderLabel(folder)
        } else {
            DisclosureGroup {
                ForEach(children, id: \.path) { child in
                    SubfolderSidebarRow(folder: folder, path: child.path, name: child.name)
                }
            } label: {
                folderLabel(folder)
            }
        }
    }

    @ViewBuilder
    private func folderLabel(_ folder: ScannedFolder) -> some View {
        Label(URL(fileURLWithPath: folder.path).lastPathComponent, systemImage: "folder")
        .tag(SidebarItem.folder(folder))
        .contextMenu {
            Button("Rescan") {
                Task { await rescanFolder(folder) }
            }
            .disabled(isScanning)
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            }
            Divider()
            Button("Remove", role: .destructive) {
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
        panel.message = "Select a folder to scan for photos"
        panel.prompt = "Scan"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            addFolderURL(url)
        }
    }

    private func moveFolder(from source: IndexSet, to destination: Int) {
        var reordered = Array(folders)
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, folder) in reordered.enumerated() {
            folder.sortOrder = index
        }
        try? modelContext.save()
    }

    private func addFolderURL(_ url: URL) {
        // Skip if already added
        guard !folders.contains(where: { $0.path == url.path }) else { return }

        do {
            let bookmarkData = try BookmarkService.createBookmark(for: url)
            let folder = ScannedFolder(path: url.path, bookmarkData: bookmarkData, sortOrder: folders.count)
            modelContext.insert(folder)
            try modelContext.save()

            selection = .folder(folder)

            Task {
                await rescanFolder(folder)
                await loadAllFolderChildren()
            }
        } catch {
            print("Failed to create bookmark: \(error)")
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
