import SwiftData
import Foundation

@Model
final class Tag {
    @Attribute(.unique) var name: String
    var photos: [Photo] = []

    init(name: String) {
        self.name = name
        self.photos = []
    }
}
