import AppKit
import CoreImage
import ImageIO

struct HLGHDRSpec: HDRRenderSpec {
    let badgeLabel = "HLG"
    let needsPrerenderedSDR = true

    func detect(source: CGImageSource, url: URL) -> Bool {
        guard let ciImage = CIImage(contentsOf: url),
              let colorSpace = ciImage.colorSpace else { return false }
        return CGColorSpaceUsesITUR_2100TF(colorSpace)
    }

    func render(url: URL, filePath: String, screenHeadroom: Float, maxPixelSize: Int? = nil, hlgToneMapMode: HLGToneMapMode = .iccTRC) -> (hdr: NSImage?, sdr: NSImage?) {
        // ICC TRC mode: bypass Apple's HLG decode, use Sony's exact TRC curve
        if hlgToneMapMode == .iccTRC {
            return renderWithICCTRC(url: url, filePath: filePath, screenHeadroom: screenHeadroom, maxPixelSize: maxPixelSize)
        }

        // Both HDR and SDR: CIImage → shared pipeline
        guard var ciImage = CIImage(contentsOf: url) else { return (nil, nil) }

        // Apply EXIF orientation
        if let orientationValue = ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: orientationValue) {
            ciImage = ciImage.oriented(orientation)
        }

        ciImage = downsampleIfNeeded(ciImage, maxPixelSize: maxPixelSize)

        let hdr = renderHLGToneMapped(ciImage, mode: hlgToneMapMode, screenHeadroom: screenHeadroom, clipToSDR: false)
        let sdr = renderHLGToneMapped(ciImage, mode: hlgToneMapMode, screenHeadroom: screenHeadroom, clipToSDR: true)
        return (hdr, sdr)
    }

    func dynamicRange(showHDR: Bool) -> NSImage.DynamicRange {
        showHDR ? .high : .standard
    }
}
