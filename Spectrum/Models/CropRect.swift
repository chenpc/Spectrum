import CoreGraphics
import Foundation

struct CropRect: Codable, Equatable {
    var x: Double      // 左上角 x (0~1)
    var y: Double      // 左上角 y (0~1)
    var width: Double  // 寬度 (0~1)
    var height: Double // 高度 (0~1)

    func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        CGRect(
            x: x * Double(imageWidth),
            y: y * Double(imageHeight),
            width: width * Double(imageWidth),
            height: height * Double(imageHeight)
        )
    }

    /// Transform crop coordinates when the image is rotated by the given degrees.
    func rotated(by degrees: Int) -> CropRect {
        let norm = ((degrees % 360) + 360) % 360
        switch norm {
        case 90:
            // 90° CW: (x, y, w, h) → (1-y-h, x, h, w)
            return CropRect(x: 1 - y - height, y: x, width: height, height: width)
        case 180:
            return CropRect(x: 1 - x - width, y: 1 - y - height, width: width, height: height)
        case 270:
            // 270° CW (= 90° CCW): (x, y, w, h) → (y, 1-x-w, h, w)
            return CropRect(x: y, y: 1 - x - width, width: height, height: width)
        default:
            return self
        }
    }
}
