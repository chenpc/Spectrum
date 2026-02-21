import Foundation
import UniformTypeIdentifiers

extension URL {
    /// Common camera RAW extensions that UTType may not recognise on all
    /// macOS configurations (e.g. com.sony.arw-raw-image may not be declared
    /// if no compatible app is installed).
    static let rawPhotoExtensions: Set<String> = [
        "arw", "srf", "sr2",    // Sony
        "nef", "nrw",            // Nikon
        "cr2", "cr3",            // Canon
        "raf",                   // Fujifilm
        "dng",                   // Adobe DNG / Leica / Ricoh / DJI…
        "rw2",                   // Panasonic
        "orf",                   // Olympus / OM System
        "pef",                   // Pentax
        "x3f",                   // Sigma
        "3fr",                   // Hasselblad
        "mef",                   // Mamiya
        "iiq",                   // Phase One
    ]

    /// True for camera RAW files that require explicit extension matching
    /// because UTType conformance cannot be relied upon universally.
    var isCameraRawFile: Bool {
        URL.rawPhotoExtensions.contains(pathExtension.lowercased())
    }

    var isImageFile: Bool {
        // Fast path: explicitly listed RAW extensions are always treated as images.
        if isCameraRawFile { return true }
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
