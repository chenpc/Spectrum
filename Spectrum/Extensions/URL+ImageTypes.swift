import Foundation
import UniformTypeIdentifiers

extension URL {
    var isImageFile: Bool {
        guard let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    var isVideoFile: Bool {
        guard let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    var isMediaFile: Bool {
        isImageFile || isVideoFile
    }
}
