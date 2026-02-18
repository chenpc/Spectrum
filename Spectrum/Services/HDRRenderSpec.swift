import AppKit
import CoreImage
import ImageIO

// MARK: - HLG Tone Map Modes

enum HLGToneMapMode: String, CaseIterable, Identifiable, Sendable {
    case appleToneMap = "Apple ToneMap"
    case bt2100OOTF = "BT.2100 OOTF"
    case toneMapWithLift = "ToneMap + Lift"
    case iccOOTF = "ICC OOTF"
    case iccTRC = "ICC TRC"

    var id: String { rawValue }
}

protocol HDRRenderSpec {
    /// Badge display text, e.g. "HDR", "HLG"
    var badgeLabel: String { get }

    /// Whether SDR needs a pre-rendered image (vs toggling dynamicRange)
    var needsPrerenderedSDR: Bool { get }

    /// Detect whether the image at this URL matches this spec
    func detect(source: CGImageSource, url: URL) -> Bool

    /// Render HDR and optional SDR versions
    /// - sdr is nil when SDR is controlled by NSImageView dynamicRange
    /// - maxPixelSize: if set, downsample before rendering (for preload/display performance)
    /// - hlgToneMapMode: tone mapping mode (only affects HLG-based specs)
    func render(url: URL, filePath: String, screenHeadroom: Float, maxPixelSize: Int?, hlgToneMapMode: HLGToneMapMode) -> (hdr: NSImage?, sdr: NSImage?)

    /// NSImageView dynamic range for the given HDR toggle state
    func dynamicRange(showHDR: Bool) -> NSImage.DynamicRange
}

// MARK: - Shared CIImage rendering pipeline

/// Tone-map a scene-referred HDR CIImage (HLG/PQ) and render to NSImage.
///
/// Pipeline:
/// 1. CIToneMapHeadroom — OOTF for display's EDR capability
/// 2. Saturation boost — compensates BT.2020→P3 gamut mapping (default 1.12)
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
    saturationBoost: Float = 1.0,
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

// MARK: - HLG tone map mode dispatcher

/// Render an HLG CIImage using the specified tone mapping mode.
func renderHLGToneMapped(
    _ ciImage: CIImage,
    mode: HLGToneMapMode,
    screenHeadroom: Float,
    saturationBoost: Float = 1.12,
    clipToSDR: Bool
) -> NSImage? {
    switch mode {
    case .appleToneMap:
        return renderHDRCIImage(ciImage, screenHeadroom: screenHeadroom, saturationBoost: saturationBoost, clipToSDR: clipToSDR)
    case .bt2100OOTF:
        return renderBT2100OOTF(ciImage, screenHeadroom: screenHeadroom, saturationBoost: saturationBoost, clipToSDR: clipToSDR)
    case .toneMapWithLift:
        return renderToneMapWithLift(ciImage, screenHeadroom: screenHeadroom, saturationBoost: saturationBoost, clipToSDR: clipToSDR)
    case .iccOOTF:
        return renderICCOOTF(ciImage, screenHeadroom: screenHeadroom, saturationBoost: saturationBoost, clipToSDR: clipToSDR)
    case .iccTRC:
        return nil // Must be handled by caller — requires re-loading with linearSRGB
    }
}

// MARK: - Mode B: BT.2100 OOTF

/// Standard BT.2100 OOTF via CIFilter chain.
///
/// Pipeline:
/// 1. Extract BT.2020 luminance Y_s per pixel (CIColorMatrix)
/// 2. Compute gain = Y_s^(γ-1) (CIGammaAdjust)
/// 3. Multiply original by gain → OOTF result (CIMultiplyCompositing)
/// 4. Saturation boost + render
///
/// System gamma γ = 1.2 + 0.42 × log10(L_W / 1000)
/// where L_W = screenHeadroom × 203 (HLG reference white nits)
private func renderBT2100OOTF(
    _ ciImage: CIImage,
    screenHeadroom: Float,
    saturationBoost: Float = 1.12,
    clipToSDR: Bool
) -> NSImage? {
    // Calculate system gamma based on display peak luminance
    let lw = Double(clipToSDR ? 1.0 : max(screenHeadroom, 1.0)) * 203.0
    let gamma = 1.2 + 0.42 * log10(lw / 1000.0)

    // Step 1: Extract BT.2020 luminance → R=G=B=Y_s
    let luminance = ciImage.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.2627, y: 0.2627, z: 0.2627, w: 0),
        "inputGVector": CIVector(x: 0.6780, y: 0.6780, z: 0.6780, w: 0),
        "inputBVector": CIVector(x: 0.0593, y: 0.0593, z: 0.0593, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
    ])

    // Step 2: Y_s^(gamma-1)
    let gain = luminance.applyingFilter("CIGammaAdjust", parameters: [
        "inputPower": gamma - 1.0
    ])

    // Step 3: Multiply original RGB by gain → F_d = Y_s^(γ-1) × E_s
    var processed = ciImage.applyingFilter("CIMultiplyCompositing", parameters: [
        "inputBackgroundImage": gain
    ])

    // Saturation boost
    processed = processed.applyingFilter("CIColorControls", parameters: [
        "inputSaturation": saturationBoost
    ])

    return renderCIImageToNSImage(processed, clipToSDR: clipToSDR)
}

// MARK: - Mode C: CIToneMapHeadroom + midtone lift

/// Apple CIToneMapHeadroom followed by a gamma lift to brighten midtones
/// and compress highlights — closer to Sony IEDT behavior.
///
/// CIGammaAdjust(power: 0.85) applies x^0.85:
///   0.2 → 0.235 (+17%), 0.5 → 0.553 (+10%), 1.0 → 1.0, 2.0 → 1.81 (compressed)
private func renderToneMapWithLift(
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

    // Gamma lift: brightens midtones, slightly compresses highlights > 1.0
    processed = processed.applyingFilter("CIGammaAdjust", parameters: [
        "inputPower": 0.85
    ])

    processed = processed.applyingFilter("CIColorControls", parameters: [
        "inputSaturation": saturationBoost
    ])

    return renderCIImageToNSImage(processed, clipToSDR: clipToSDR)
}

// MARK: - Mode D: ICC-based per-channel OOTF

/// Per-channel gamma derived from Sony's BT.2100 HLG ICC profile analysis.
///
/// The ICC profile TRC = inverse_OETF(signal) ^ (1/1.2), converting HLG signal
/// to scene-referred linear by removing the reference OOTF (γ_ref = 1.2 at 1000 nits).
/// For display, reapply OOTF adapted to actual display luminance:
///
///   output = input ^ (γ_display / γ_ref)
///
/// Unlike BT.2100 OOTF (Mode B) which uses luminance-dependent per-pixel gain,
/// this applies a uniform per-channel power — matching how ICC color management works.
/// Results in smoother highlight rolloff and brighter midtones.
private func renderICCOOTF(
    _ ciImage: CIImage,
    screenHeadroom: Float,
    saturationBoost: Float = 1.12,
    clipToSDR: Bool
) -> NSImage? {
    let gammaRef = 1.2
    let lw = Double(clipToSDR ? 1.0 : max(screenHeadroom, 1.0)) * 203.0
    let gammaDisplay = 1.2 + 0.42 * log10(lw / 1000.0)
    let power = gammaDisplay / gammaRef

    var processed = ciImage.applyingFilter("CIGammaAdjust", parameters: [
        "inputPower": power
    ])

    processed = processed.applyingFilter("CIColorControls", parameters: [
        "inputSaturation": saturationBoost
    ])

    return renderCIImageToNSImage(processed, clipToSDR: clipToSDR)
}

// MARK: - Shared final render step

/// Render a processed CIImage to NSImage in the appropriate format.
private func renderCIImageToNSImage(_ processed: CIImage, clipToSDR: Bool) -> NSImage? {
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

/// Downsample a CIImage if it exceeds maxPixelSize on its longest side.
func downsampleIfNeeded(_ image: CIImage, maxPixelSize: Int?) -> CIImage {
    guard let maxSize = maxPixelSize else { return image }
    let w = image.extent.width
    let h = image.extent.height
    let longest = max(w, h)
    guard longest > CGFloat(maxSize) else { return image }
    let scale = CGFloat(maxSize) / longest
    return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
}

/// Registered specs — detection order matters (first match wins)
let hdrRenderSpecs: [any HDRRenderSpec] = [
    HLGHDRSpec(),
    GainMapHDRSpec(),
]

// MARK: - Mode E: ICC TRC (exact Sony HLG profile curve)

/// Sony's BT.2100 HLG ICC profile data and derived constants.
///
/// The ICC profile (sony_HLG.icc) contains BT.2020 primaries and a 1024-point
/// TRC that maps HLG signal [0,1] → scene-referred linear with the reference
/// OOTF (γ=1.2) removed: TRC = inverse_OETF(signal)^(1/1.2).
///
/// Using `CGColorSpace(iccData:)` lets Core Image apply the TRC + gamut
/// conversion natively — no manual CIColorCube LUT needed.
enum ICCTRCData {
    /// ICC profile data loaded from app bundle resource
    private static let iccData: Data? = {
        guard let url = Bundle.main.url(forResource: "sony_HLG", withExtension: "icc"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return data
    }()

    /// CGColorSpace created from the Sony ICC profile.
    /// CI uses this to apply TRC + gamut conversion natively.
    static let colorSpace: CGColorSpace? = {
        guard let data = iccData else { return nil }
        return CGColorSpace(iccData: data as CFData)
    }()

    /// EDR scale: maps HLG reference white (75% signal) to 1.0 in display buffer.
    ///
    /// The ICC TRC maps 75% signal → ~0.3265 linear. For HDR display, values > 1.0
    /// represent highlights brighter than reference white. Scale = 1/TRC(0.75) ≈ 3.06.
    ///
    /// Parsed from the ICC profile's rTRC tag (1024 × uint16 big-endian curve).
    static let edrScaleFactor: Float = {
        guard let data = iccData else { return 3.0 }
        let trcOffset = 576 + 12  // rTRC tag data offset (skip 'curv' header)
        let trcCount = 1024
        guard data.count >= trcOffset + trcCount * 2 else { return 3.0 }

        let idx = Int(0.75 * Float(trcCount - 1))  // index 767
        let byteOffset = trcOffset + idx * 2
        let hi = UInt16(data[byteOffset]) << 8
        let lo = UInt16(data[byteOffset + 1])
        let trcValue = Float(hi | lo) / 65535.0
        guard trcValue > 0 else { return 3.0 }
        return 1.0 / trcValue
    }()
}

/// Render HLG image using Sony's BT.2100 HLG ICC profile + EDR scaling + tone mapping.
///
/// Pipeline:
/// 1. CGColorSpace(iccData:) — Sony's exact TRC + BT.2020 gamut (CI native)
/// 2. EDR scale ×3.06 — reference white (75% signal) → 1.0, highlights → >1.0
/// 3. CIToneMapHeadroom — Apple's HDR tone mapping for the display
/// 4. HDR: extendedLinearITUR_2020 / RGBAh — preserves full BT.2020 gamut
///    SDR: displayP3 / RGBA8 — hard clips values > 1.0
func renderWithICCTRC(
    url: URL,
    filePath: String,
    screenHeadroom: Float,
    maxPixelSize: Int?
) -> (hdr: NSImage?, sdr: NSImage?) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return (NSImage(contentsOfFile: filePath), nil) }

    guard let sonyCS = ICCTRCData.colorSpace else {
        return (NSImage(contentsOfFile: filePath), nil)
    }

    // Sony ICC profile as input color space: CI applies TRC + gamut natively
    var ciImage = CIImage(cgImage: cgImage, options: [.colorSpace: sonyCS])

    // EXIF orientation
    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
       let rawOrientation = props[kCGImagePropertyOrientation as String] as? UInt32,
       let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) {
        ciImage = ciImage.oriented(orientation)
    }

    ciImage = downsampleIfNeeded(ciImage, maxPixelSize: maxPixelSize)

    // EDR scale: reference white → 1.0, highlights → >1.0
    let scale = CGFloat(ICCTRCData.edrScaleFactor)
    ciImage = ciImage.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
    ])

    // CIToneMapHeadroom for HDR and SDR
    var hdrImage = ciImage
    var sdrImage = ciImage
    if #available(macOS 15.0, *) {
        hdrImage = hdrImage.applyingFilter("CIToneMapHeadroom", parameters: [
            "inputTargetHeadroom": max(screenHeadroom, 1.0)
        ])
        sdrImage = sdrImage.applyingFilter("CIToneMapHeadroom", parameters: [
            "inputTargetHeadroom": 1.0
        ])
    }

    let ctx = CIContext()

    // HDR: BT.2020 extended linear — preserves full source gamut
    let hdr: NSImage?
    if let outputSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
       let cgImg = ctx.createCGImage(hdrImage, from: hdrImage.extent,
                                      format: .RGBAh, colorSpace: outputSpace) {
        hdr = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    } else {
        hdr = nil
    }

    // SDR: displayP3 / RGBA8 — clips values > 1.0
    let sdr: NSImage?
    if let outputSpace = CGColorSpace(name: CGColorSpace.displayP3),
       let cgImg = ctx.createCGImage(sdrImage, from: sdrImage.extent,
                                      format: .RGBA8, colorSpace: outputSpace) {
        sdr = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    } else {
        sdr = nil
    }

    return (hdr, sdr)
}
