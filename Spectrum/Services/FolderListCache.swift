import Foundation

struct FolderListEntry: Codable, Equatable {
    let name: String
    let path: String
    let coverPath: String?
    let coverDate: Date?
}

/// Persistent cache mapping parent folder path → immediate subfolder entries.
/// Replaces SubfolderDateCache — stores (name, path, coverPath, coverDate) together.
final class FolderListCache: @unchecked Sendable {
    static let shared = FolderListCache()

    private var memory: [String: [FolderListEntry]] = [:]
    /// Paths that have been listed from filesystem this session (cleared on invalidate).
    private var scannedThisSession: Set<String> = []
    private let lock = NSLock()
    private let fileURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Spectrum", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("FolderList.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [FolderListEntry]].self, from: data) {
            memory = decoded
        }
    }

    /// Returns cached children of a parent folder, or nil if not yet cached.
    func entries(for parentPath: String) -> [FolderListEntry]? {
        lock.withLock { memory[parentPath] }
    }

    /// Returns a single cached child entry by its path, under the given parent.
    func entry(forChildPath childPath: String, underParent parentPath: String) -> FolderListEntry? {
        lock.withLock { memory[parentPath]?.first { $0.path == childPath } }
    }

    /// Returns true if this path has already been scanned from filesystem this session.
    func isScannedThisSession(_ parentPath: String) -> Bool {
        lock.withLock { scannedThisSession.contains(parentPath) }
    }

    func setEntries(_ entries: [FolderListEntry], for parentPath: String) {
        lock.withLock {
            memory[parentPath] = entries
            scannedThisSession.insert(parentPath)
        }
        persistAsync()
    }

    func invalidate(parentPath: String) {
        lock.withLock {
            memory[parentPath] = nil
            scannedThisSession.remove(parentPath)
            // Also invalidate the grandparent so the cover thumbnail for this folder gets re-evaluated.
            let parent = (parentPath as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != parentPath {
                memory[parent] = nil
                scannedThisSession.remove(parent)
            }
        }
        persistAsync()
    }

    func clear() {
        lock.withLock { memory = [:]; scannedThisSession = [] }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persistAsync() {
        let snapshot = lock.withLock { memory }
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
