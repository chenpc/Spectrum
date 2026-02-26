import Cocoa
import CoreGraphics

// MARK: - Placebo Render View (Mode 9: libplacebo offscreen tone mapping)

class PlaceboRenderView: NSView {
    private var showHDR = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    private var activeColorSpace: CGColorSpace?

    func configure(decoded: DecodedImageData, hdr: Bool, colorSpace: CGColorSpace? = nil) {
        showHDR = hdr
        activeColorSpace = colorSpace
        doRender(decoded: decoded)
    }

    func setHDR(_ on: Bool, decoded: DecodedImageData) {
        showHDR = on
        doRender(decoded: decoded)
    }

    private func doRender(decoded: DecodedImageData) {
        let w = decoded.width
        let h = decoded.height
        let dstStride = w * 8  // 4 × 16 bits
        let dstData = UnsafeMutablePointer<UInt16>.allocate(capacity: w * h * 4)
        defer { dstData.deallocate() }

        let ret = pl_render_hlg_image(
            decoded.data, Int32(w), Int32(h), Int32(decoded.stride),
            dstData, Int32(dstStride), showHDR ? 0 : 1
        )

        if ret != 0 {
            print("[placebo] render failed: \(ret)")
            return
        }

        // Build CGImage — use detected colorspace, fallback to displayP3/sRGB
        let cs = activeColorSpace ?? (showHDR ? CGColorSpace(name: CGColorSpace.displayP3)!
                                              : CGColorSpace(name: CGColorSpace.sRGB)!)

        let bpc = 16
        let bpp = 64
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue
                                        | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes: dstData, count: dstStride * h) as CFData) else { return }
        guard let cgImage = CGImage(width: w, height: h,
                                    bitsPerComponent: bpc, bitsPerPixel: bpp,
                                    bytesPerRow: dstStride,
                                    space: cs, bitmapInfo: info,
                                    provider: provider,
                                    decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else { return }

        // Use the view's own layer (same pattern as CALayerImageView / Mode 2)
        layer?.contents = cgImage

        // Enable EDR on layer chain
        func applyEDR(_ l: CALayer) {
            if #available(macOS 26.0, *) {
                l.preferredDynamicRange = showHDR ? .high : .standard
            } else {
                l.wantsExtendedDynamicRangeContent = showHDR
            }
        }
        if let l = layer { applyEDR(l) }
        var current = layer?.superlayer
        while let l = current { applyEDR(l); current = l.superlayer }
    }
}
