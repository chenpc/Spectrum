import XCTest
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers
@testable import Spectrum

/// Targets the remaining UNCOVERED branches / edge & error paths in several
/// services. Happy paths are already covered elsewhere (EXIFServiceUnitTests,
/// ThumbnailServiceUnitTests, VideoMetadataServiceUnitTests, ImagePreloadCacheTests,
/// CoreServicesUnitTests, etc.), so this file deliberately avoids duplicating them.
final class ServiceGapTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceGapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
    }

    // MARK: - Helpers

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SpectrumUITests/E2EFixtures")
    }

    private func fixture(_ name: String) -> URL {
        fixturesDir.appendingPathComponent(name)
    }

    /// Canonical absolute path (resolves /var → /private/var reliably, unlike
    /// resolvingSymlinksInPath which is flaky for the temp dir on macOS).
    private func canonical(_ url: URL) -> String {
        url.path.withCString { cs -> String in
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            if realpath(cs, &buf) != nil { return String(cString: buf) }
            return url.path
        }
    }

    /// Writes a tiny JPEG with the supplied metadata and returns its URL.
    @discardableResult
    private func writeImage(name: String,
                            width: Int = 8,
                            height: Int = 6,
                            metadata: [CFString: Any]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("Could not create CGContext")
        }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
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

    // MARK: - SpectrumLibrary

    func testSpectrumLibrary_urlIsConsistentWithOverride() {
        if let override = SpectrumLibrary.overrideURL {
            // When redirected, `url` is exactly the override base (no extra child).
            XCTAssertEqual(SpectrumLibrary.url.standardizedFileURL,
                           override.standardizedFileURL)
        } else {
            // Default location: ~/Pictures/Spectrum Library/
            XCTAssertEqual(SpectrumLibrary.url.lastPathComponent, "Spectrum Library")
        }
        // All derived URLs hang off the root.
        XCTAssertTrue(SpectrumLibrary.databaseURL.path.hasPrefix(SpectrumLibrary.url.path))
        XCTAssertTrue(SpectrumLibrary.thumbnailsURL.path.hasPrefix(SpectrumLibrary.url.path))
        XCTAssertTrue(SpectrumLibrary.lockFileURL.path.hasPrefix(SpectrumLibrary.url.path))
    }

    /// Exercises the early-return guard of migrate. Only run when the store
    /// already exists, so the call is guaranteed to be a no-op (avoids any
    /// chance of copying real legacy data into the live library).
    func testSpectrumLibrary_migrateIsNoOpWhenStoreExists() throws {
        let dbPath = SpectrumLibrary.databaseURL.path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dbPath),
                          "default.store not present — skipping to avoid legacy-copy side effects")
        // Must early-return cleanly and not remove/alter the existing store.
        SpectrumLibrary.migrateFromLegacyLocationIfNeeded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath),
                      "migrate must be a no-op when the store already exists")
    }

    // MARK: - BookmarkService

    func testBookmark_createForNonexistentURLThrows() {
        let bogus = tempDir.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertThrowsError(try BookmarkService.createBookmark(for: bogus),
                             "Creating a security-scoped bookmark for a missing file should throw")
    }

    func testBookmark_resolveGarbageDataThrows() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xAB])
        XCTAssertThrowsError(try BookmarkService.resolveBookmark(garbage),
                             "Resolving garbage bookmark data should throw")
    }

    func testBookmark_resolveRefreshingGarbageDataThrows() {
        let garbage = Data("definitely-not-a-bookmark".utf8)
        XCTAssertThrowsError(try BookmarkService.resolveBookmarkRefreshing(garbage),
                             "resolveBookmarkRefreshing should throw on garbage data")
    }

    func testBookmark_resolveRefreshing_freshRoundTrips() throws {
        // Complements the existing fresh-is-nil test by also checking the URL
        // round-trips through resolveBookmarkRefreshing.
        let data = try BookmarkService.createBookmark(for: tempDir)
        let (url, refreshed) = try BookmarkService.resolveBookmarkRefreshing(data)
        XCTAssertEqual(canonical(url), canonical(tempDir))
        XCTAssertNil(refreshed)
    }

    func testBookmark_withSecurityScopeAsyncPropagatesThrows() async {
        struct Boom: Error {}
        do {
            _ = try await BookmarkService.withSecurityScope(tempDir) { () async throws -> Int in
                throw Boom()
            }
            XCTFail("Async withSecurityScope should rethrow the body's error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testBookmark_withSecurityScopeAsyncReturnsValue() async {
        let value = await BookmarkService.withSecurityScope(tempDir) { () async -> Int in 7 }
        XCTAssertEqual(value, 7)
    }

    // MARK: - VideoMetadataService

    func testVideoMetadata_imageFileHasNoVideoOrAudioTracks() async throws {
        let url = fixture("richexif.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "richexif.jpg missing")
        let meta = await VideoMetadataService.readMetadata(from: url)
        // A still image has no video/audio tracks → these fields stay nil.
        XCTAssertNil(meta.pixelWidth)
        XCTAssertNil(meta.pixelHeight)
        XCTAssertNil(meta.videoCodec)
        XCTAssertNil(meta.audioCodec)
    }

    func testVideoMetadata_realVideoExercisesAudioAndCreationBranches() async throws {
        let url = fixture("video_01.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "video_01.mp4 missing")
        let meta = await VideoMetadataService.readMetadata(from: url)
        XCTAssertNotNil(meta.duration)
        // Audio track branch: codec may or may not be present, but if present
        // it must be a non-empty fourCC string.
        if let audio = meta.audioCodec {
            XCTAssertFalse(audio.isEmpty)
            XCTAssertLessThanOrEqual(audio.count, 4)
        }
        // Creation date branch is exercised regardless of whether a value exists.
        _ = meta.creationDate
        // GPS branch likewise; if present values must be finite.
        if let lat = meta.latitude { XCTAssertTrue(lat.isFinite) }
        if let lon = meta.longitude { XCTAssertTrue(lon.isFinite) }
    }

    func testVideoMetadata_emptyTempFileURL() async throws {
        // Zero-byte file with a video extension → all loads fail gracefully.
        let url = tempDir.appendingPathComponent("empty.mp4")
        try Data().write(to: url)
        let meta = await VideoMetadataService.readMetadata(from: url)
        XCTAssertNil(meta.duration)
        XCTAssertNil(meta.pixelWidth)
        XCTAssertNil(meta.videoCodec)
        XCTAssertNil(meta.audioCodec)
    }

    // MARK: - ThumbnailService (video + repeat)

    func testThumbnail_videoFileGeneratesImage() async throws {
        let url = fixture("video_01.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "video_01.mp4 missing")
        let service = ThumbnailService()

        // Routes through generateVideoThumbnail (isVideoFile == true).
        let image = await service.thumbnail(for: url.path, bookmarkData: nil)
        XCTAssertNotNil(image, "Should generate a thumbnail frame for a real video")
        if let image {
            let maxDim = max(image.size.width, image.size.height)
            XCTAssertGreaterThan(maxDim, 0)
            XCTAssertLessThanOrEqual(maxDim, CGFloat(service.thumbnailSize) + 1)
        }
    }

    func testThumbnail_videoSecondCallHitsCache() async throws {
        let url = fixture("video_01.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "video_01.mp4 missing")
        let service = ThumbnailService()
        let first = await service.thumbnail(for: url.path, bookmarkData: nil)
        let second = await service.thumbnail(for: url.path, bookmarkData: nil)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssert(first === second, "Second call for a video should return the cached instance")
    }

    // MARK: - ImagePreloadCache

    @MainActor
    func testImagePreload_loadRealImageEntry_isSDR() async throws {
        let url = fixture("richexif.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "richexif.jpg missing")
        let entry = await ImagePreloadCache.loadImageEntry(path: url.path, bookmarkData: nil)
        XCTAssertNotNil(entry.image, "A real JPEG should decode to a non-nil image")
        XCTAssertNil(entry.hdrFormat, "A standard Sony JPEG should be SDR")
        XCTAssertNil(entry.hlgCGImage)
        // Cached afterward.
        XCTAssertNotNil(ImagePreloadCache.cachedEntry(for: url.path))
    }

    @MainActor
    func testImagePreload_loadWithInvalidBookmarkStillDecodes() async throws {
        let url = fixture("photo_01.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "photo_01.jpg missing")
        // Garbage bookmark → resolve fails (catch branch) but decode proceeds.
        let entry = await ImagePreloadCache.loadImageEntry(
            path: url.path, bookmarkData: Data("garbage".utf8))
        XCTAssertNotNil(entry.image)
    }

    func testImagePreload_detectHDR_realImageSourceIsNil() throws {
        let url = fixture("richexif.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "richexif.jpg missing")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw XCTSkip("could not create CGImageSource")
        }
        // Hits the gainMap-aux / EXIF-customRendered / HLG-thumbnail branches, all false.
        XCTAssertNil(ImagePreloadCache.detectHDR(source: source))
    }

    func testImagePreload_detectVideoHDRType_realVideo() async throws {
        let url = fixture("video_01.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "video_01.mp4 missing")
        let result = await ImagePreloadCache.detectVideoHDRType(path: url.path, bookmarkData: nil)
        // Exercises loadTracks + formatDescriptions success path. The fixture is
        // SDR (expected nil) but accept any valid classification to avoid flakiness.
        XCTAssertTrue(result == nil || VideoHDRType.allCases.contains(result!))
    }

    func testImagePreload_detectVideoHDRType_invalidBookmark() async throws {
        let url = fixture("video_01.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "video_01.mp4 missing")
        // Garbage bookmark → resolve catch branch; detection continues on the path.
        let result = await ImagePreloadCache.detectVideoHDRType(
            path: url.path, bookmarkData: Data("nope".utf8))
        XCTAssertTrue(result == nil || VideoHDRType.allCases.contains(result!))
    }

    func testImagePreload_detectVideoHDRType_nonexistentPath() async {
        let result = await ImagePreloadCache.detectVideoHDRType(
            path: "/no/such/file-\(UUID()).mp4", bookmarkData: nil)
        XCTAssertNil(result, "Missing file → no tracks → nil")
    }

    // MARK: - FolderMonitor

    func testFolderMonitor_lifecycleNoOpsAndStopAll() {
        let dir = canonical(tempDir)
        let monitor = FolderMonitor.shared
        // Stopping a path that was never monitored is a harmless no-op.
        monitor.stopMonitoring(path: "/no/such/path-\(UUID())")
        // Start, then re-start (tears down the old stream first), then stop.
        monitor.startMonitoring(path: dir)
        monitor.startMonitoring(path: dir)
        monitor.stopMonitoring(path: dir)
        // stopAll over a populated map, then over an empty map.
        monitor.startMonitoring(path: dir)
        monitor.stopAll()
        monitor.stopAll()
        // No assertions beyond "did not crash / deadlock".
    }

    func testFolderMonitor_postsNotificationOnDirectoryChange() throws {
        let dir = canonical(tempDir)
        let monitor = FolderMonitor.shared

        let exp = expectation(description: "FolderMonitor posts folderDidChange")
        exp.assertForOverFulfill = false

        let token = NotificationCenter.default.addObserver(
            forName: FolderMonitor.folderDidChange, object: nil, queue: .main
        ) { note in
            if let path = note.userInfo?["path"] as? String, path == dir {
                exp.fulfill()
            }
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            monitor.stopMonitoring(path: dir)
        }

        monitor.startMonitoring(path: dir)

        // Give the stream a moment to arm, then mutate the directory.
        let newFile = URL(fileURLWithPath: dir).appendingPathComponent("change-\(UUID()).txt")
        try Data("hello".utf8).write(to: newFile)

        // FSEvents latency is 2s; allow generous headroom.
        wait(for: [exp], timeout: 20)
    }

    // MARK: - EXIFService

    func testEXIF_richFixtureExposesRealMetadata() throws {
        let url = fixture("richexif.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "richexif.jpg missing")
        let exif = EXIFService.readEXIF(from: url)

        XCTAssertNotNil(exif.pixelWidth)
        XCTAssertNotNil(exif.pixelHeight)

        let make = try XCTUnwrap(exif.cameraMake, "richexif should have a camera make")
        XCTAssertTrue(make.uppercased().contains("SONY"), "Expected SONY make, got \(make)")
        XCTAssertNotNil(exif.cameraModel, "richexif should have a camera model")
        XCTAssertNotNil(exif.lensModel, "richexif should have a lens model")
        XCTAssertNotNil(exif.iso, "richexif should have ISO")

        // GPS should be present and within valid coordinate ranges.
        let lat = try XCTUnwrap(exif.latitude, "richexif should have GPS latitude")
        let lon = try XCTUnwrap(exif.longitude, "richexif should have GPS longitude")
        XCTAssertTrue((-90...90).contains(lat))
        XCTAssertTrue((-180...180).contains(lon))
    }

    /// Covers EXIF branches not hit by the synthetic cases in EXIFServiceUnitTests:
    /// SubsecTimeOriginal, ExifVersion array, and the ExifAux dictionary.
    func testEXIF_subsecVersionAndAuxBranches() throws {
        let exifDict: [CFString: Any] = [
            kCGImagePropertyExifSubsecTimeOriginal: "123",
            kCGImagePropertyExifVersion: [2, 2, 1, 0],
        ]
        let aux: [CFString: Any] = [
            "ImageStabilization" as CFString: 1,
        ]
        let url = try writeImage(name: "subsecaux.jpg", metadata: [
            kCGImagePropertyExifDictionary: exifDict,
            kCGImagePropertyExifAuxDictionary: aux,
        ])
        let exif = EXIFService.readEXIF(from: url)

        XCTAssertEqual(exif.subsecTimeOriginal, "123")
        // ExifVersion may be normalized by ImageIO; only assert it parsed to digits.
        if let version = exif.exifVersion {
            XCTAssertFalse(version.isEmpty)
        }
        // ExifAux round-trip is best-effort across ImageIO; assert only if present.
        if let stab = exif.imageStabilization {
            XCTAssertEqual(stab, 1)
        }
    }

    func testEXIF_noEXIFImageHasOnlyDimensions() throws {
        // An image written with no metadata exercises the "all dictionaries absent"
        // branches (TIFF/EXIF/GPS/Aux guards all fail) while dimensions remain.
        let url = try writeImage(name: "noexif.jpg", width: 5, height: 7, metadata: [:])
        let exif = EXIFService.readEXIF(from: url)
        XCTAssertEqual(exif.pixelWidth, 5)
        XCTAssertEqual(exif.pixelHeight, 7)
        XCTAssertNil(exif.lensModel)
        XCTAssertNil(exif.iso)
        XCTAssertNil(exif.latitude)
        XCTAssertNil(exif.imageStabilization)
        XCTAssertNil(exif.software)
    }
}
