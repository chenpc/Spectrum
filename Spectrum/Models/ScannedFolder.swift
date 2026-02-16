import SwiftData
import Foundation

@Model
final class ScannedFolder {
    var path: String
    var bookmarkData: Data?
    var dateAdded: Date
    var sortOrder: Int = 0
    @Relationship(deleteRule: .cascade) var photos: [Photo] = []

    init(path: String, bookmarkData: Data, sortOrder: Int = 0) {
        self.path = path
        self.bookmarkData = bookmarkData
        self.dateAdded = Date()
        self.sortOrder = sortOrder
        self.photos = []
    }
}
