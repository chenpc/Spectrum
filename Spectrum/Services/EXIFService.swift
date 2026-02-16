import Foundation
import ImageIO
import CoreLocation

struct EXIFData {
    var dateTaken: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var aperture: Double?
    var shutterSpeed: String?
    var iso: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var latitude: Double?
    var longitude: Double?
}

enum EXIFService {
    private static let exifDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    static func readEXIF(from url: URL) -> EXIFData {
        var result = EXIFData()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return result }

        // Dimensions
        result.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        result.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int

        // TIFF
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            result.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            result.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }

        // EXIF
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                result.dateTaken = exifDateFormatter.date(from: dateStr)
            }
            result.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            result.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            result.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            if let exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double {
                if exposureTime >= 1 {
                    result.shutterSpeed = String(format: "%.1fs", exposureTime)
                } else {
                    let denominator = Int(round(1.0 / exposureTime))
                    result.shutterSpeed = "1/\(denominator)s"
                }
            }
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
                result.iso = first
            }
        }

        // GPS
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String {
                result.latitude = latRef == "S" ? -lat : lat
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                result.longitude = lonRef == "W" ? -lon : lon
            }
        }

        return result
    }
}
