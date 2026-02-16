import SwiftData
import Foundation

@Model
final class Photo {
    @Attribute(.unique) var filePath: String
    var fileName: String
    var dateTaken: Date
    var dateAdded: Date
    var isFavorite: Bool
    var fileSize: Int64
    var pixelWidth: Int
    var pixelHeight: Int

    // EXIF cache
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var aperture: Double?
    var shutterSpeed: String?
    var iso: Int?
    var latitude: Double?
    var longitude: Double?

    // Video fields
    var isVideo: Bool = false
    var duration: Double?
    var videoCodec: String?
    var audioCodec: String?

    // Relationships
    var folder: ScannedFolder?
    @Relationship(inverse: \Tag.photos) var tags: [Tag] = []

    init(
        filePath: String,
        fileName: String,
        dateTaken: Date,
        fileSize: Int64 = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        folder: ScannedFolder? = nil
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.dateTaken = dateTaken
        self.dateAdded = Date()
        self.isFavorite = false
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.folder = folder
        self.tags = []
    }
}
