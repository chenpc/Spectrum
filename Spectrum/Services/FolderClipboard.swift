import Foundation
import AppKit

struct ClipboardFolder: Sendable {
    let sourcePath: String
    let bookmarkData: Data
    var isCut: Bool
    var name: String { URL(fileURLWithPath: sourcePath).lastPathComponent }
}

struct ClipboardFiles: Sendable {
    let paths: [String]
    let bookmarkData: Data
    var isCut: Bool
    var count: Int { paths.count }
}

@Observable @MainActor
final class FolderClipboard {
    static let shared = FolderClipboard()
    private(set) var content: ClipboardFolder?
    private(set) var files: ClipboardFiles?
    var hasContent: Bool { content != nil || files != nil }

    private init() {}

    func copy(path: String, bookmarkData: Data) {
        content = ClipboardFolder(sourcePath: path, bookmarkData: bookmarkData, isCut: false)
        files = nil
        writeToSystemPasteboard(paths: [path])
    }

    func cut(path: String, bookmarkData: Data) {
        content = ClipboardFolder(sourcePath: path, bookmarkData: bookmarkData, isCut: true)
        files = nil
        writeToSystemPasteboard(paths: [path])
    }

    func copyFiles(paths: [String], bookmarkData: Data) {
        files = ClipboardFiles(paths: paths, bookmarkData: bookmarkData, isCut: false)
        content = nil
        writeToSystemPasteboard(paths: paths)
    }

    func cutFiles(paths: [String], bookmarkData: Data) {
        files = ClipboardFiles(paths: paths, bookmarkData: bookmarkData, isCut: true)
        content = nil
        writeToSystemPasteboard(paths: paths)
    }

    func clear() {
        content = nil
        files = nil
    }

    private func writeToSystemPasteboard(paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    }
}
