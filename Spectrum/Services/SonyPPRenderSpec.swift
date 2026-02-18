import AppKit
import CoreImage
import ImageIO

// MARK: - SonyPPRenderSpec

struct SonyPPRenderSpec: HDRRenderSpec {
    let badgeLabel: String
    let needsPrerenderedSDR = true

    /// Raw PP value from MakerNote (28, 31, 32, 33, 34, 35)
    let profileValue: Int

    func detect(source: CGImageSource, url: URL) -> Bool {
        false
    }

    func render(url: URL, filePath: String, screenHeadroom: Float, maxPixelSize: Int?, hlgToneMapMode: HLGToneMapMode = .iccTRC) -> (hdr: NSImage?, sdr: NSImage?) {
        switch profileValue {
        case 32, 33, 34, 35:
            return renderHLG(url: url, filePath: filePath, screenHeadroom: screenHeadroom, maxPixelSize: maxPixelSize)
        case 28, 31:
            // S-Log: display as-is (no proper decode yet)
            return (NSImage(contentsOfFile: filePath), nil)
        default:
            return (NSImage(contentsOfFile: filePath), nil)
        }
    }

    func dynamicRange(showHDR: Bool) -> NSImage.DynamicRange {
        showHDR ? .high : .standard
    }

    // MARK: - HLG render (PP 32-35)

    private func renderHLG(url: URL, filePath: String, screenHeadroom: Float, maxPixelSize: Int?) -> (hdr: NSImage?, sdr: NSImage?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return (NSImage(contentsOfFile: filePath), nil) }

        // Override color space to BT.2100 HLG (the container lies about BT.709)
        guard let hlgSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else {
            return (NSImage(contentsOfFile: filePath), nil)
        }
        var ciImage = CIImage(cgImage: cgImage, options: [.colorSpace: hlgSpace])

        // Apply EXIF orientation
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let rawOrientation = props[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) {
            ciImage = ciImage.oriented(orientation)
        }

        ciImage = downsampleIfNeeded(ciImage, maxPixelSize: maxPixelSize)

        let hdr = renderHDRCIImage(ciImage, screenHeadroom: screenHeadroom, clipToSDR: false)
        let sdr = renderHDRCIImage(ciImage, screenHeadroom: screenHeadroom, clipToSDR: true)
        return (hdr, sdr)
    }
}

// MARK: - SonyPPDetector

enum SonyPPDetector {
    /// PP values that represent HLG variants (container mislabeled as BT.709)
    private static let hlgPPValues: Set<Int> = [32, 33, 34, 35]

    /// PP values that represent S-Log variants
    private static let slogPPValues: Set<Int> = [28, 31]

    /// All PP values this detector handles
    private static let supportedPPValues = hlgPPValues.union(slogPPValues)

    /// Detect a Sony PP file and return a configured SonyPPRenderSpec, or nil.
    /// Called after the standard hdrRenderSpecs loop fails to match.
    static func detect(url: URL) -> SonyPPRenderSpec? {
        guard let ppValue = SonyMakerNoteParser.extractPictureProfileRawValue(from: url),
              supportedPPValues.contains(ppValue)
        else { return nil }

        let badge: String
        switch ppValue {
        case 32: badge = "HLG1"
        case 33: badge = "HLG2"
        case 34: badge = "HLG3"
        case 35: badge = "HLG"
        case 31: badge = "S-Log3"
        case 28: badge = "S-Log2"
        default: return nil
        }

        return SonyPPRenderSpec(badgeLabel: badge, profileValue: ppValue)
    }
}
