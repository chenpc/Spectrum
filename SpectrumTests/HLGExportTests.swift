import XCTest
import CoreImage
import ImageIO
import AppKit
import UniformTypeIdentifiers
import Accelerate

/// Experiment: compare different HLG→SDR tone mapping approaches against Sony Image Edge output.
/// Reference: /Users/chenpc/Desktop/DSC00513.JPG (Sony Image Edge export)
/// Source:    /Users/chenpc/Desktop/DSC00513.HIF (Sony HLG)
final class HLGExportTests: XCTestCase {

    let sourcePath = "/Users/chenpc/Desktop/DSC00513.HIF"
    let referencePath = "/Users/chenpc/Desktop/DSC00513.JPG"
    let outputDir = "/tmp/hlg_export_experiments"

    // MARK: - Approaches

    struct ApproachResult {
        let name: String
        let image: CGImage
        let mae: Double   // mean absolute error vs reference
        let psnr: Double  // peak signal-to-noise ratio
    }

    func testCompareAllApproaches() throws {
        guard let hlgImage = loadHLGImage(path: sourcePath) else {
            XCTFail("Cannot load HLG source at \(sourcePath)"); return
        }
        guard let refImage = loadReferenceImage(path: referencePath) else {
            XCTFail("Cannot load reference at \(referencePath)"); return
        }

        // Downscale to 1/4 for faster processing
        let scaleFactor = 0.5
        let smallW = Int(CGFloat(hlgImage.width) * scaleFactor)
        let smallH = Int(CGFloat(hlgImage.height) * scaleFactor)
        guard let smallHLG = resizeCGImage(hlgImage, w: smallW, h: smallH),
              let smallRef = resizeCGImage(refImage, w: smallW, h: smallH) else {
            XCTFail("Cannot downscale images"); return
        }

        // Ensure output dir
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outputDir),
                                                  withIntermediateDirectories: true)


        var results: [ApproachResult] = []

        // Approach: Gamma series (BT.2020→sRGB gamut + pow(1/γ))
        for gamma in stride(from: 1.0, through: 2.5, by: 0.25) {
            if let img = renderGamutGamma(smallHLG, gamma: Float(gamma)) {
                let mae = computeMAE(img, reference: smallRef)
                let psnr = computePSNR(img, reference: smallRef)
                saveDebug(img, name: String(format: "gamut_gamma_%.2f", gamma))
                results.append(ApproachResult(name: String(format: "gamut γ=%.2f", gamma),
                                              image: img, mae: mae, psnr: psnr))
            }
        }

        // Approach: Full HLG decode (inv OETF → OOTF γ → gamut → sRGB γ)
        for gamma in stride(from: 1.0, through: 2.0, by: 0.25) {
            if let img = renderFullHLG(smallHLG, ootfGamma: Float(gamma)) {
                let mae = computeMAE(img, reference: smallRef)
                let psnr = computePSNR(img, reference: smallRef)
                saveDebug(img, name: String(format: "full_ootf_%.2f", gamma))
                results.append(ApproachResult(name: String(format: "full OOTF γ=%.2f", gamma),
                                              image: img, mae: mae, psnr: psnr))
            }
        }

        // Approach: CGContext with perceptual intent
        if let img = renderCGContext(smallHLG) {
            let mae = computeMAE(img, reference: smallRef)
            let psnr = computePSNR(img, reference: smallRef)
            saveDebug(img, name: "cgcontext_perceptual")
            results.append(ApproachResult(name: "CGContext perceptual",
                                          image: img, mae: mae, psnr: psnr))
        }

        // Approach: CGContext perceptual + brightness scaling
        for scale in stride(from: 1.3, through: 1.6, by: 0.05) {
            if let img = renderCGContextWithBrightness(smallHLG, scale: Float(scale)) {
                let mae = computeMAE(img, reference: smallRef)
                let psnr = computePSNR(img, reference: smallRef)
                saveDebug(img, name: String(format: "cgcontext_scale_%.2f", scale))
                results.append(ApproachResult(name: String(format: "CGContext ×%.2f", scale),
                                              image: img, mae: mae, psnr: psnr))
            }
        }

        // Approach: Full HLG decode with Reinhard tone mapping
        for gamma in stride(from: 1.0, through: 2.0, by: 0.5) {
            if let img = renderFullHLGWithTonemap(smallHLG, ootfGamma: Float(gamma)) {
                let mae = computeMAE(img, reference: smallRef)
                let psnr = computePSNR(img, reference: smallRef)
                saveDebug(img, name: String(format: "full_reinhard_%.2f", gamma))
                results.append(ApproachResult(name: String(format: "full+Reinhard γ=%.2f", gamma),
                                              image: img, mae: mae, psnr: psnr))
            }
        }

        // Sort by MAE (lower = better)
        results.sort { $0.mae < $1.mae }

        print("\n========== HLG Export Comparison Results ==========")
        print(String(format: "Reference: %@ (%dx%d)", referencePath, refImage.width, refImage.height))
        print(String(format: "Source:    %@ (%dx%d)", sourcePath, hlgImage.width, hlgImage.height))
        print(String(format: "Downscaled to %dx%d for comparison", smallW, smallH))
        print("")
        let padName = "Approach".padding(toLength: 28, withPad: " ", startingAt: 0)
        let padMAE = "MAE".padding(toLength: 8, withPad: " ", startingAt: 0)
        let padPSNR = "PSNR".padding(toLength: 6, withPad: " ", startingAt: 0)
        print("  \(padName) \(padMAE) \(padPSNR)")
        let sepName = String(repeating: "-", count: 28)
        let sepMAE = String(repeating: "-", count: 8)
        let sepPSNR = String(repeating: "-", count: 6)
        print("  \(sepName) \(sepMAE) \(sepPSNR)")
        for r in results {
            print("  \(r.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(String(format: "%8.4f", r.mae))  \(String(format: "%6.1f", r.psnr))dB")
        }
        print("==================================================")

        // Best result
        if let best = results.first {
            print("  Best: \(best.name) (MAE=\(String(format: "%.4f", best.mae)), PSNR=\(String(format: "%.1f", best.psnr))dB)")
        }
    }

    // MARK: - Rendering Approaches

    /// Simple gamut conversion: BT.2020→sRGB primaries + gamma adjustment.
    /// No inverse OETF, no OOTF — treats HLG pixel values as SDR-compatible.
    private func renderGamutGamma(_ hlgImage: CGImage, gamma: Float) -> CGImage? {
        let source = """
        kernel vec4 gamutGamma(__sample s, float g) {
            float3 srgb;
            srgb.r = 1.660444 * s.r - 0.587562 * s.g - 0.072882 * s.b;
            srgb.g = -0.124557 * s.r + 1.132852 * s.g - 0.008295 * s.b;
            srgb.b = -0.018200 * s.r - 0.100561 * s.g + 1.118679 * s.b;
            if (g != 1.0) {
                srgb.r = pow(max(srgb.r, 0.0), 1.0 / g);
                srgb.g = pow(max(srgb.g, 0.0), 1.0 / g);
                srgb.b = pow(max(srgb.b, 0.0), 1.0 / g);
            }
            return vec4(clamp(srgb, 0.0, 1.0), s.a);
        }
        """
        guard let kernel = CIColorKernel(source: source) else { return nil }
        let ciImage = CIImage(cgImage: hlgImage)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = kernel.apply(extent: ciImage.extent, arguments: [ciImage, gamma]) else { return nil }
        let ctx = CIContext(options: [.outputColorSpace: sRGB])
        return ctx.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Full HLG decode pipeline: inv OETF → OOTF → BT.2020→sRGB → sRGB gamma.
    private func renderFullHLG(_ hlgImage: CGImage, ootfGamma: Float) -> CGImage? {
        let source = """
        kernel vec4 fullHLG(__sample s, float g) {
            const float a = 0.17883277, b = 0.28466892, c = 0.55991073;

            // 1. Inverse HLG OETF
            float3 lin;
            lin.r = s.r <= 0.5 ? s.r * s.r / 3.0 : (exp((s.r - c) / a) + b) / 12.0;
            lin.g = s.g <= 0.5 ? s.g * s.g / 3.0 : (exp((s.g - c) / a) + b) / 12.0;
            lin.b = s.b <= 0.5 ? s.b * s.b / 3.0 : (exp((s.b - c) / a) + b) / 12.0;

            // 2. OOTF (luminance-dependent scaling)
            float Ys = max(0.001, dot(lin, float3(0.2627, 0.6780, 0.0593)));
            float scale = pow(Ys, g - 1.0);
            lin *= scale;

            // 3. BT.2020 → sRGB primaries
            float3 srgb;
            srgb.r = 1.660444 * lin.r - 0.587562 * lin.g - 0.072882 * lin.b;
            srgb.g = -0.124557 * lin.r + 1.132852 * lin.g - 0.008295 * lin.b;
            srgb.b = -0.018200 * lin.r - 0.100561 * lin.g + 1.118679 * lin.b;

            // 4. sRGB gamma
            float3 result;
            result.r = srgb.r <= 0.0031308 ? srgb.r * 12.92 : 1.055 * pow(srgb.r, 1.0/2.4) - 0.055;
            result.g = srgb.g <= 0.0031308 ? srgb.g * 12.92 : 1.055 * pow(srgb.g, 1.0/2.4) - 0.055;
            result.b = srgb.b <= 0.0031308 ? srgb.b * 12.92 : 1.055 * pow(srgb.b, 1.0/2.4) - 0.055;

            return vec4(clamp(result, 0.0, 1.0), s.a);
        }
        """
        guard let kernel = CIColorKernel(source: source) else { return nil }
        let ciImage = CIImage(cgImage: hlgImage)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = kernel.apply(extent: ciImage.extent, arguments: [ciImage, ootfGamma]) else { return nil }
        let ctx = CIContext(options: [.outputColorSpace: sRGB])
        return ctx.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Full HLG decode + Reinhard tone mapping.
    private func renderFullHLGWithTonemap(_ hlgImage: CGImage, ootfGamma: Float) -> CGImage? {
        let source = """
        kernel vec4 fullHLGTonemap(__sample s, float g) {
            const float a = 0.17883277, b = 0.28466892, c = 0.55991073;

            // 1. Inverse HLG OETF
            float3 lin;
            lin.r = s.r <= 0.5 ? s.r * s.r / 3.0 : (exp((s.r - c) / a) + b) / 12.0;
            lin.g = s.g <= 0.5 ? s.g * s.g / 3.0 : (exp((s.g - c) / a) + b) / 12.0;
            lin.b = s.b <= 0.5 ? s.b * s.b / 3.0 : (exp((s.b - c) / a) + b) / 12.0;

            // 2. OOTF
            float Ys = max(0.001, dot(lin, float3(0.2627, 0.6780, 0.0593)));
            float scale = pow(Ys, g - 1.0);
            lin *= scale;

            // 3. BT.2020 → sRGB primaries
            float3 srgb;
            srgb.r = 1.660444 * lin.r - 0.587562 * lin.g - 0.072882 * lin.b;
            srgb.g = -0.124557 * lin.r + 1.132852 * lin.g - 0.008295 * lin.b;
            srgb.b = -0.018200 * lin.r - 0.100561 * lin.g + 1.118679 * lin.b;

            // 4. Reinhard tone mapping
            float3 tm;
            tm.r = srgb.r / (srgb.r + 1.0);
            tm.g = srgb.g / (srgb.g + 1.0);
            tm.b = srgb.b / (srgb.b + 1.0);

            // 5. sRGB gamma
            float3 result;
            result.r = tm.r <= 0.0031308 ? tm.r * 12.92 : 1.055 * pow(tm.r, 1.0/2.4) - 0.055;
            result.g = tm.g <= 0.0031308 ? tm.g * 12.92 : 1.055 * pow(tm.g, 1.0/2.4) - 0.055;
            result.b = tm.b <= 0.0031308 ? tm.b * 12.92 : 1.055 * pow(tm.b, 1.0/2.4) - 0.055;

            return vec4(clamp(result, 0.0, 1.0), s.a);
        }
        """
        guard let kernel = CIColorKernel(source: source) else { return nil }
        let ciImage = CIImage(cgImage: hlgImage)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = kernel.apply(extent: ciImage.extent, arguments: [ciImage, ootfGamma]) else { return nil }
        let ctx = CIContext(options: [.outputColorSpace: sRGB])
        return ctx.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Render via CGContext with perceptual rendering intent.
    private func renderCGContext(_ hlgImage: CGImage) -> CGImage? {
        let w = hlgImage.width, h = hlgImage.height
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setRenderingIntent(.perceptual)
        ctx.draw(hlgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// CGContext perceptual + brightness scaling via vImage.
    private func renderCGContextWithBrightness(_ hlgImage: CGImage, scale: Float) -> CGImage? {
        let w = hlgImage.width, h = hlgImage.height
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let base = renderCGContext(hlgImage) else { return nil }
        let baseData = base.dataProvider?.data
        guard let ptr = CFDataGetBytePtr(baseData) else { return nil }
        let len = CFDataGetLength(baseData)
        var scaled = [UInt8](repeating: 0, count: len)
        let s = UInt32(min(Int(scale * 256 + 0.5), 65535))
        for i in 0..<len {
            let v = UInt32(ptr[i]) * s / 256
            scaled[i] = UInt8(min(v, 255))
        }
        guard let provider = CGDataProvider(data: Data(scaled) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .perceptual)
    }

    // MARK: - Image Loading

    private func resizeCGImage(_ image: CGImage, w: Int, h: Int) -> CGImage? {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func loadHLGImage(path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func loadReferenceImage(path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Pixel Comparison

    private func pixelData(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &data, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    /// Compute Mean Absolute Error between two CGImages (RGB channels only).
    private func computeMAE(_ img: CGImage, reference: CGImage) -> Double {
        guard let a = pixelData(img), let b = pixelData(reference) else { return Double.infinity }
        let w = min(img.width, reference.width)
        let h = min(img.height, reference.height)
        var totalDiff: Double = 0
        var count = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                totalDiff += Double(abs(Int(a[i]) - Int(b[i])))
                totalDiff += Double(abs(Int(a[i+1]) - Int(b[i+1])))
                totalDiff += Double(abs(Int(a[i+2]) - Int(b[i+2])))
                count += 3
            }
        }
        return count > 0 ? totalDiff / Double(count) : Double.infinity
    }

    /// Compute PSNR between two CGImages.
    private func computePSNR(_ img: CGImage, reference: CGImage) -> Double {
        guard let a = pixelData(img), let b = pixelData(reference) else { return 0 }
        let w = min(img.width, reference.width)
        let h = min(img.height, reference.height)
        var mse: Double = 0
        var count = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let dr = Double(Int(a[i]) - Int(b[i]))
                let dg = Double(Int(a[i+1]) - Int(b[i+1]))
                let db = Double(Int(a[i+2]) - Int(b[i+2]))
                mse += dr*dr + dg*dg + db*db
                count += 3
            }
        }
        if count == 0 { return 0 }
        mse /= Double(count)
        return mse > 0 ? 20 * log10(255.0 / sqrt(mse)) : 100
    }

    // MARK: - Debug output

    // MARK: - LUT cross-validation

    /// Calibrated 1D LUT from DSC00513 (CGContext perceptual → Sony reference).
    /// Smoothed (window=5), per-channel, 256-entry.
    private let lutR: [UInt8] = [6,5,4,3,2,2,3,4,5,6,7,8,9,10,11,13,14,16,18,20,22,24,26,28,30,32,34,36,37,39,40,42,43,45,47,48,50,51,53,55,56,58,60,61,63,65,67,68,70,72,73,75,76,78,80,81,83,84,86,87,89,91,93,94,96,98,100,101,103,105,107,109,110,112,114,115,117,118,120,122,123,125,126,128,129,130,131,132,134,135,136,137,139,140,141,143,144,145,146,148,149,150,151,152,154,155,156,157,158,159,160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179,180,181,182,183,184,185,185,186,187,188,189,190,191,191,192,193,194,194,195,196,196,196,197,197,197,197,198,199,199,200,200,201,201,202,202,203,203,204,205,206,207,208,209,210,210,211,212,212,213,213,214,214,215,215,216,217,217,218,218,219,219,220,221,222,222,223,223,224,225,226,227,227,228,229,229,230,231,232,233,234,234,235,236,236,237,238,239,239,240,241,241,242,242,243,243,243,243,243,244,244,244,245,245,245,246,246,247,247,248,248,248,249,249,249,249,250,250,251,251,252,252,252,253,253,254,253]
    private let lutG: [UInt8] = [0,0,1,1,1,2,2,3,4,5,6,7,8,9,10,12,13,15,16,18,20,22,23,25,27,28,30,32,34,35,37,39,41,43,44,46,48,50,51,53,55,56,58,60,61,63,65,67,68,70,72,74,75,77,79,80,82,83,85,87,88,90,92,93,95,96,98,100,101,103,104,106,108,109,111,112,114,115,117,118,120,121,123,124,126,127,128,130,131,133,134,135,137,138,140,141,142,144,145,146,148,149,150,151,153,154,155,156,158,159,160,161,162,163,164,165,166,168,169,170,171,172,173,174,175,176,177,178,179,180,181,182,183,183,184,185,186,187,188,189,190,191,192,192,193,194,195,195,196,197,198,198,199,200,201,202,202,203,204,205,206,207,207,208,209,209,210,211,211,212,213,213,214,214,214,215,215,216,216,217,217,218,218,219,219,220,220,221,221,222,222,223,223,223,224,224,225,226,226,227,228,228,229,230,231,232,233,234,236,237,238,238,239,239,240,240,241,241,242,243,243,244,244,244,244,245,245,245,245,245,245,245,246,246,246,247,247,247,248,249,249,250,251,251,251,251,252,252,253,253,253,253,253,254,254,255]
    private let lutB: [UInt8] = [0,0,1,1,1,2,2,3,3,4,5,6,7,8,9,11,12,14,16,18,20,21,23,24,25,27,28,30,32,33,35,37,39,41,43,45,46,48,50,52,53,55,57,58,60,62,64,65,67,69,71,72,74,75,77,79,80,82,83,85,87,88,90,92,93,95,96,98,100,101,103,104,106,107,109,110,112,114,115,117,118,120,121,123,125,126,128,129,131,133,134,136,137,138,140,141,143,144,146,147,149,150,151,152,154,155,156,157,158,159,160,162,163,164,165,166,168,169,170,171,172,173,174,175,176,177,178,180,181,182,183,184,184,185,186,187,188,189,190,191,192,192,193,194,195,196,197,198,198,199,200,200,201,202,203,203,204,205,205,206,206,207,208,209,209,210,211,211,212,213,213,214,214,215,215,216,216,217,217,218,218,219,219,220,220,221,221,222,223,223,224,224,225,226,226,226,227,228,228,229,229,230,230,231,231,232,232,233,233,234,234,235,235,236,236,237,238,238,239,239,240,240,241,241,242,242,243,244,245,245,246,246,247,247,248,249,250,250,250,251,251,251,252,252,252,252,252,252,251,252,252,252,253,254,254,255]

    func testLutGeneralization() throws {
        let testHLG = "/Users/chenpc/Desktop/DSC02917.HIF"
        let testRef = "/Users/chenpc/Desktop/DSC02917.JPG"
        let outDir = "/tmp/hlg_export_experiments"
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir),
                                                  withIntermediateDirectories: true)

        guard let hlg = loadHLGImage(path: testHLG) else { XCTFail("Load HLG"); return }
        guard let ref = loadReferenceImage(path: testRef) else { XCTFail("Load ref"); return }

        let imgW = 2120, imgH = 1416
        guard let smallHLG = resizeCGImage(hlg, w: imgW, h: imgH),
              let smallRef = resizeCGImage(ref, w: imgW, h: imgH) else { XCTFail("Resize"); return }

        // Render via CGContext perceptual
        guard var baseData = pixelData(renderCGContext(smallHLG)!) else { XCTFail("Render"); return }
        let refData = pixelData(smallRef)!

        // MAE without LUT
        let baseMAE = computeMAENoRef(baseData, ref: refData, count: baseData.count)
        print("DSC02917 CGContext perceptual (no LUT): MAE=\(String(format: "%.4f", baseMAE))")

        // Apply LUT
        for i in stride(from: 0, to: baseData.count, by: 4) {
            baseData[i] = lutR[Int(baseData[i])]
            baseData[i+1] = lutG[Int(baseData[i+1])]
            baseData[i+2] = lutB[Int(baseData[i+2])]
        }

        // MAE with LUT
        let lutMAE = computeMAENoRef(baseData, ref: refData, count: baseData.count)
        print("DSC02917 CGContext + LUT: MAE=\(String(format: "%.4f", lutMAE))")

        // Save outputs
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        if let provider = CGDataProvider(data: Data(refData) as CFData),
           let refImg = CGImage(width: imgW, height: imgH, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: imgW * 4, space: sRGB,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            saveDebug(refImg, name: "dsc02917_ref")
        }
        // Use Data(baseData) for LUT result
        let lutData = baseData
        if let provider = CGDataProvider(data: Data(lutData) as CFData),
           let lutImg = CGImage(width: imgW, height: imgH, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: imgW * 4, space: sRGB,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            saveDebug(lutImg, name: "dsc02917_lut")
        }

        print("DSC02917: without LUT=\(String(format: "%.4f", baseMAE))  with LUT=\(String(format: "%.4f", lutMAE))")
    }

    private func computeMAENoRef(_ img: [UInt8], ref: [UInt8], count: Int) -> Double {
        var total: Double = 0
        var n = 0
        for i in stride(from: 0, to: min(count, img.count, ref.count), by: 4) {
            total += Double(abs(Int(img[i]) - Int(ref[i])))
            total += Double(abs(Int(img[i+1]) - Int(ref[i+1])))
            total += Double(abs(Int(img[i+2]) - Int(ref[i+2])))
            n += 3
        }
        return n > 0 ? total / Double(n) : Double.infinity
    }

    private func saveDebug(_ image: CGImage, name: String) {
        let url = URL(fileURLWithPath: "\(outputDir)/\(name).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            print("  [!] Cannot save \(name)")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
