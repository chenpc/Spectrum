import XCTest
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Spectrum

final class EXIFServiceUnitTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SpectrumUITests/E2EFixtures")
    }

    /// Writes a JPEG with the supplied metadata dictionary and returns its URL.
    @discardableResult
    private func writeImage(name: String,
                            width: Int = 8,
                            height: Int = 6,
                            metadata: [CFString: Any]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        // Build a tiny solid-color image.
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("Could not create CGContext")
        }
        ctx.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw XCTSkip("makeImage failed") }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw XCTSkip("CGImageDestination create failed")
        }
        CGImageDestinationAddImage(dest, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("finalize failed") }
        return url
    }

    // MARK: - Non-image / error paths

    func testNonexistentURLReturnsEmpty() {
        let url = tempDir.appendingPathComponent("does-not-exist.jpg")
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertNil(exif.cameraMake)
        XCTAssertNil(exif.dateTaken)
        XCTAssertNil(exif.pixelWidth)
        XCTAssertNil(exif.iso)
    }

    func testNonImageFileReturnsEmpty() throws {
        let url = tempDir.appendingPathComponent("notanimage.txt")
        try Data("hello world this is not an image".utf8).write(to: url)
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertNil(exif.cameraModel)
        XCTAssertNil(exif.pixelWidth)
        XCTAssertNil(exif.latitude)
    }

    // MARK: - Dimensions & top-level

    func testDimensionsAndTopLevel() throws {
        let url = try writeImage(name: "dims.jpg", width: 12, height: 9, metadata: [:])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.pixelWidth, 12)
        XCTAssertEqual(exif.pixelHeight, 9)
        // Depth is present for a standard 8-bit JPEG.
        XCTAssertNotNil(exif.colorDepth)
    }

    // MARK: - TIFF dictionary

    func testTIFFFields() throws {
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "SONY",
            kCGImagePropertyTIFFModel: "ILCE-7M4",
            kCGImagePropertyTIFFSoftware: "Spectrum 1.0",
        ]
        let url = try writeImage(name: "tiff.jpg", metadata: [
            kCGImagePropertyTIFFDictionary: tiff
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.cameraMake, "SONY")
        XCTAssertEqual(exif.cameraModel, "ILCE-7M4")
        XCTAssertEqual(exif.software, "Spectrum 1.0")
    }

    // MARK: - EXIF core fields & derived formatting

    func testExifCoreFieldsAndShutterFraction() throws {
        let exifDict: [CFString: Any] = [
            kCGImagePropertyExifLensModel: "FE 24-70mm F2.8 GM II",
            kCGImagePropertyExifFocalLength: 50.0,
            kCGImagePropertyExifFNumber: 2.8,
            kCGImagePropertyExifExposureTime: 1.0 / 250.0,
            kCGImagePropertyExifISOSpeedRatings: [400, 100],
            kCGImagePropertyExifFocalLenIn35mmFilm: 75,
        ]
        let url = try writeImage(name: "exif.jpg", metadata: [
            kCGImagePropertyExifDictionary: exifDict
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.lensModel, "FE 24-70mm F2.8 GM II")
        XCTAssertEqual(exif.focalLength, 50.0)
        XCTAssertEqual(exif.aperture, 2.8)
        XCTAssertEqual(exif.shutterSpeed, "1/250s")
        XCTAssertEqual(exif.iso, 400, "ISO should be first element of array")
        XCTAssertEqual(exif.focalLenIn35mm, 75)
    }

    func testShutterSpeedLongExposureFormatting() throws {
        let exifDict: [CFString: Any] = [
            kCGImagePropertyExifExposureTime: 2.5,
        ]
        let url = try writeImage(name: "longexp.jpg", metadata: [
            kCGImagePropertyExifDictionary: exifDict
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.shutterSpeed, "2.5s")
    }

    func testExifExtraScalarFields() throws {
        let exifDict: [CFString: Any] = [
            kCGImagePropertyExifExposureBiasValue: -0.7,
            kCGImagePropertyExifExposureProgram: 3,
            kCGImagePropertyExifMeteringMode: 5,
            kCGImagePropertyExifFlash: 16,
            kCGImagePropertyExifWhiteBalance: 0,
            kCGImagePropertyExifBrightnessValue: 4.5,
            kCGImagePropertyExifSceneCaptureType: 1,
            kCGImagePropertyExifLightSource: 4,
            kCGImagePropertyExifDigitalZoomRatio: 2.0,
            kCGImagePropertyExifContrast: 1,
            kCGImagePropertyExifSaturation: 2,
            kCGImagePropertyExifSharpness: 0,
        ]
        let url = try writeImage(name: "extras.jpg", metadata: [
            kCGImagePropertyExifDictionary: exifDict
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.exposureBias, -0.7)
        XCTAssertEqual(exif.exposureProgram, 3)
        XCTAssertEqual(exif.meteringMode, 5)
        XCTAssertEqual(exif.flash, 16)
        XCTAssertEqual(exif.whiteBalance, 0)
        XCTAssertEqual(exif.brightnessValue, 4.5)
        XCTAssertEqual(exif.sceneCaptureType, 1)
        XCTAssertEqual(exif.lightSource, 4)
        XCTAssertEqual(exif.digitalZoomRatio, 2.0)
        XCTAssertEqual(exif.contrast, 1)
        XCTAssertEqual(exif.saturation, 2)
        XCTAssertEqual(exif.sharpness, 0)
    }

    func testLensSpecificationArray() throws {
        let spec: [Double] = [24.0, 70.0, 2.8, 2.8]
        let url = try writeImage(name: "lensspec.jpg", metadata: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensSpecification: spec
            ] as [CFString: Any]
        ])
        let exif = EXIFService.readEXIF(from: url)
        let actual = exif.lensSpecification
        XCTAssertEqual(actual?.count, spec.count)
        if let actual, actual.count == spec.count {
            for (a, e) in zip(actual, spec) {
                XCTAssertEqual(Double(a), e, accuracy: 0.001)
            }
        }
    }

    func testDateTakenWithoutOffset() throws {
        let url = try writeImage(name: "date.jpg", metadata: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:01:15 14:30:00"
            ] as [CFString: Any]
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertNotNil(exif.dateTaken)
        XCTAssertNil(exif.offsetTimeOriginal)

        // Verify the parsed components against a POSIX/UTC-agnostic formatter.
        let df = DateFormatter()
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(exif.dateTaken, df.date(from: "2026:01:15 14:30:00"))
    }

    func testDateTakenWithOffset() throws {
        let url = try writeImage(name: "dateoffset.jpg", metadata: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:01:15 14:30:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
            ] as [CFString: Any]
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.offsetTimeOriginal, "+09:00")
        XCTAssertNotNil(exif.dateTaken)

        let tzdf = DateFormatter()
        tzdf.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
        tzdf.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(exif.dateTaken, tzdf.date(from: "2026:01:15 14:30:00+09:00"))
    }

    // MARK: - GPS

    func testGPSNorthEast() throws {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 35.6895,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.6917,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let url = try writeImage(name: "gpsne.jpg", metadata: [
            kCGImagePropertyGPSDictionary: gps
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.latitude ?? 0, 35.6895, accuracy: 0.0001)
        XCTAssertEqual(exif.longitude ?? 0, 139.6917, accuracy: 0.0001)
    }

    func testGPSSouthWestNegated() throws {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 33.8688,
            kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 70.6483,
            kCGImagePropertyGPSLongitudeRef: "W",
        ]
        let url = try writeImage(name: "gpssw.jpg", metadata: [
            kCGImagePropertyGPSDictionary: gps
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.latitude ?? 0, -33.8688, accuracy: 0.0001, "S latitude negated")
        XCTAssertEqual(exif.longitude ?? 0, -70.6483, accuracy: 0.0001, "W longitude negated")
    }

    func testGPSMissingRefLeavesNil() throws {
        // Latitude present but no ref => guard fails => stays nil.
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 10.0,
        ]
        let url = try writeImage(name: "gpsnoref.jpg", metadata: [
            kCGImagePropertyGPSDictionary: gps
        ])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertNil(exif.latitude)
        XCTAssertNil(exif.longitude)
    }

    // MARK: - Empty metadata defaults

    func testEmptyMetadataYieldsMostlyNil() throws {
        let url = try writeImage(name: "bare.jpg", metadata: [:])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertNil(exif.cameraMake)
        XCTAssertNil(exif.lensModel)
        XCTAssertNil(exif.shutterSpeed)
        XCTAssertNil(exif.iso)
        XCTAssertNil(exif.dateTaken)
        XCTAssertNil(exif.latitude)
        // But dimensions are always derivable.
        XCTAssertNotNil(exif.pixelWidth)
        XCTAssertNotNil(exif.pixelHeight)
    }

    // MARK: - Source-based overload

    func testReadFromCGImageSourceMatchesURL() throws {
        let url = try writeImage(name: "source.jpg", metadata: [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFModel: "ZV-E1"
            ] as [CFString: Any]
        ])
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw XCTSkip("could not create source")
        }
        let exif = EXIFService.readEXIF(from: src)
        XCTAssertEqual(exif.cameraModel, "ZV-E1")
        XCTAssertEqual(exif.pixelWidth, 8)
    }

    // MARK: - Real fixture

    func testRealFixtureReadsDimensions() throws {
        let fixture = fixturesDir.appendingPathComponent("photo_01.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path),
                          "E2E fixture missing")
        let exif = EXIFService.readEXIF(from: fixture)
        // A real JPEG must at least have dimensions.
        XCTAssertNotNil(exif.pixelWidth)
        XCTAssertNotNil(exif.pixelHeight)
        XCTAssertGreaterThan(exif.pixelWidth ?? 0, 0)
        XCTAssertGreaterThan(exif.pixelHeight ?? 0, 0)
    }
}
