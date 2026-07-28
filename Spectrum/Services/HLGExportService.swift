import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Exports HLG images to SDR JPEG using System ColorSync + Sony-calibrated 1D LUT.
///
/// Pipeline:
///   1. CGContext draw with perceptual intent (ColorSync BT.2100 HLG → sRGB)
///   2. Per-channel 256-entry 1D LUT calibrated against Sony Image Edge Edit output
///   3. Write JPEG
///
/// LUT calibrated on DSC00513 (ZV-E1), cross-validated on DSC02917 (MAE 21.4 → 4.3).
struct HLGExportService {

    // MARK: - Sony-calibrated 1D LUT

    private static let lr: [UInt8] = [6,5,4,3,2,2,3,4,5,6,7,8,9,10,11,13,14,16,18,20,22,24,26,28,30,32,34,36,37,39,40,42,43,45,47,48,50,51,53,55,56,58,60,61,63,65,67,68,70,72,73,75,76,78,80,81,83,84,86,87,89,91,93,94,96,98,100,101,103,105,107,109,110,112,114,115,117,118,120,122,123,125,126,128,129,130,131,132,134,135,136,137,139,140,141,143,144,145,146,148,149,150,151,152,154,155,156,157,158,159,160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179,180,181,182,183,184,185,185,186,187,188,189,190,191,191,192,193,194,194,195,196,196,196,197,197,197,197,198,199,199,200,200,201,201,202,202,203,203,204,205,206,207,208,209,210,210,211,212,212,213,213,214,214,215,215,216,217,217,218,218,219,219,220,221,222,222,223,223,224,225,226,227,227,228,229,229,230,231,232,233,234,234,235,236,236,237,238,239,239,240,241,241,242,242,243,243,243,243,243,244,244,244,245,245,245,246,246,247,247,248,248,248,249,249,249,249,250,250,251,251,252,252,252,253,253,254,253]
    private static let lg: [UInt8] = [0,0,1,1,1,2,2,3,4,5,6,7,8,9,10,12,13,15,16,18,20,22,23,25,27,28,30,32,34,35,37,39,41,43,44,46,48,50,51,53,55,56,58,60,61,63,65,67,68,70,72,74,75,77,79,80,82,83,85,87,88,90,92,93,95,96,98,100,101,103,104,106,108,109,111,112,114,115,117,118,120,121,123,124,126,127,128,130,131,133,134,135,137,138,140,141,142,144,145,146,148,149,150,151,153,154,155,156,158,159,160,161,162,163,164,165,166,168,169,170,171,172,173,174,175,176,177,178,179,180,181,182,183,183,184,185,186,187,188,189,190,191,192,192,193,194,195,195,196,197,198,198,199,200,201,202,202,203,204,205,206,207,207,208,209,209,210,211,211,212,213,213,214,214,214,215,215,216,216,217,217,218,218,219,219,220,220,221,221,222,222,223,223,223,224,224,225,226,226,227,228,228,229,230,231,232,233,234,236,237,238,238,239,239,240,240,241,241,242,243,243,244,244,244,244,245,245,245,245,245,245,245,246,246,246,247,247,247,248,249,249,250,251,251,251,251,252,252,253,253,253,253,253,254,254,255]
    private static let lb: [UInt8] = [0,0,1,1,1,2,2,3,3,4,5,6,7,8,9,11,12,14,16,18,20,21,23,24,25,27,28,30,32,33,35,37,39,41,43,45,46,48,50,52,53,55,57,58,60,62,64,65,67,69,71,72,74,75,77,79,80,82,83,85,87,88,90,92,93,95,96,98,100,101,103,104,106,107,109,110,112,114,115,117,118,120,121,123,125,126,128,129,131,133,134,136,137,138,140,141,143,144,146,147,149,150,151,152,154,155,156,157,158,159,160,162,163,164,165,166,168,169,170,171,172,173,174,175,176,177,178,180,181,182,183,184,184,185,186,187,188,189,190,191,192,192,193,194,195,196,197,198,198,199,200,200,201,202,203,203,204,205,205,206,206,207,208,209,209,210,211,211,212,213,213,214,214,215,215,216,216,217,217,218,218,219,219,220,220,221,221,222,223,223,224,224,225,226,226,226,227,228,228,229,229,230,230,231,231,232,232,233,233,234,234,235,235,236,236,237,238,238,239,239,240,240,241,241,242,242,243,244,245,245,246,246,247,247,248,249,250,250,250,251,251,251,252,252,252,252,252,252,251,252,252,252,253,254,254,255]

    // MARK: - Public API

    /// Export HLG image to SDR JPEG at the given URL.
    static func exportAsJPEG(hlgCGImage: CGImage, to url: URL, compressionQuality: Float = 0.95) -> Bool {
        guard let sdr = renderSDR(hlgCGImage: hlgCGImage) else { return false }
        return writeJPEG(sdr, to: url, quality: compressionQuality)
    }

    /// Render HLG CGImage to SDR pixel buffer (8-bit sRGB).
    static func renderSDR(hlgCGImage: CGImage) -> CGImage? {
        let w = hlgCGImage.width, h = hlgCGImage.height
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

        // Step 1: CGContext perceptual draw
        var pixelData = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixelData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setRenderingIntent(.perceptual)
        ctx.draw(hlgCGImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Step 2: Apply Sony-calibrated 1D LUT
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            pixelData[i] = lr[Int(pixelData[i])]
            pixelData[i+1] = lg[Int(pixelData[i+1])]
            pixelData[i+2] = lb[Int(pixelData[i+2])]
        }

        // Step 3: Build CGImage
        guard let provider = CGDataProvider(data: Data(pixelData) as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - Private

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: Float) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        let props: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        return CGImageDestinationFinalize(dest)
    }
}
