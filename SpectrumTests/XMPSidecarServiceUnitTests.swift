import XCTest
import Foundation
@testable import Spectrum

final class XMPSidecarServiceUnitTests: XCTestCase {

    private var tempDir: URL!
    private var imageURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMPSidecarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        imageURL = tempDir.appendingPathComponent("photo.jpg")
        // Create a placeholder image file so the sidecar sits next to a real path.
        try Data("fake-jpeg".utf8).write(to: imageURL)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        imageURL = nil
    }

    // MARK: - sidecarURL

    func testSidecarURLAppendsXmpExtension() {
        let url = XMPSidecarService.sidecarURL(for: imageURL)
        XCTAssertEqual(url.lastPathComponent, "photo.jpg.xmp")
        XCTAssertEqual(url.pathExtension, "xmp")
    }

    func testSidecarURLPreservesOriginalExtension() {
        let video = tempDir.appendingPathComponent("clip.mp4")
        let url = XMPSidecarService.sidecarURL(for: video)
        XCTAssertEqual(url.lastPathComponent, "clip.mp4.xmp")
    }

    // MARK: - No sidecar

    func testReadNoSidecarReturnsNil() {
        let result = XMPSidecarService.read(for: imageURL, originalOrientation: 1)
        XCTAssertNil(result, "Reading when no sidecar file exists must return nil")
    }

    // MARK: - Malformed XML

    func testReadMalformedXMLReturnsNil() throws {
        let sidecar = XMPSidecarService.sidecarURL(for: imageURL)
        try Data("this is <not> valid xml &&&".utf8).write(to: sidecar)
        let result = XMPSidecarService.read(for: imageURL, originalOrientation: 1)
        XCTAssertNil(result, "Malformed XML must parse to nil, not crash")
    }

    func testReadValidXMLWithoutDescriptionReturnsNil() throws {
        let sidecar = XMPSidecarService.sidecarURL(for: imageURL)
        try Data("<root><child>hi</child></root>".utf8).write(to: sidecar)
        let result = XMPSidecarService.read(for: imageURL, originalOrientation: 1)
        XCTAssertNil(result, "Valid XML lacking rdf:Description must return nil")
    }

    // MARK: - No-op edit writes a sidecar but reads back nil

    func testWriteIdentityEditReadsBackNil() throws {
        let edit = CompositeEdit.from([])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: XMPSidecarService.sidecarURL(for: imageURL).path))
        let result = XMPSidecarService.read(for: imageURL, originalOrientation: 1)
        XCTAssertNil(result, "An identity edit carries no information and reads back nil")
    }

    // MARK: - Rotation round trips

    func testRotation90RoundTrip() throws {
        let edit = CompositeEdit.from([.rotate(90)])
        XCTAssertEqual(edit.rotation, 90)
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(result.rotation, 90)
        XCTAssertFalse(result.flipH)
        XCTAssertNil(result.crop)
    }

    func testRotation180RoundTrip() throws {
        let edit = CompositeEdit.from([.rotate(90), .rotate(90)])
        XCTAssertEqual(edit.rotation, 180)
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(result.rotation, 180)
        XCTAssertFalse(result.flipH)
    }

    func testRotation270RoundTrip() throws {
        let edit = CompositeEdit.from([.rotate(-90)])
        XCTAssertEqual(edit.rotation, 270)
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(result.rotation, 270)
        XCTAssertFalse(result.flipH)
    }

    // MARK: - Flip round trips

    func testFlipHRoundTrip() throws {
        let edit = CompositeEdit.from([.flipH])
        XCTAssertTrue(edit.flipH)
        XCTAssertEqual(edit.rotation, 0)
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertTrue(result.flipH)
        XCTAssertEqual(result.rotation, 0)
    }

    func testFlipHWithRotationRoundTrip() throws {
        // flip then rotate 90
        let edit = CompositeEdit.from([.flipH, .rotate(90)])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(result.flipH, edit.flipH)
        XCTAssertEqual(result.rotation, edit.rotation)
    }

    // MARK: - Crop round trips

    func testCropRoundTrip() throws {
        let crop = CropRect(x: 0.25, y: 0.1, width: 0.5, height: 0.25)
        let edit = CompositeEdit.from([.crop(crop)])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        let readCrop = try XCTUnwrap(result.crop)
        XCTAssertEqual(readCrop.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(readCrop.y, 0.1, accuracy: 1e-6)
        XCTAssertEqual(readCrop.width, 0.5, accuracy: 1e-6)
        XCTAssertEqual(readCrop.height, 0.25, accuracy: 1e-6)
        XCTAssertEqual(result.rotation, 0)
        XCTAssertFalse(result.flipH)
    }

    func testFullCropDoesNotProduceCrop() throws {
        // A crop covering the whole image: top=0 left=0 bottom=1 right=1.
        // Read: w=1,h=1 > 0 so crop is returned; verify it round trips as full frame.
        let crop = CropRect(x: 0, y: 0, width: 1, height: 1)
        let edit = CompositeEdit.from([.crop(crop)])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        let readCrop = try XCTUnwrap(result.crop)
        XCTAssertEqual(readCrop.width, 1.0, accuracy: 1e-6)
        XCTAssertEqual(readCrop.height, 1.0, accuracy: 1e-6)
    }

    // MARK: - Combined rotation + flip + crop

    func testCombinedEditRoundTrip() throws {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let edit = CompositeEdit.from([.rotate(90), .crop(crop), .flipH])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(result.rotation, edit.rotation)
        XCTAssertEqual(result.flipH, edit.flipH)
        let readCrop = try XCTUnwrap(result.crop)
        let expected = try XCTUnwrap(edit.crop)
        XCTAssertEqual(readCrop.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(readCrop.y, expected.y, accuracy: 1e-6)
        XCTAssertEqual(readCrop.width, expected.width, accuracy: 1e-6)
        XCTAssertEqual(readCrop.height, expected.height, accuracy: 1e-6)
    }

    // MARK: - originalOrientation parameter

    func testOriginalOrientationCancelsWhenWriteAndReadMatch() throws {
        // Write with a real edit on an image whose original EXIF orientation is 6 (90 CW).
        let edit = CompositeEdit.from([.rotate(90)])
        try XMPSidecarService.write(edit: edit, originalOrientation: 6, for: imageURL)
        // Reading back with the SAME original orientation recovers the user edit (90).
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 6))
        XCTAssertEqual(result.rotation, 90)
        XCTAssertFalse(result.flipH)
    }

    func testOriginalOrientationAffectsDecodedEdit() throws {
        // Written with original orientation 1 and a 90 edit.
        let edit = CompositeEdit.from([.rotate(90)])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)

        // Read with the correct orientation → recovers 90.
        let correct = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(correct.rotation, 90)

        // Read pretending the original was already rotated 90 (orientation 6):
        // the stored absolute orientation now cancels the original, leaving no edit → nil.
        let mismatched = XMPSidecarService.read(for: imageURL, originalOrientation: 6)
        XCTAssertNil(mismatched, "Different originalOrientation must change the decoded edit")
    }

    func testOriginalOrientationWithFlippedSource() throws {
        // Source already mirrored (orientation 2 = flipH). User adds no edit.
        let edit = CompositeEdit.from([])
        try XMPSidecarService.write(edit: edit, originalOrientation: 2, for: imageURL)
        // Reading with matching orientation 2 → identity edit → nil.
        let result = XMPSidecarService.read(for: imageURL, originalOrientation: 2)
        XCTAssertNil(result)
    }

    // MARK: - GyroConfig

    func testGyroConfigRoundTripWithEscaping() throws {
        let json = "{\"fov\":1.0,\"name\":\"a&b<c>\\\"d\\\"\"}"
        let edit = CompositeEdit.from([])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, gyroConfig: json, for: imageURL)
        // gyroConfig alone is enough to make read return non-nil.
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(result.gyroConfig, json, "GyroConfig must survive XML attribute escaping round trip")
        XCTAssertEqual(result.rotation, 0)
        XCTAssertFalse(result.flipH)
        XCTAssertNil(result.crop)
    }

    func testGyroConfigWithEditRoundTrip() throws {
        let json = "{\"smoothness\":0.5}"
        let edit = CompositeEdit.from([.rotate(180)])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, gyroConfig: json, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(result.rotation, 180)
        XCTAssertEqual(result.gyroConfig, json)
    }

    // MARK: - deleteSidecar

    func testDeleteSidecarRemovesFile() throws {
        let edit = CompositeEdit.from([.rotate(90)])
        try XMPSidecarService.write(edit: edit, originalOrientation: 1, for: imageURL)
        let sidecar = XMPSidecarService.sidecarURL(for: imageURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        XMPSidecarService.deleteSidecar(for: imageURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertNil(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
    }

    func testDeleteSidecarWhenMissingIsNoOp() {
        // Should not throw / crash when there is nothing to delete.
        XMPSidecarService.deleteSidecar(for: imageURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecarService.sidecarURL(for: imageURL).path))
    }

    // MARK: - Overwrite behavior

    func testOverwriteSidecarReplacesContent() throws {
        try XMPSidecarService.write(edit: CompositeEdit.from([.rotate(90)]), originalOrientation: 1, for: imageURL)
        try XMPSidecarService.write(edit: CompositeEdit.from([.rotate(180)]), originalOrientation: 1, for: imageURL)
        let result = try XCTUnwrap(XMPSidecarService.read(for: imageURL, originalOrientation: 1))
        XCTAssertEqual(result.rotation, 180, "Second write must replace the first")
    }
}
