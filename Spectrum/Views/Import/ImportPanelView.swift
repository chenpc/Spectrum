import SwiftUI
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ImportItem: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let dateTaken: Date
    let isVideo: Bool
}

struct ImportDateGroup: Identifiable {
    let date: String         // display name, e.g. "Jan 1, 2025"
    let folderName: String   // filesystem name, e.g. "20250101"
    let items: [ImportItem]
    var id: String { folderName }
}

@Observable
@MainActor
final class ImportPanelModel {
    static let shared = ImportPanelModel()

    var sourceURL: URL?
    var items: [ImportItem] = []
    var isScanning = false

    // MARK: - Copy/Move 多任務進度
    struct ImportTask: Identifiable {
        let id = UUID()
        var label: String
        var done: Int
        var total: Int
        var isDeterminate: Bool { total > 0 }
    }
    private(set) var importTasks: [ImportTask] = []

    func beginImportTask(label: String, total: Int) -> UUID {
        let task = ImportTask(label: label, done: 0, total: total)
        importTasks.append(task)
        return task.id
    }

    func updateImportTask(_ id: UUID, done: Int) {
        guard let idx = importTasks.firstIndex(where: { $0.id == id }) else { return }
        importTasks[idx].done = done
    }

    func finishImportTask(_ id: UUID) {
        importTasks.removeAll { $0.id == id }
    }


    /// Toggle to expand/collapse all groups (toggling triggers onChange in views)
    var expandCollapseToken = 0
    var expandAll = true

    /// Pending group drag — set before onDrag, consumed by drop handler
    var draggedGroup: ImportDateGroup?
    /// true = move (cut), false = copy
    var draggedGroupIsCut = false

    private static let folderNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var dateGroups: [ImportDateGroup] {
        let grouped = Dictionary(grouping: items) {
            ImportPanelModel.folderNameFormatter.string(from: $0.dateTaken)
        }
        return grouped.sorted { lhs, rhs in
            lhs.key > rhs.key  // newest first
        }.map { key, values in
            let displayDate = values.first.map {
                ImportPanelModel.displayDateFormatter.string(from: $0.dateTaken)
            } ?? key
            return ImportDateGroup(
                date: displayDate,
                folderName: key,
                items: values.sorted { $0.dateTaken > $1.dateTaken }
            )
        }
    }

    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a folder to import from")
        panel.prompt = String(localized: "Select")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        sourceURL = url
        Task { await scanFolder(url: url) }
    }

    func scanFolder(url: URL) async {
        isScanning = true
        items = []
        await Task.yield()  // 讓 SwiftUI 先 render 掃描狀態再開始工作

        let scopeStarted = url.startAccessingSecurityScopedResource()
        let stream = AsyncStream<ImportItem> { continuation in
            Task.detached {
                ImportPanelModel.enumerateMedia(in: url, yield: { continuation.yield($0) })
                continuation.finish()
            }
        }
        var batchCount = 0
        for await item in stream {
            items.append(item)
            batchCount += 1
            if batchCount % 10 == 0 {
                await Task.yield()
            }
        }
        if scopeStarted { url.stopAccessingSecurityScopedResource() }

        isScanning = false
    }

    /// Open a folder directly (without NSOpenPanel), e.g. from grid view context menu.
    func openFolder(url: URL) {
        sourceURL = url
        Task { await scanFolder(url: url) }
    }

    /// Remove items that have been moved out
    func removeItems(_ urls: Set<URL>) {
        items.removeAll { urls.contains($0.url) }
    }

    nonisolated private static func enumerateMedia(in url: URL, yield yieldItem: (ImportItem) -> Void) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        for case let fileURL as URL in enumerator {
            guard fileURL.isMediaFile else { continue }
            let date = extractDateStatic(from: fileURL, formatter: dateFormatter)
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date()
            yieldItem(ImportItem(url: fileURL, fileName: fileURL.lastPathComponent, dateTaken: date, isVideo: fileURL.isVideoFile))
        }
    }

    nonisolated private static func extractDateStatic(from url: URL, formatter: DateFormatter) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else {
            return nil
        }
        return formatter.date(from: dateStr)
    }

    func close() {
        sourceURL = nil
        items = []
    }
}

struct ImportPanelView: View {
    @Bindable var model: ImportPanelModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.sourceURL == nil {
                emptyState
            } else if model.items.isEmpty && !model.isScanning {
                Spacer()
                Text("No media files found")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                fileList
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ImportPanelFooter(model: model)
        }
        .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
    }

    private var header: some View {
        HStack {
            Text("Import")
                .font(.headline)
            Spacer()
            Button {
                model.expandAll.toggle()
                model.expandCollapseToken += 1
            } label: {
                Image(systemName: model.expandAll ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
            }
            .help(model.expandAll ? "Collapse All" : "Expand All")
            Button {
                model.selectFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Select folder to import from")
            Button {
                model.close()
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.and.arrow.down")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Select a folder to import photos and videos")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Select Folder…") {
                model.selectFolder()
            }
            Spacer()
        }
        .padding()
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.dateGroups) { group in
                    ImportDateGroupView(group: group)
                }
            }
            .padding(4)
        }
    }
}

struct ImportDateGroupView: View {
    let group: ImportDateGroup
    @State private var isExpanded = true
    private let model = ImportPanelModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Draggable folder header
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "folder.badge.minus" : "folder.fill")
                    .foregroundStyle(.secondary)
                Text(group.folderName)
                    .font(.caption.bold().monospacedDigit())
                Spacer()
                Text(group.date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("\(group.items.count)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.5))
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }
            .onTapGesture(count: 1) {
                // single tap: no-op (prevents double-tap delay from blocking drag)
            }
            .onDrag {
                ImportPanelModel.shared.draggedGroup = group
                ImportPanelModel.shared.draggedGroupIsCut = false
                return NSItemProvider(object: "import-group:\(group.folderName)" as NSString)
            }
            .contextMenu {
                Button("Copy") {
                    ImportPanelModel.shared.draggedGroup = group
                    ImportPanelModel.shared.draggedGroupIsCut = false
                }
                Button("Cut") {
                    ImportPanelModel.shared.draggedGroup = group
                    ImportPanelModel.shared.draggedGroupIsCut = true
                }
            }

            if isExpanded {
                let columns = [GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 2)]
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(group.items) { item in
                        ImportThumbnailView(item: item)
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, 2)
            }
        }
        .onChange(of: model.expandCollapseToken) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded = model.expandAll }
        }
    }
}

struct ImportThumbnailView: View {
    let item: ImportItem
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 60, height: 60)
                    .overlay {
                        ProgressView().scaleEffect(0.4)
                    }
            }
            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
        .task {
            thumbnail = await generateThumbnail(for: item.url)
        }
    }

    private func generateThumbnail(for url: URL) async -> NSImage? {
        let size = CGSize(width: 120, height: 120)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2.0, representationTypes: .thumbnail)
        do {
            let thumb = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return thumb.nsImage
        } catch {
            return nil
        }
    }
}

// MARK: - Import Panel Footer

private struct ImportPanelFooter: View {
    let model: ImportPanelModel

    var body: some View {
        if !model.importTasks.isEmpty || model.isScanning {
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 4) {
                    ForEach(model.importTasks) { task in
                        HStack(spacing: 8) {
                            ProgressView(value: Double(task.done), total: Double(max(1, task.total)))
                                .progressViewStyle(.linear)
                                .frame(maxWidth: .infinity)
                            Text("\(task.label) \(task.done)/\(task.total)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    if model.isScanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).frame(width: 20)
                            Text(model.items.isEmpty ? "Scanning…" : "Scanning… \(model.items.count) files found")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
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
