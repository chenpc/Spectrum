import Foundation

enum EditOp: Codable, Equatable {
    case crop(CropRect)
    case rotate(Int) // 90 (CW) or -90 (CCW)
    case flipH
}

struct CompositeEdit {
    let rotation: Int    // 0, 90, 180, 270
    let flipH: Bool      // horizontal flip (applied before rotation)
    let crop: CropRect?  // in rotated coordinate space; nil = full image

    static func from(_ ops: [EditOp]) -> CompositeEdit {
        var rotation = 0
        var flipH = false
        var crop: CropRect? = nil

        for op in ops {
            switch op {
            case .rotate(let deg):
                // If there's an existing crop, transform it into the new rotated space
                if let c = crop {
                    crop = c.rotated(by: deg)
                }
                rotation = (rotation + deg % 360 + 360) % 360
            case .flipH:
                if let c = crop {
                    crop = c.flippedH()
                }
                rotation = (360 - rotation) % 360
                flipH = !flipH
            case .crop(let rect):
                // Replace existing crop (UI always draws a new crop on the full rotated image)
                crop = rect
            }
        }

        return CompositeEdit(rotation: rotation, flipH: flipH, crop: crop)
    }
}
