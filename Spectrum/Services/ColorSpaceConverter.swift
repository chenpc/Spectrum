import AppKit
import CoreImage

enum ColorSpaceOption: String, CaseIterable, Identifiable, Sendable {
    case original
    case sRGB
    case displayP3
    case adobeRGB
    case proPhotoRGB
    case bt709
    case bt2020

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original"
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB"
        case .proPhotoRGB: "ProPhoto RGB"
        case .bt709: "BT.709"
        case .bt2020: "BT.2020"
        }
    }

    var cgColorSpace: CGColorSpace? {
        switch self {
        case .original: nil
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)
        case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case .proPhotoRGB: CGColorSpace(name: CGColorSpace.rommrgb)
        case .bt709: CGColorSpace(name: CGColorSpace.itur_709)
        case .bt2020: CGColorSpace(name: CGColorSpace.itur_2020)
        }
    }
}

enum ColorSpaceConverter {
    static func convert(_ nsImage: NSImage, to colorSpace: CGColorSpace) -> NSImage? {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let ciImage = CIImage(cgImage: cgImage)
        let ctx = CIContext()

        guard let outputCGImage = ctx.createCGImage(
            ciImage,
            from: ciImage.extent,
            format: .RGBAh,
            colorSpace: colorSpace
        ) else {
            return nil
        }

        return NSImage(
            cgImage: outputCGImage,
            size: NSSize(width: outputCGImage.width, height: outputCGImage.height)
        )
    }
}
