import XCTest
import Foundation
@testable import Spectrum

final class ExtraModelTests: XCTestCase {

    // MARK: - PhotoItem: identity / fileURL / compositeEdit

    func testPhotoItemIdentityAndFileURL() {
        let item = PhotoItem(filePath: "/Volumes/Cam/DCIM/IMG_0001.JPG",
                             fileName: "IMG_0001.JPG",
                             dateTaken: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(item.id, item.filePath, "id must equal filePath")
        XCTAssertEqual(item.id, "/Volumes/Cam/DCIM/IMG_0001.JPG")
        XCTAssertEqual(item.fileURL, URL(fileURLWithPath: "/Volumes/Cam/DCIM/IMG_0001.JPG"))
        XCTAssertEqual(item.fileURL.lastPathComponent, "IMG_0001.JPG")
        // Defaults
        XCTAssertFalse(item.isVideo)
        XCTAssertEqual(item.fileSize, 0)
        XCTAssertTrue(item.editOps.isEmpty)
    }

    func testPhotoItemCompositeEditEmpty() {
        let item = PhotoItem(filePath: "/a/b.jpg", fileName: "b.jpg", dateTaken: Date())
        let composite = item.compositeEdit
        XCTAssertEqual(composite.rotation, 0)
        XCTAssertFalse(composite.flipH)
        XCTAssertNil(composite.crop)
    }

    func testPhotoItemCompositeEditWithOps() {
        var item = PhotoItem(filePath: "/a/c.jpg", fileName: "c.jpg", dateTaken: Date())
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        item.editOps = [.rotate(90), .crop(crop)]
        let composite = item.compositeEdit
        XCTAssertEqual(composite.rotation, 90, "single +90 rotate")
        XCTAssertFalse(composite.flipH)
        XCTAssertEqual(composite.crop, crop, "crop replaces and is preserved after rotate-then-crop")
    }

    func testPhotoItemCompositeEditFlipTogglesRotation() {
        var item = PhotoItem(filePath: "/a/d.jpg", fileName: "d.jpg", dateTaken: Date())
        // rotate 90 then flipH: flip mirrors rotation => (360 - 90) % 360 = 270, flipH = true
        item.editOps = [.rotate(90), .flipH]
        let composite = item.compositeEdit
        XCTAssertEqual(composite.rotation, 270)
        XCTAssertTrue(composite.flipH)
        XCTAssertNil(composite.crop)
    }

    // MARK: - PhotoItem.applyEXIF

    func testApplyEXIFTransfersAllFields() {
        var item = PhotoItem(filePath: "/x/y.jpg", fileName: "y.jpg",
                             dateTaken: Date(timeIntervalSince1970: 0))

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var exif = EXIFData()
        exif.dateTaken = date
        exif.cameraMake = "SONY"
        exif.cameraModel = "ILCE-7M4"
        exif.lensModel = "FE 24-70mm F2.8 GM II"
        exif.focalLength = 50.0
        exif.aperture = 2.8
        exif.shutterSpeed = "1/250s"
        exif.iso = 400
        exif.pixelWidth = 6000
        exif.pixelHeight = 4000
        exif.latitude = 35.6895
        exif.longitude = 139.6917
        exif.exposureBias = -0.7
        exif.exposureProgram = 3
        exif.meteringMode = 5
        exif.flash = 16
        exif.whiteBalance = 0
        exif.brightnessValue = 4.5
        exif.focalLenIn35mm = 75
        exif.sceneCaptureType = 1
        exif.lightSource = 4
        exif.digitalZoomRatio = 2.0
        exif.contrast = 1
        exif.saturation = 2
        exif.sharpness = 0
        exif.lensSpecification = [24.0, 70.0, 2.8, 2.8]
        exif.offsetTimeOriginal = "+09:00"
        exif.subsecTimeOriginal = "123"
        exif.exifVersion = "2.3.1"
        exif.headroom = 1.5
        exif.profileName = "Display P3"
        exif.colorDepth = 8
        exif.orientation = 6
        exif.dpiWidth = 72.0
        exif.dpiHeight = 72.0
        exif.software = "Spectrum 1.0"
        exif.imageStabilization = 1

        item.applyEXIF(exif)

        XCTAssertEqual(item.dateTaken, date, "dateTaken set from EXIF")
        XCTAssertEqual(item.cameraMake, "SONY")
        XCTAssertEqual(item.cameraModel, "ILCE-7M4")
        XCTAssertEqual(item.lensModel, "FE 24-70mm F2.8 GM II")
        XCTAssertEqual(item.focalLength, 50.0)
        XCTAssertEqual(item.aperture, 2.8)
        XCTAssertEqual(item.shutterSpeed, "1/250s")
        XCTAssertEqual(item.iso, 400)
        XCTAssertEqual(item.pixelWidth, 6000)
        XCTAssertEqual(item.pixelHeight, 4000)
        XCTAssertEqual(item.latitude, 35.6895)
        XCTAssertEqual(item.longitude, 139.6917)
        XCTAssertEqual(item.exposureBias, -0.7)
        XCTAssertEqual(item.exposureProgram, 3)
        XCTAssertEqual(item.meteringMode, 5)
        XCTAssertEqual(item.flash, 16)
        XCTAssertEqual(item.whiteBalance, 0)
        XCTAssertEqual(item.brightnessValue, 4.5)
        XCTAssertEqual(item.focalLenIn35mm, 75)
        XCTAssertEqual(item.sceneCaptureType, 1)
        XCTAssertEqual(item.lightSource, 4)
        XCTAssertEqual(item.digitalZoomRatio, 2.0)
        XCTAssertEqual(item.contrast, 1)
        XCTAssertEqual(item.saturation, 2)
        XCTAssertEqual(item.sharpness, 0)
        XCTAssertEqual(item.lensSpecification ?? [], [24.0, 70.0, 2.8, 2.8])
        XCTAssertEqual(item.offsetTimeOriginal, "+09:00")
        XCTAssertEqual(item.exifVersion, "2.3.1")
        XCTAssertEqual(item.headroom, 1.5)
        XCTAssertEqual(item.profileName, "Display P3")
        XCTAssertEqual(item.colorDepth, 8)
        XCTAssertEqual(item.orientation, 6)
        XCTAssertEqual(item.dpiWidth, 72.0)
        XCTAssertEqual(item.dpiHeight, 72.0)
        XCTAssertEqual(item.software, "Spectrum 1.0")
        XCTAssertEqual(item.imageStabilization, 1)
    }

    func testApplyEXIFEmptyKeepsDimensionsAndDate() {
        // When pixelWidth/Height and dateTaken are nil in EXIF, existing values are kept.
        let originalDate = Date(timeIntervalSince1970: 42)
        var item = PhotoItem(filePath: "/x/z.jpg", fileName: "z.jpg", dateTaken: originalDate)
        item.pixelWidth = 1234
        item.pixelHeight = 5678

        let exif = EXIFData()  // all nil
        item.applyEXIF(exif)

        XCTAssertEqual(item.pixelWidth, 1234, "nil EXIF pixelWidth must not overwrite")
        XCTAssertEqual(item.pixelHeight, 5678, "nil EXIF pixelHeight must not overwrite")
        XCTAssertEqual(item.dateTaken, originalDate, "nil EXIF dateTaken must not overwrite")
        XCTAssertNil(item.cameraMake)
        XCTAssertNil(item.iso)
    }

    // MARK: - PhotoItem.applyVideoMetadata

    func testApplyVideoMetadataTransfersFields() {
        var item = PhotoItem(filePath: "/v/clip.mov", fileName: "clip.mov",
                             dateTaken: Date(timeIntervalSince1970: 0), isVideo: true)
        let creation = Date(timeIntervalSince1970: 1_650_000_000)
        var meta = VideoMetadata()
        meta.duration = 12.5
        meta.pixelWidth = 3840
        meta.pixelHeight = 2160
        meta.videoCodec = "hvc1"
        meta.audioCodec = "aac"
        meta.creationDate = creation
        meta.latitude = -33.8688
        meta.longitude = 151.2093

        item.applyVideoMetadata(meta)

        XCTAssertEqual(item.duration, 12.5)
        XCTAssertEqual(item.pixelWidth, 3840)
        XCTAssertEqual(item.pixelHeight, 2160)
        XCTAssertEqual(item.videoCodec, "hvc1")
        XCTAssertEqual(item.audioCodec, "aac")
        XCTAssertEqual(item.dateTaken, creation, "creationDate maps to dateTaken")
        XCTAssertEqual(item.latitude, -33.8688)
        XCTAssertEqual(item.longitude, 151.2093)
    }

    func testApplyVideoMetadataEmptyKeepsExisting() {
        let original = Date(timeIntervalSince1970: 99)
        var item = PhotoItem(filePath: "/v/empty.mov", fileName: "empty.mov", dateTaken: original)
        item.pixelWidth = 100
        item.pixelHeight = 200

        let meta = VideoMetadata()  // all nil
        item.applyVideoMetadata(meta)

        XCTAssertNil(item.duration)
        XCTAssertEqual(item.pixelWidth, 100)
        XCTAssertEqual(item.pixelHeight, 200)
        XCTAssertEqual(item.dateTaken, original)
        XCTAssertNil(item.videoCodec)
        XCTAssertNil(item.audioCodec)
        XCTAssertNil(item.latitude)
        XCTAssertNil(item.longitude)
    }

    // MARK: - PhotoItem.resolveBookmarkData

    func testResolveBookmarkDataPrefixMatch() {
        let dataA = Data([0xAA, 0xBB])
        let dataB = Data([0xCC, 0xDD])
        let folderA = ScannedFolder(path: "/Volumes/CardA", bookmarkData: dataA)
        let folderB = ScannedFolder(path: "/Volumes/CardB", bookmarkData: dataB)
        let folders = [folderA, folderB]

        let item = PhotoItem(filePath: "/Volumes/CardB/DCIM/IMG.JPG",
                             fileName: "IMG.JPG", dateTaken: Date())
        XCTAssertEqual(item.resolveBookmarkData(from: folders), dataB,
                       "should pick the folder whose path prefixes the file path")
    }

    func testResolveBookmarkDataNoMatchReturnsNil() {
        let folder = ScannedFolder(path: "/Volumes/CardA", bookmarkData: Data([0x01]))
        let item = PhotoItem(filePath: "/Volumes/Other/x.jpg",
                             fileName: "x.jpg", dateTaken: Date())
        XCTAssertNil(item.resolveBookmarkData(from: [folder]))
        XCTAssertNil(item.resolveBookmarkData(from: []), "empty folder list => nil")
    }

}
