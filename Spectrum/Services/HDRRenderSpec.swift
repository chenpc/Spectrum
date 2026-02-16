import AppKit
import CoreImage
import ImageIO

protocol HDRRenderSpec {
    /// Badge display text, e.g. "HDR", "HLG"
    var badgeLabel: String { get }

    /// Whether SDR needs a pre-rendered image (vs toggling dynamicRange)
    var needsPrerenderedSDR: Bool { get }

    /// Detect whether the image at this URL matches this spec
    func detect(source: CGImageSource, url: URL) -> Bool

    /// Render HDR and optional SDR versions
    /// - sdr is nil when SDR is controlled by NSImageView dynamicRange
    func render(url: URL, filePath: String, screenHeadroom: Float) -> (hdr: NSImage?, sdr: NSImage?)

    /// NSImageView dynamic range for the given HDR toggle state
    func dynamicRange(showHDR: Bool) -> NSImage.DynamicRange
}

// MARK: - Shared CIImage rendering pipeline

/// Tone-map a scene-referred HDR CIImage (HLG/PQ) and render to NSImage.
///
/// Pipeline:
/// 1. CIToneMapHeadroom — OOTF for display's EDR capability
/// 2. Saturation boost — compensates BT.2020→P3 gamut mapping
/// 3. Render to target format:
///    - clipToSDR == true  → displayP3 + RGBA8 (hard clips values > 1.0)
///    - clipToSDR == false → extendedDisplayP3 + RGBAh (preserves EDR headroom)
///
/// NOTE: This only works for images whose CIImage pixel values are truly
/// scene-referred HDR (HLG, PQ). Gain-map images store HDR as auxiliary
/// data — CIImage only sees the SDR base — so they cannot use this pipeline.
func renderHDRCIImage(
    _ ciImage: CIImage,
    screenHeadroom: Float,
    saturationBoost: Float = 1.12,
    clipToSDR: Bool
) -> NSImage? {
    var processed = ciImage

    if #available(macOS 15.0, *) {
        let targetHeadroom: Float = clipToSDR ? 1.0 : max(screenHeadroom, 1.0)
        processed = processed.applyingFilter("CIToneMapHeadroom", parameters: [
            "inputTargetHeadroom": targetHeadroom
        ])
    }

    processed = processed.applyingFilter("CIColorControls", parameters: [
        "inputSaturation": saturationBoost
    ])

    let ctx = CIContext()
    if clipToSDR {
        guard let outputSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let cgImage = ctx.createCGImage(
                  processed, from: processed.extent,
                  format: .RGBA8, colorSpace: outputSpace
              )
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    } else {
        guard let outputSpace = CGColorSpace(name: CGColorSpace.extendedDisplayP3),
              let cgImage = ctx.createCGImage(
                  processed, from: processed.extent,
                  format: .RGBAh, colorSpace: outputSpace
              )
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Registered specs — detection order matters (first match wins)
let hdrRenderSpecs: [any HDRRenderSpec] = [
    HLGHDRSpec(),
    GainMapHDRSpec(),
]
