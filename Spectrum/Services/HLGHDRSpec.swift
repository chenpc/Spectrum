import AppKit
import CoreImage
import ImageIO

struct HLGHDRSpec: HDRRenderSpec {
    let badgeLabel = "HLG"
    let needsPrerenderedSDR = true

    /// Tunable: BT.2020→P3 gamut mapping loses some punch
    let saturationBoost: Float = 1.12

    func detect(source: CGImageSource, url: URL) -> Bool {
        guard let ciImage = CIImage(contentsOf: url),
              let colorSpace = ciImage.colorSpace else { return false }
        return CGColorSpaceUsesITUR_2100TF(colorSpace)
    }

    func render(url: URL, filePath: String, screenHeadroom: Float) -> (hdr: NSImage?, sdr: NSImage?) {
        // Both HDR and SDR: CIImage → shared pipeline
        guard var ciImage = CIImage(contentsOf: url) else { return (nil, nil) }

        // Apply EXIF orientation
        if let orientationValue = ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: orientationValue) {
            ciImage = ciImage.oriented(orientation)
        }

        let hdr = renderHDRCIImage(ciImage, screenHeadroom: screenHeadroom, saturationBoost: saturationBoost, clipToSDR: false)
        let sdr = renderHDRCIImage(ciImage, screenHeadroom: screenHeadroom, saturationBoost: saturationBoost, clipToSDR: true)
        return (hdr, sdr)
    }

    func dynamicRange(showHDR: Bool) -> NSImage.DynamicRange {
        showHDR ? .high : .standard
    }
}
