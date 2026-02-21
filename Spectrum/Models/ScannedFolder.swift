import SwiftData
import Foundation

@Model
final class ScannedFolder {
    var path: String
    var bookmarkData: Data?
    /// Network volume remount URL (e.g. "smb://server/share") captured when the folder was added.
    /// Used to trigger auto-mount when the volume is offline.
    var remountURL: String?
    var dateAdded: Date
    var sortOrder: Int = 0
    @Relationship(deleteRule: .cascade) var photos: [Photo] = []

    init(path: String, bookmarkData: Data, remountURL: String? = nil, sortOrder: Int = 0) {
        self.path = path
        self.bookmarkData = bookmarkData
        self.remountURL = remountURL
        self.dateAdded = Date()
        self.sortOrder = sortOrder
        self.photos = []
    }
}
