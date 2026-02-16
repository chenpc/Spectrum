import AppKit
import CoreImage
import ImageIO

struct GainMapHDRSpec: HDRRenderSpec {
    let badgeLabel = "HDR"
    let needsPrerenderedSDR = true

    func detect(source: CGImageSource, url: URL) -> Bool {
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
        ) != nil {
            return true
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let cr = exif[kCGImagePropertyExifCustomRendered] as? Int,
           cr == 3 {
            return true
        }
        return false
    }

    func render(url: URL, filePath: String, screenHeadroom: Float) -> (hdr: NSImage?, sdr: NSImage?) {
        // Read entire file into memory to avoid lazy I/O after security scope ends
        guard let fileData = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(fileData as CFData, nil)
        else {
            return (NSImage(contentsOfFile: filePath), nil)
        }

        // Load SDR base as CGImage → CIImage
        guard let baseCG = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return (NSImage(contentsOfFile: filePath), nil)
        }
        let sdrBase = CIImage(cgImage: baseCG)

        // Read gain map auxiliary data
        guard let auxInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
        ) as? [String: Any],
              let auxData = auxInfo[kCGImageAuxiliaryDataInfoData as String] as? Data,
              let auxDesc = auxInfo[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any],
              let gmWidth = auxDesc["Width"] as? Int,
              let gmHeight = auxDesc["Height"] as? Int,
              let gmBytesPerRow = auxDesc["BytesPerRow"] as? Int
        else {
            let img = NSImage(contentsOfFile: filePath)
            return (img, nil)
        }

        // Read headroom from image properties (MakerApple tag 33)
        let headroom = readHeadroom(source: source, screenHeadroom: screenHeadroom)

        // Create CIImage from gain map raw 8-bit grayscale data
        let gainMapCI = createGainMapCIImage(
            data: auxData, width: gmWidth, height: gmHeight, bytesPerRow: gmBytesPerRow
        )

        // Resize gain map to match SDR base dimensions using affine transform
        let scaleX = sdrBase.extent.width / gainMapCI.extent.width
        let scaleY = sdrBase.extent.height / gainMapCI.extent.height
        let resizedGainMap = gainMapCI
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Apply gain map formula (linear approximation):
        //   HDR = SDR * (1 + gainMap * (headroom - 1))
        //       = SDR + SDR * gainMap * (headroom - 1)
        //
        // Step 1: Scale gain map channels by (headroom - 1)
        // Step 2: Multiply SDR * scaledGainMap → boost
        // Step 3: Add SDR + boost → HDR
        let boostFactor = CGFloat(headroom - 1.0)

        let scaledGainMap = resizedGainMap.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: boostFactor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: boostFactor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: boostFactor, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        // SDR * scaledGainMap (pixel-by-pixel multiplication)
        let boost = sdrBase.applyingFilter("CIMultiplyCompositing", parameters: [
            "inputBackgroundImage": scaledGainMap
        ])

        // HDR = SDR + boost
        let hdrImage = sdrBase.applyingFilter("CIAdditionCompositing", parameters: [
            "inputBackgroundImage": boost
        ])

        let ctx = CIContext()

        // HDR: RGBAh / extendedDisplayP3 — preserves values > 1.0
        let hdr: NSImage?
        if let outputSpace = CGColorSpace(name: CGColorSpace.extendedDisplayP3),
           let cgImg = ctx.createCGImage(hdrImage, from: hdrImage.extent,
                                         format: .RGBAh, colorSpace: outputSpace) {
            hdr = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        } else {
            hdr = NSImage(contentsOfFile: filePath)
        }

        // SDR: RGBA8 / displayP3 — clips values > 1.0 (highlight clipping)
        let sdr: NSImage?
        if let outputSpace = CGColorSpace(name: CGColorSpace.displayP3),
           let cgImg = ctx.createCGImage(hdrImage, from: hdrImage.extent,
                                         format: .RGBA8, colorSpace: outputSpace) {
            sdr = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        } else {
            sdr = nil
        }

        return (hdr, sdr)
    }

    func dynamicRange(showHDR: Bool) -> NSImage.DynamicRange {
        showHDR ? .high : .standard
    }

    // MARK: - Helpers

    private func readHeadroom(source: CGImageSource, screenHeadroom: Float) -> Float {
        // Try MakerApple tag 33 (Apple's HDR headroom)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let makerApple = props["{MakerApple}"] as? [String: Any],
           let h = makerApple["33"] as? Double {
            return Float(h)
        }
        // Fallback
        return max(screenHeadroom, 2.0)
    }

    private func createGainMapCIImage(data: Data, width: Int, height: Int, bytesPerRow: Int) -> CIImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let graySpace = CGColorSpace(name: CGColorSpace.linearGray),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: bytesPerRow,
                  space: graySpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return CIImage(cgImage: cgImage)
    }
}
