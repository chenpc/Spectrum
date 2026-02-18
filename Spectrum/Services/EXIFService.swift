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

    // {Exif} extras
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

    // Top-level
    var headroom: Double?
    var profileName: String?
    var colorDepth: Int?
    var orientation: Int?
    var dpiWidth: Double?
    var dpiHeight: Double?

    // {TIFF}
    var software: String?

    // {ExifAux}
    var imageStabilization: Int?

    // Sony MakerNote
    var pictureProfile: String?
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

        // Top-level properties
        result.colorDepth = properties[kCGImagePropertyDepth] as? Int
        result.orientation = properties[kCGImagePropertyOrientation] as? Int
        result.dpiWidth = properties[kCGImagePropertyDPIWidth] as? Double
        result.dpiHeight = properties[kCGImagePropertyDPIHeight] as? Double
        result.profileName = properties[kCGImagePropertyProfileName] as? String
        // Headroom: Sony HLG uses top-level "Headroom"; iPhone uses MakerApple tag 33
        if let h = (properties as NSDictionary)["Headroom"] as? Double {
            result.headroom = h
        } else if let makerApple = (properties as NSDictionary)["{MakerApple}"] as? [String: Any],
                  let h = makerApple["33"] as? Double {
            result.headroom = h
        }

        // TIFF
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            result.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            result.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            result.software = tiff[kCGImagePropertyTIFFSoftware] as? String
        }

        // EXIF
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            let offsetTime = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            result.offsetTimeOriginal = offsetTime

            if let dateStr {
                if let offsetTime {
                    // Parse with timezone
                    let tzFormatter = DateFormatter()
                    tzFormatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
                    tzFormatter.locale = Locale(identifier: "en_US_POSIX")
                    result.dateTaken = tzFormatter.date(from: dateStr + offsetTime)
                        ?? exifDateFormatter.date(from: dateStr)
                } else {
                    result.dateTaken = exifDateFormatter.date(from: dateStr)
                }
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

            result.exposureBias = exif[kCGImagePropertyExifExposureBiasValue] as? Double
            result.exposureProgram = exif[kCGImagePropertyExifExposureProgram] as? Int
            result.meteringMode = exif[kCGImagePropertyExifMeteringMode] as? Int
            result.flash = exif[kCGImagePropertyExifFlash] as? Int
            result.whiteBalance = exif[kCGImagePropertyExifWhiteBalance] as? Int
            result.brightnessValue = exif[kCGImagePropertyExifBrightnessValue] as? Double
            result.focalLenIn35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
            result.sceneCaptureType = exif[kCGImagePropertyExifSceneCaptureType] as? Int
            result.lightSource = exif[kCGImagePropertyExifLightSource] as? Int
            result.digitalZoomRatio = exif[kCGImagePropertyExifDigitalZoomRatio] as? Double
            result.contrast = exif[kCGImagePropertyExifContrast] as? Int
            result.saturation = exif[kCGImagePropertyExifSaturation] as? Int
            result.sharpness = exif[kCGImagePropertyExifSharpness] as? Int
            result.subsecTimeOriginal = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String

            if let lensSpec = exif[kCGImagePropertyExifLensSpecification] as? [Double], !lensSpec.isEmpty {
                result.lensSpecification = lensSpec
            }

            if let versionArray = exif[kCGImagePropertyExifVersion] as? [Int] {
                result.exifVersion = versionArray.map(String.init).joined(separator: ".")
            }
        }

        // ExifAux
        if let aux = properties[kCGImagePropertyExifAuxDictionary] as? [String: Any] {
            result.imageStabilization = aux["ImageStabilization"] as? Int
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

        // Sony MakerNote
        result.pictureProfile = SonyMakerNoteParser.extractPictureProfile(from: url)

        return result
    }
}
