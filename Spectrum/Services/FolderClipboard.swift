import Foundation

struct ClipboardFolder: Sendable {
    let sourcePath: String
    let bookmarkData: Data
    var isCut: Bool
    var name: String { URL(fileURLWithPath: sourcePath).lastPathComponent }
}

@Observable @MainActor
final class FolderClipboard {
    static let shared = FolderClipboard()
    private(set) var content: ClipboardFolder?
    var hasContent: Bool { content != nil }

    private init() {}

    func copy(path: String, bookmarkData: Data) {
        content = ClipboardFolder(sourcePath: path, bookmarkData: bookmarkData, isCut: false)
    }

    func cut(path: String, bookmarkData: Data) {
        content = ClipboardFolder(sourcePath: path, bookmarkData: bookmarkData, isCut: true)
    }

    func clear() {
        content = nil
    }
}
