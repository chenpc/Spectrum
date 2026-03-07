import Foundation
import AppKit

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
        writeToSystemPasteboard(path: path)
    }

    func cut(path: String, bookmarkData: Data) {
        content = ClipboardFolder(sourcePath: path, bookmarkData: bookmarkData, isCut: true)
        writeToSystemPasteboard(path: path)
    }

    func clear() {
        content = nil
    }

    private func writeToSystemPasteboard(path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
    }
}
