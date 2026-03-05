import XCTest
import SwiftData
@testable import Spectrum

final class PhotoEditOpsTests: XCTestCase {

    private func makePhoto() throws -> Photo {
        Photo(filePath: "/tmp/test.jpg", fileName: "test.jpg", dateTaken: Date())
    }

    // MARK: - editOps getter

    func testEditOps_nilJson_returnsEmpty() throws {
        let photo = try makePhoto()
        photo.editOpsJson = nil
        XCTAssertEqual(photo.editOps, [])
    }

    func testEditOps_invalidJson_returnsEmpty() throws {
        let photo = try makePhoto()
        photo.editOpsJson = "not valid json"
        XCTAssertEqual(photo.editOps, [])
    }

    func testEditOps_emptyArray_returnsEmpty() throws {
        let photo = try makePhoto()
        photo.editOpsJson = "[]"
        XCTAssertEqual(photo.editOps, [])
    }

    // MARK: - editOps setter

    func testEditOps_setter_encodesToJson() throws {
        let photo = try makePhoto()
        let ops: [EditOp] = [.rotate(-90), .flipH]
        photo.editOps = ops
        XCTAssertNotNil(photo.editOpsJson)

        // Decode back to verify
        let data = photo.editOpsJson!.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([EditOp].self, from: data)
        XCTAssertEqual(decoded, ops)
    }

    func testEditOps_setter_emptyArray_setsJson() throws {
        let photo = try makePhoto()
        photo.editOps = [.rotate(90)]
        XCTAssertNotNil(photo.editOpsJson)

        photo.editOps = []
        // Empty array should still encode as "[]"
        XCTAssertNotNil(photo.editOpsJson)
        XCTAssertEqual(photo.editOps, [])
    }

    // MARK: - Round-trip

    func testEditOps_roundTrip_withCrop() throws {
        let photo = try makePhoto()
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let ops: [EditOp] = [.rotate(-90), .crop(crop), .flipH]
        photo.editOps = ops
        XCTAssertEqual(photo.editOps, ops)
    }

    // MARK: - compositeEdit

    func testCompositeEdit_derivesFromEditOps() throws {
        let photo = try makePhoto()
        photo.editOps = [.rotate(-90), .rotate(-90)]
        let c = photo.compositeEdit
        XCTAssertEqual(c.rotation, 180)
        XCTAssertFalse(c.flipH)
        XCTAssertNil(c.crop)
    }

    func testCompositeEdit_noEdits() throws {
        let photo = try makePhoto()
        let c = photo.compositeEdit
        XCTAssertEqual(c.rotation, 0)
        XCTAssertFalse(c.flipH)
        XCTAssertNil(c.crop)
    }
}
