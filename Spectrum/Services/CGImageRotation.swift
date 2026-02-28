import CoreGraphics

/// Rotate a CGImage by 0, 90, 180, or 270 degrees (CW).
func rotateCGImage(_ image: CGImage, degrees: Int) -> CGImage? {
    let norm = ((degrees % 360) + 360) % 360
    guard norm != 0 else { return image }

    let w = image.width
    let h = image.height
    let isTransposed = (norm == 90 || norm == 270)
    let newW = isTransposed ? h : w
    let newH = isTransposed ? w : h

    guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: newW,
              height: newH,
              bitsPerComponent: image.bitsPerComponent,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: image.bitmapInfo.rawValue
          )
    else { return nil }

    switch norm {
    case 90:
        // 90° CW
        ctx.translateBy(x: CGFloat(newW), y: 0)
        ctx.rotate(by: .pi / 2)
    case 180:
        ctx.translateBy(x: CGFloat(newW), y: CGFloat(newH))
        ctx.rotate(by: .pi)
    case 270:
        // 270° CW = 90° CCW
        ctx.translateBy(x: 0, y: CGFloat(newH))
        ctx.rotate(by: -.pi / 2)
    default:
        break
    }

    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// Flip a CGImage horizontally.
func flipCGImage(_ image: CGImage, horizontal: Bool) -> CGImage? {
    guard horizontal else { return image }

    let w = image.width
    let h = image.height

    guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: w,
              height: h,
              bitsPerComponent: image.bitsPerComponent,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: image.bitmapInfo.rawValue
          )
    else { return nil }

    // Flip horizontally: mirror along vertical axis
    ctx.translateBy(x: CGFloat(w), y: 0)
    ctx.scaleBy(x: -1, y: 1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}
