import XCTest
@testable import Spectrum

final class EditOpTests: XCTestCase {

    // MARK: - CropRect.rotated(by:)

    func testCropRect_rotated0_returnsSelf() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let result = crop.rotated(by: 0)
        XCTAssertEqual(result, crop)
    }

    func testCropRect_rotated360_returnsSelf() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let result = crop.rotated(by: 360)
        XCTAssertEqual(result, crop)
    }

    func testCropRect_rotated90() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        // 90° CW: (x, y, w, h) → (1-y-h, x, h, w)
        let result = crop.rotated(by: 90)
        XCTAssertEqual(result.x, 1 - 0.2 - 0.4, accuracy: 1e-10)
        XCTAssertEqual(result.y, 0.1, accuracy: 1e-10)
        XCTAssertEqual(result.width, 0.4, accuracy: 1e-10)
        XCTAssertEqual(result.height, 0.3, accuracy: 1e-10)
    }

    func testCropRect_rotated180() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let result = crop.rotated(by: 180)
        XCTAssertEqual(result.x, 1 - 0.1 - 0.3, accuracy: 1e-10)
        XCTAssertEqual(result.y, 1 - 0.2 - 0.4, accuracy: 1e-10)
        XCTAssertEqual(result.width, 0.3, accuracy: 1e-10)
        XCTAssertEqual(result.height, 0.4, accuracy: 1e-10)
    }

    func testCropRect_rotated270() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        // 270° CW: (x, y, w, h) → (y, 1-x-w, h, w)
        let result = crop.rotated(by: 270)
        XCTAssertEqual(result.x, 0.2, accuracy: 1e-10)
        XCTAssertEqual(result.y, 1 - 0.1 - 0.3, accuracy: 1e-10)
        XCTAssertEqual(result.width, 0.4, accuracy: 1e-10)
        XCTAssertEqual(result.height, 0.3, accuracy: 1e-10)
    }

    func testCropRect_rotatedNegative90_same_as_270() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let neg90 = crop.rotated(by: -90)
        let pos270 = crop.rotated(by: 270)
        XCTAssertEqual(neg90.x, pos270.x, accuracy: 1e-10)
        XCTAssertEqual(neg90.y, pos270.y, accuracy: 1e-10)
        XCTAssertEqual(neg90.width, pos270.width, accuracy: 1e-10)
        XCTAssertEqual(neg90.height, pos270.height, accuracy: 1e-10)
    }

    func testCropRect_fourRotations_returnsOriginal() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        var result = crop
        for _ in 0..<4 {
            result = result.rotated(by: 90)
        }
        XCTAssertEqual(result.x, crop.x, accuracy: 1e-10)
        XCTAssertEqual(result.y, crop.y, accuracy: 1e-10)
        XCTAssertEqual(result.width, crop.width, accuracy: 1e-10)
        XCTAssertEqual(result.height, crop.height, accuracy: 1e-10)
    }

    // MARK: - CropRect.flippedH()

    func testCropRect_flippedH() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let result = crop.flippedH()
        XCTAssertEqual(result.x, 1 - 0.1 - 0.3, accuracy: 1e-10)
        XCTAssertEqual(result.y, 0.2, accuracy: 1e-10)
        XCTAssertEqual(result.width, 0.3, accuracy: 1e-10)
        XCTAssertEqual(result.height, 0.4, accuracy: 1e-10)
    }

    func testCropRect_doubleFlip_returnsOriginal() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let result = crop.flippedH().flippedH()
        XCTAssertEqual(result.x, crop.x, accuracy: 1e-10)
        XCTAssertEqual(result.y, crop.y, accuracy: 1e-10)
    }

    // MARK: - CropRect.pixelRect()

    func testCropRect_pixelRect() {
        let crop = CropRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let rect = crop.pixelRect(imageWidth: 1920, imageHeight: 1080)
        XCTAssertEqual(rect.origin.x, 480, accuracy: 1e-10)
        XCTAssertEqual(rect.origin.y, 540, accuracy: 1e-10)
        XCTAssertEqual(rect.width, 960, accuracy: 1e-10)
        XCTAssertEqual(rect.height, 270, accuracy: 1e-10)
    }

    // MARK: - CompositeEdit.from() — basic

    func testCompositeEdit_emptyOps() {
        let c = CompositeEdit.from([])
        XCTAssertEqual(c.rotation, 0)
        XCTAssertFalse(c.flipH)
        XCTAssertNil(c.crop)
    }

    func testCompositeEdit_singleRotate90() {
        let c = CompositeEdit.from([.rotate(90)])
        XCTAssertEqual(c.rotation, 90)
        XCTAssertFalse(c.flipH)
        XCTAssertNil(c.crop)
    }

    func testCompositeEdit_singleRotateNeg90() {
        let c = CompositeEdit.from([.rotate(-90)])
        XCTAssertEqual(c.rotation, 270)
    }

    func testCompositeEdit_twoRotates() {
        let c = CompositeEdit.from([.rotate(90), .rotate(90)])
        XCTAssertEqual(c.rotation, 180)
    }

    func testCompositeEdit_fourRotates_wrapsToZero() {
        let ops: [EditOp] = (0..<4).map { _ in .rotate(90) }
        let c = CompositeEdit.from(ops)
        XCTAssertEqual(c.rotation, 0)
    }

    func testCompositeEdit_singleCrop() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let c = CompositeEdit.from([.crop(crop)])
        XCTAssertEqual(c.crop, crop)
        XCTAssertEqual(c.rotation, 0)
    }

    func testCompositeEdit_secondCropReplaces() {
        let crop1 = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let crop2 = CropRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let c = CompositeEdit.from([.crop(crop1), .crop(crop2)])
        XCTAssertEqual(c.crop, crop2)
    }

    // MARK: - CompositeEdit.from() — flip

    func testCompositeEdit_singleFlip() {
        let c = CompositeEdit.from([.flipH])
        XCTAssertTrue(c.flipH)
        XCTAssertEqual(c.rotation, 0)
    }

    func testCompositeEdit_doubleFlip_cancels() {
        let c = CompositeEdit.from([.flipH, .flipH])
        XCTAssertFalse(c.flipH)
        XCTAssertEqual(c.rotation, 0)
    }

    // MARK: - CompositeEdit.from() — crop + rotate interaction

    func testCompositeEdit_cropThenRotate_transformsCrop() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let c = CompositeEdit.from([.crop(crop), .rotate(90)])
        XCTAssertEqual(c.rotation, 90)
        // Crop should be transformed to 90° rotated space
        let expected = crop.rotated(by: 90)
        XCTAssertEqual(c.crop!.x, expected.x, accuracy: 1e-10)
        XCTAssertEqual(c.crop!.y, expected.y, accuracy: 1e-10)
        XCTAssertEqual(c.crop!.width, expected.width, accuracy: 1e-10)
        XCTAssertEqual(c.crop!.height, expected.height, accuracy: 1e-10)
    }

    func testCompositeEdit_cropThenFlip_transformsCrop() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let c = CompositeEdit.from([.crop(crop), .flipH])
        XCTAssertTrue(c.flipH)
        let expected = crop.flippedH()
        XCTAssertEqual(c.crop!.x, expected.x, accuracy: 1e-10)
        XCTAssertEqual(c.crop!.y, expected.y, accuracy: 1e-10)
    }

    // MARK: - EditOp Codable

    func testEditOp_codableRoundTrip() throws {
        let ops: [EditOp] = [
            .rotate(-90),
            .crop(CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
            .flipH,
        ]
        let data = try JSONEncoder().encode(ops)
        let decoded = try JSONDecoder().decode([EditOp].self, from: data)
        XCTAssertEqual(decoded, ops)
    }
}
