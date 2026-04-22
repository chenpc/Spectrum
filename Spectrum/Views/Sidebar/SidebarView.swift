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
            loadChildren()
        }
    }

    private var label: some View {
        Label(name, systemImage: "folder")
            .tag(SidebarItem.subfolder(folder, path))
    }

    private func loadChildren() {
        let bookmarkData = folder.bookmarkData
        let path = self.path
        Task.detached(priority: .background) {
            let result = FolderReader.listSubfolders(folderPath: path, bookmarkData: bookmarkData)
            await MainActor.run {
                self.children = result
                self.loaded = true
            }
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Query private var folders: [ScannedFolder]
    @Environment(\.modelContext) private var modelContext

    /// folder.persistentModelID -> immediate subfolders
    @State private var folderChildren: [String: [(name: String, path: String, coverPath: String?, coverDate: Date?)]] = [:]
    @State private var dropTargeted = false
    /// Paths of folders whose bookmark cannot be resolved or whose directory no longer exists.
    @State private var missingFolders: Set<String> = []
    /// 嘗試加入一個「正在刪除中」的資料夾時顯示的錯誤名稱。
    @State private var pendingDeletionConflictName: String? = nil

    /// 最近加入的資料夾排最前，過濾掉刪除中的資料夾。
    private var sortedFolders: [ScannedFolder] {
        folders
            .filter { !$0.isPendingDeletion }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(sortedFolders) { folder in
                    folderRow(folder)
                }
            } header: {
                Text("Folders")
                    .accessibilityIdentifier(AccessibilityID.sidebarFoldersSection)
            }

        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AccessibilityID.sidebarList)
        .frame(minWidth: 200)
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView {
                    Label("No Folders", systemImage: "folder.badge.plus")
                } description: {
                    Text("Drag folders here or use File → Add Folder...")
                }
                .accessibilityIdentifier(AccessibilityID.sidebarEmptyMessage)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarProgressBar()
        }
        .focusedSceneValue(\.addFolderAction, addFolder)
        .task(priority: .userInitiated) {
            await resumePendingDeletions()
            loadAllFolderChildren()
            // --add-folder CLI 參數：app 就緒後自動加入資料夾
            if let folderURL = AppLaunchArgs.shared.addFolder {
                Log.info(Log.scanner, "[launch] --add-folder \(folderURL.path)")
                addFolderURL(folderURL)
            }
        }
        .alert(
            "無法加入資料夾",
            isPresented: Binding(get: { pendingDeletionConflictName != nil },
                                 set: { if !$0 { pendingDeletionConflictName = nil } })
        ) {
            Button("OK") { pendingDeletionConflictName = nil }
        } message: {
            if let name = pendingDeletionConflictName {
                Text("「\(name)」正在刪除中，請等待完成後再加入。")
            }
        }
    }

    private func loadAllFolderChildren() {
        var nowMissing: Set<String> = []
        var toScan: [(path: String, bookmarkData: Data)] = []

        for folder in folders {
            guard let bookmarkData = folder.bookmarkData,
                  let (url, freshData) = try? BookmarkService.resolveBookmarkRefreshing(bookmarkData) else {
                nowMissing.insert(folder.path)
                folderChildren[folder.path] = nil
                continue
            }
            if let freshData {
                folder.bookmarkData = freshData
            }
            let accessible = BookmarkService.withSecurityScope(url) {
                FileManager.default.fileExists(atPath: url.path)
            }
            guard accessible else {
                nowMissing.insert(folder.path)
                folderChildren[folder.path] = nil
                continue
            }
            toScan.append((folder.path, folder.bookmarkData ?? bookmarkData))
        }
        missingFolders = nowMissing

        Task.detached(priority: .background) {
            var collected: [(String, [(name: String, path: String, coverPath: String?, coverDate: Date?)])] = []
            for item in toScan {
                let children = FolderReader.listSubfolders(folderPath: item.path, bookmarkData: item.bookmarkData)
                collected.append((item.path, children))
            }
            let snapshot = collected
            await MainActor.run {
                for (path, children) in snapshot {
                    self.folderChildren[path] = children
                }
            }
        }
    }

    /// 掃描進行中快速更新：略過 bookmark 驗證，只重新查詢已知有效的資料夾子目錄。
    private func refreshFolderChildren() {
        let toScan = folders
            .filter { !missingFolders.contains($0.path) && !$0.isPendingDeletion }
            .map { (path: $0.path, bookmarkData: $0.bookmarkData) }

        Task.detached(priority: .background) {
            var collected: [(String, [(name: String, path: String, coverPath: String?, coverDate: Date?)])] = []
            for item in toScan {
                let children = FolderReader.listSubfolders(folderPath: item.path, bookmarkData: item.bookmarkData)
                collected.append((item.path, children))
            }
            let snapshot = collected
            await MainActor.run {
                for (path, children) in snapshot {
                    self.folderChildren[path] = children
                }
            }
        }
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
        let name = URL(fileURLWithPath: folder.path).lastPathComponent
        let icon = isMissing ? "folder.badge.questionmark" : "folder"
        Label(name, systemImage: icon)
            .foregroundStyle(isMissing ? .secondary : .primary)
            .tag(SidebarItem.folder(folder))
            .contextMenu {
                Button("Rescan") { rescanFolder(folder) }.disabled(isMissing)
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                }.disabled(isMissing)
                Divider()
                Button("Remove", role: .destructive) {
                    startFolderRemoval(folder)
                }
            }
    }

    /// Remove button 觸發點：先在 DB 標記 isPendingDeletion，再背景刪除。
    private func startFolderRemoval(_ folder: ScannedFolder) {
        // 1. 先寫 DB flag（同步，MainActor）
        folder.isPendingDeletion = true
        try? modelContext.save()

        // 2. UI 狀態清理
        FolderMonitor.shared.stopMonitoring(path: folder.path)
        if selection == .folder(folder) { selection = nil }

        // 3. 背景完成刪除
        performFolderRemoval(id: folder.persistentModelID,
                             folderName: URL(fileURLWithPath: folder.path).lastPathComponent,
                             folderPath: folder.path,
                             container: modelContext.container)
    }

    /// 背景執行：刪除 Photos → 清除縮圖（整個子目錄，instant）→ 刪除 ScannedFolder 記錄。
    private func performFolderRemoval(id: PersistentIdentifier, folderName: String, folderPath: String, container: ModelContainer) {
        ThumbnailProgress.shared.markRemovalStarted(name: folderName)
        Task.detached(priority: .background) {
            let scanner = FolderScanner(modelContainer: container)
            await scanner.removePhotos(forFolder: id)
            await ThumbnailService.shared.clearCache()
            await scanner.removeFolderRecord(id: id)
            await MainActor.run { ThumbnailProgress.shared.markRemovalFinished() }
        }
    }

    /// App 啟動時恢復上次未完成的 folder 刪除（crash / 強制關閉後續做）。
    private func resumePendingDeletions() async {
        let pending = folders.filter { $0.isPendingDeletion }
        guard !pending.isEmpty else { return }
        Log.info(Log.scanner, "[sidebar] resuming \(pending.count) pending deletion(s)")
        for folder in pending {
            FolderMonitor.shared.stopMonitoring(path: folder.path)
            if selection == .folder(folder) { selection = nil }
            performFolderRemoval(id: folder.persistentModelID,
                                 folderName: URL(fileURLWithPath: folder.path).lastPathComponent,
                                 folderPath: folder.path,
                                 container: modelContext.container)
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

        // 把所有資料夾寫入 DB（只存 bookmark，不掃描）
        let inserted = panel.urls.filter { insertFolderURL($0) != nil }
        guard !inserted.isEmpty else { return }
    }

    /// 把單一 URL 寫入 DB 並回傳 PersistentIdentifier；已存在或失敗則回傳 nil。
    @discardableResult
    private func insertFolderURL(_ url: URL) -> PersistentIdentifier? {
        if let existing = folders.first(where: { $0.path == url.path }) {
            if existing.isPendingDeletion {
                pendingDeletionConflictName = URL(fileURLWithPath: url.path).lastPathComponent
            }
            return nil
        }
        do {
            let bookmarkData = try BookmarkService.createBookmark(for: url)
            let remountURL = BookmarkService.remountURL(for: url)?.absoluteString
            let folder = ScannedFolder(path: url.path, bookmarkData: bookmarkData,
                                       remountURL: remountURL, sortOrder: folders.count)
            modelContext.insert(folder)
            try modelContext.save()
            if selection == nil { selection = .folder(folder) }
            return folder.persistentModelID
        } catch {
            Log.bookmark.warning("Failed to create bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Drop 或單一來源呼叫：只寫入 ScannedFolder（bookmark），不掃描不生成縮圖。
    private func addFolderURL(_ url: URL) {
        insertFolderURL(url)
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

    /// Rescan context menu 用：重新整理此資料夾的 bookmark。
    private func rescanFolder(_ folder: ScannedFolder) {
        guard let bookmarkData = folder.bookmarkData,
              let (_, freshData) = try? BookmarkService.resolveBookmarkRefreshing(bookmarkData),
              let fresh = freshData else { return }
        folder.bookmarkData = fresh
        try? modelContext.save()
    }
}

// MARK: - Sidebar progress bar

private struct SidebarProgressBar: View {
    private let progress = ThumbnailProgress.shared

    var body: some View {
        if progress.isActive {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    if progress.isRemoving {
                        ProgressView().controlSize(.small).frame(width: 20)
                        Text("Removing \(progress.removingName)…")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        if progress.thumbTotal > 0 {
                            ProgressView(value: Double(progress.thumbDone), total: Double(progress.thumbTotal))
                                .progressViewStyle(.linear).frame(maxWidth: .infinity)
                        } else {
                            ProgressView().controlSize(.small).frame(width: 20)
                        }
                        HStack(spacing: 4) {
                            Text("\(progress.thumbDone) / \(progress.thumbTotal)")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            if progress.isScanning {
                                Text("· Scanning…")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            } else if progress.isScheduled || (progress.isGenerating && progress.thumbRate == 0) {
                                Text("· Preparing…")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            } else if progress.isGenerating && progress.thumbRate > 0 {
                                Text("· \(Int(progress.thumbRate.rounded())) /s")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .background(.bar)
        }
    }
}
