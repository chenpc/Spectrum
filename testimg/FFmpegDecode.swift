import Foundation
import CoreGraphics

// MARK: - FFmpeg Decoded Image Data

struct DecodedImageData {
    let data: UnsafeMutablePointer<UInt16>
    let width: Int
    let height: Int
    let stride: Int  // bytes per row

    func makeCGImage(colorSpace: CGColorSpace) -> CGImage? {
        let bpc = 16
        let bpp = 64  // 4 × 16
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue
                                        | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(dataInfo: nil,
                                            data: data,
                                            size: stride * height,
                                            releaseData: { _, _, _ in }) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: bpc, bitsPerPixel: bpp, bytesPerRow: stride,
                       space: colorSpace, bitmapInfo: info,
                       provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func free() {
        Darwin.free(data)
    }
}

// MARK: - CGImage Extraction (handles HEIF grid correctly)

func decodedDataFromCGImage(_ cgImage: CGImage) -> DecodedImageData? {
    let w = cgImage.width
    let h = cgImage.height
    let bpr = w * 8  // 4 components × 16 bits
    let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()

    let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue
                                    | CGImageAlphaInfo.noneSkipLast.rawValue)

    guard let rawData = malloc(bpr * h) else { return nil }
    let data = rawData.assumingMemoryBound(to: UInt16.self)

    guard let ctx = CGContext(
        data: rawData,
        width: w, height: h,
        bitsPerComponent: 16,
        bytesPerRow: bpr,
        space: cs,
        bitmapInfo: info.rawValue
    ) else {
        Darwin.free(rawData)
        return nil
    }

    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    return DecodedImageData(
        data: data,
        width: w,
        height: h,
        stride: bpr
    )
}

// MARK: - FFmpeg Decode Wrapper

// MARK: - Placebo Filter (apply libplacebo tone mapping to CGImage)

/// Apply libplacebo HLG tone mapping: HLG/BT.2020 → P3/sRGB, tagged with original colorspace.
/// This creates the "version A" effect: libplacebo quality + macOS HLG EDR boost.
func applyPlaceboFilter(_ cgImage: CGImage) -> CGImage? {
    guard let decoded = decodedDataFromCGImage(cgImage) else { return nil }
    defer { decoded.free() }

    let w = decoded.width
    let h = decoded.height
    let dstStride = w * 8
    guard let dstRaw = malloc(dstStride * h) else { return nil }
    let dstData = dstRaw.assumingMemoryBound(to: UInt16.self)

    let ret = pl_render_hlg_image(
        decoded.data, Int32(w), Int32(h), Int32(decoded.stride),
        dstData, Int32(dstStride), 0  // HDR mode
    )
    guard ret == 0 else {
        Darwin.free(dstRaw)
        print("[placebo-filter] render failed: \(ret)")
        return nil
    }

    // Tag with original colorspace (HLG) for macOS EDR display
    let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue
                                    | CGImageAlphaInfo.noneSkipLast.rawValue)
    guard let provider = CGDataProvider(dataInfo: nil,
                                        data: dstRaw,
                                        size: dstStride * h,
                                        releaseData: { _, ptr, _ in Darwin.free(UnsafeMutableRawPointer(mutating: ptr)) })
    else {
        Darwin.free(dstRaw)
        return nil
    }

    return CGImage(width: w, height: h,
                   bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: dstStride,
                   space: cs, bitmapInfo: info,
                   provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// MARK: - FFmpeg Decode Wrapper

func ffmpegDecodeHEIF(url: URL) -> DecodedImageData? {
    var result = FFDecodedImage()
    let ret = url.path.withCString { path in
        ff_decode_heif(path, &result)
    }
    guard ret == 0, let data = result.data else {
        print("[ffmpeg] decode failed: \(ret)")
        return nil
    }
    return DecodedImageData(
        data: data,
        width: Int(result.width),
        height: Int(result.height),
        stride: Int(result.stride)
    )
}
