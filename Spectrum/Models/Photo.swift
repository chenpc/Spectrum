import SwiftData
import Foundation

@Model
final class Photo {
    @Attribute(.unique) var filePath: String
    var fileName: String
    var dateTaken: Date
    var dateAdded: Date
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

    // EXIF extras
    var exposureBias: Double?
    var exposureProgram: Int?
    var meteringMode: Int?
    var flash: Int?
    var whiteBalance: Int?
    var brightnessValue: Double?
    var focalLenIn35mm: Int?
    var sceneCaptureType: Int?
    var lightSource: Int?
    var digitalZoomRatio: Double?
    var contrast: Int?
    var saturation: Int?
    var sharpness: Int?
    var lensSpecification: [Double]?
    var offsetTimeOriginal: String?
    var subsecTimeOriginal: String?
    var exifVersion: String?

    // Top-level metadata
    var headroom: Double?
    var profileName: String?
    var colorDepth: Int?
    var orientation: Int?
    var dpiWidth: Double?
    var dpiHeight: Double?

    // TIFF
    var software: String?

    // ExifAux
    var imageStabilization: Int?

    // Video fields
    var isVideo: Bool = false
    var duration: Double?
    var videoCodec: String?
    var audioCodec: String?

    // Live Photo fields
    /// Path to the companion .mov for a Live Photo (set on the image entry)
    var livePhotoMovPath: String?
    /// True if this entry is the companion .mov of a Live Photo (hidden from grid)
    var isLivePhotoMov: Bool = false

    /// Ordered edit operations (JSON-encoded [EditOp]). nil = no edits.
    var editOpsJson: String?

    var editOps: [EditOp] {
        get {
            guard let json = editOpsJson, let data = json.data(using: .utf8),
                  let ops = try? JSONDecoder().decode([EditOp].self, from: data)
            else { return [] }
            return ops
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                editOpsJson = String(data: data, encoding: .utf8)
            } else {
                editOpsJson = nil
            }
        }
    }

    var compositeEdit: CompositeEdit {
        CompositeEdit.from(editOps)
    }

    // Relationships
    var folder: ScannedFolder?

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
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.folder = folder
    }

    /// Resolve bookmark data: try the relationship first, then fall back to path-matching.
    func resolveBookmarkData(from folders: [ScannedFolder]) -> Data? {
        if let data = folder?.bookmarkData { return data }
        return folders.first { filePath.hasPrefix($0.path) }?.bookmarkData
    }
}
