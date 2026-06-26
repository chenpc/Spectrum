import XCTest
import Foundation
@testable import Spectrum

/// Deep coverage for FolderReader plus full coverage of URL+ImageTypes and Date+Formatting.
final class FolderReaderExtraTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderReaderExtraTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // FileManager canonicalizes paths (/var -> /private/var) when listing directory
        // contents. `resolvingSymlinksInPath()` is unreliable for the /var<->/private/var
        // symlink on macOS, so use realpath(3) to get the true canonical path and keep
        // expected paths in sync with what FolderReader returns.
        if let resolved = realpath(tmpDir.path, nil) {
            tmpDir = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
    }

    override func tearDownWithError() throws {
        if let tmpDir, FileManager.default.fileExists(atPath: tmpDir.path) {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
    }

    // MARK: - Fixture helpers

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SpectrumUITests/E2EFixtures")
    }

    /// Copy a real JPEG fixture into `dir` under the given name. Skips test if missing.
    @discardableResult
    private func copyJPEG(_ fixtureName: String, to dir: URL, named newName: String) throws -> URL {
        let src = fixturesDir.appendingPathComponent(fixtureName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "fixture \(fixtureName) missing")
        let dst = dir.appendingPathComponent(newName)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    /// Write a placeholder file with arbitrary bytes (used for video/non-media types
    /// whose classification depends only on the extension via UTType).
    @discardableResult
    private func writeFile(_ name: String, in dir: URL, bytes: Data = Data([0x00, 0x01, 0x02])) throws -> URL {
        let dst = dir.appendingPathComponent(name)
        try bytes.write(to: dst)
        return dst
    }

    // MARK: - URL+ImageTypes: isImageFile / RAW

    func testIsImageFile_commonImageExtensions() {
        for ext in ["jpg", "jpeg", "png", "heic", "tiff", "gif"] {
            let url = URL(fileURLWithPath: "/x/file.\(ext)")
            XCTAssertTrue(url.isImageFile, "\(ext) should be an image")
            XCTAssertFalse(url.isVideoFile, "\(ext) should not be a video")
            XCTAssertTrue(url.isMediaFile)
        }
    }

    func testIsCameraRawFile_allRawExtensions() {
        for ext in URL.rawPhotoExtensions {
            let lower = URL(fileURLWithPath: "/x/photo.\(ext)")
            XCTAssertTrue(lower.isCameraRawFile, "\(ext) should be RAW")
            XCTAssertTrue(lower.isImageFile, "RAW \(ext) should be image")
            XCTAssertTrue(lower.isMediaFile)
            // Case-insensitive
            let upper = URL(fileURLWithPath: "/x/photo.\(ext.uppercased())")
            XCTAssertTrue(upper.isCameraRawFile, "\(ext.uppercased()) should be RAW (case-insensitive)")
        }
    }

    func testIsCameraRawFile_negative() {
        XCTAssertFalse(URL(fileURLWithPath: "/x/file.jpg").isCameraRawFile)
        XCTAssertFalse(URL(fileURLWithPath: "/x/file.txt").isCameraRawFile)
        XCTAssertFalse(URL(fileURLWithPath: "/x/noext").isCameraRawFile)
    }

    // MARK: - URL+ImageTypes: isVideoFile

    func testIsVideoFile_videoExtensions() {
        for ext in ["mov", "mp4", "m4v"] {
            let url = URL(fileURLWithPath: "/x/clip.\(ext)")
            XCTAssertTrue(url.isVideoFile, "\(ext) should be a video")
            XCTAssertFalse(url.isImageFile, "\(ext) should not be an image")
            XCTAssertTrue(url.isMediaFile)
        }
    }

    func testIsMediaFile_nonMedia() {
        for ext in ["txt", "json", "xmp", "unknownext"] {
            let url = URL(fileURLWithPath: "/x/file.\(ext)")
            XCTAssertFalse(url.isImageFile, "\(ext) image")
            XCTAssertFalse(url.isVideoFile, "\(ext) video")
            XCTAssertFalse(url.isMediaFile, "\(ext) media")
        }
    }

    func testIsMediaFile_noExtension() {
        let url = URL(fileURLWithPath: "/x/README")
        XCTAssertFalse(url.isImageFile)
        XCTAssertFalse(url.isVideoFile)
        XCTAssertFalse(url.isMediaFile)
    }

    // MARK: - URL+ImageTypes: isSkippedCameraDirectory

    func testIsSkippedCameraDirectory_skipped() {
        for name in ["THMBNL", "SUB", "TAKE", "GENERAL", "DATABASE", "AVF_INFO"] {
            let url = URL(fileURLWithPath: "/cam/\(name)")
            XCTAssertTrue(url.isSkippedCameraDirectory, "\(name) should be skipped")
        }
    }

    func testIsSkippedCameraDirectory_notSkipped() {
        for name in ["Photos", "thmbnl", "Sub", "MyFolder", "AVF"] {
            let url = URL(fileURLWithPath: "/cam/\(name)")
            XCTAssertFalse(url.isSkippedCameraDirectory,
                           "\(name) should NOT be skipped (case-sensitive exact match)")
        }
    }

    // MARK: - Date+Formatting

    func testFormatDuration_branches() {
        XCTAssertEqual(formatDuration(0), "0:00")
        XCTAssertEqual(formatDuration(5), "0:05")
        XCTAssertEqual(formatDuration(65), "1:05")
        XCTAssertEqual(formatDuration(600), "10:00")
        // Hours branch
        XCTAssertEqual(formatDuration(3661), "1:01:01")
        XCTAssertEqual(formatDuration(3600), "1:00:00")
        // Truncation of fractional seconds
        XCTAssertEqual(formatDuration(59.9), "0:59")
    }

    func testDateFormattingProducesNonEmpty() {
        // Fixed reference date: 2026-06-26 12:34:56 UTC-ish — only assert non-empty &
        // that monthYearKey is yyyy-MM-dd shaped (locale-independent format string).
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertFalse(date.timelineLabel.isEmpty)
        XCTAssertFalse(date.shortDate.isEmpty)

        let key = date.monthYearKey
        XCTAssertEqual(key.count, 10, "yyyy-MM-dd is 10 chars")
        let parts = key.split(separator: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 4)
        XCTAssertEqual(parts[1].count, 2)
        XCTAssertEqual(parts[2].count, 2)
        XCTAssertTrue(key.allSatisfy { $0.isNumber || $0 == "-" })
    }

    // MARK: - FolderReader.listLevel — empty / nonexistent

    func testListLevel_nonexistentFolder() {
        let items = FolderReader.listLevel(folderPath: tmpDir.appendingPathComponent("nope").path,
                                           bookmarkData: nil)
        XCTAssertTrue(items.isEmpty)
    }

    func testListLevel_emptyFolder() {
        let items = FolderReader.listLevel(folderPath: tmpDir.path, bookmarkData: nil)
        XCTAssertTrue(items.isEmpty)
    }

    func testListLevel_ignoresNonMediaAndSorts() throws {
        try copyJPEG("photo_01.jpg", to: tmpDir, named: "a.jpg")
        try copyJPEG("photo_02.jpg", to: tmpDir, named: "b.jpg")
        // Non-media files must be ignored
        try writeFile("notes.txt", in: tmpDir)
        try writeFile("data.json", in: tmpDir)

        let items = FolderReader.listLevel(folderPath: tmpDir.path, bookmarkData: nil)
        XCTAssertEqual(items.count, 2, "only the two jpgs count")
        XCTAssertTrue(items.allSatisfy { !$0.isVideo })

        // Sorted by dateTaken descending.
        for i in 1..<items.count {
            XCTAssertGreaterThanOrEqual(items[i - 1].dateTaken, items[i].dateTaken)
        }
        // Each PhotoItem has the file fields filled in.
        for item in items {
            XCTAssertGreaterThan(item.fileSize, 0)
            XCTAssertFalse(item.fileName.isEmpty)
            XCTAssertTrue(item.filePath.hasPrefix(tmpDir.path))
        }
    }

    // MARK: - FolderReader.listLevel — Live Photo pairing

    func testListLevel_livePhotoPairing() throws {
        // image + matching .mov basename => folded into one item with livePhotoMovPath
        try copyJPEG("photo_01.jpg", to: tmpDir, named: "IMG_100.jpg")
        let movURL = try writeFile("IMG_100.mov", in: tmpDir)

        let items = FolderReader.listLevel(folderPath: tmpDir.path, bookmarkData: nil)
        XCTAssertEqual(items.count, 1, "paired mov is folded into the image, not a separate item")
        let item = try XCTUnwrap(items.first)
        XCTAssertFalse(item.isVideo)
        XCTAssertEqual(item.livePhotoMovPath, movURL.path)
    }

    func testListLevel_standaloneMovNotPaired() throws {
        // .mov with no matching image basename => standalone video item
        try writeFile("CLIP_A.mov", in: tmpDir)
        try copyJPEG("photo_03.jpg", to: tmpDir, named: "PIC.jpg")

        let items = FolderReader.listLevel(folderPath: tmpDir.path, bookmarkData: nil)
        XCTAssertEqual(items.count, 2)
        let video = items.first { $0.isVideo }
        XCTAssertNotNil(video, "standalone mov should appear as a video item")
        XCTAssertNil(video?.livePhotoMovPath)
        let image = items.first { !$0.isVideo }
        XCTAssertNil(image?.livePhotoMovPath, "unpaired image has no live mov")
    }

    func testListLevel_otherVideoFormats() throws {
        try writeFile("movie.mp4", in: tmpDir)
        try writeFile("clip.m4v", in: tmpDir)

        let items = FolderReader.listLevel(folderPath: tmpDir.path, bookmarkData: nil)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.isVideo })
        XCTAssertTrue(items.allSatisfy { $0.livePhotoMovPath == nil })
    }

    func testListLevel_mixedContent() throws {
        try copyJPEG("photo_01.jpg", to: tmpDir, named: "IMG_1.jpg")
        try copyJPEG("photo_02.jpg", to: tmpDir, named: "IMG_2.jpg")
        try writeFile("IMG_1.mov", in: tmpDir)     // live companion of IMG_1
        try writeFile("standalone.mov", in: tmpDir) // standalone
        try writeFile("reel.mp4", in: tmpDir)       // other video
        try writeFile("ignore.txt", in: tmpDir)     // non-media

        let items = FolderReader.listLevel(folderPath: tmpDir.path, bookmarkData: nil)
        // 2 images (one with live companion) + standalone mov + mp4 = 4
        XCTAssertEqual(items.count, 4)
        let images = items.filter { !$0.isVideo }
        let videos = items.filter { $0.isVideo }
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(videos.count, 2)
        XCTAssertEqual(images.filter { $0.livePhotoMovPath != nil }.count, 1)
    }

    // MARK: - FolderReader.listSubfolders

    func testListSubfolders_empty() {
        let result = FolderReader.listSubfolders(folderPath: tmpDir.path, bookmarkData: nil)
        XCTAssertTrue(result.isEmpty)
    }

    func testListSubfolders_nonexistent() {
        let result = FolderReader.listSubfolders(
            folderPath: tmpDir.appendingPathComponent("nope").path, bookmarkData: nil)
        XCTAssertTrue(result.isEmpty)
    }

    func testListSubfolders_skipsCameraDirsAndDetectsCover() throws {
        // Real subfolder with images
        let sub = tmpDir.appendingPathComponent("Vacation")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try copyJPEG("photo_04.jpg", to: sub, named: "zzz_last.jpg")
        try copyJPEG("photo_05.jpg", to: sub, named: "aaa_first.jpg")

        // Skipped camera dir — must not appear
        let skipped = tmpDir.appendingPathComponent("THMBNL")
        try FileManager.default.createDirectory(at: skipped, withIntermediateDirectories: true)
        try writeFile("thumb.jpg", in: skipped)

        // A plain file at top level should be ignored (only directories returned)
        try writeFile("top.txt", in: tmpDir)

        let result = FolderReader.listSubfolders(folderPath: tmpDir.path, bookmarkData: nil)
        XCTAssertEqual(result.count, 1, "THMBNL skipped, only Vacation returned")
        let entry = try XCTUnwrap(result.first)
        XCTAssertEqual(entry.name, "Vacation")
        XCTAssertEqual(entry.path, sub.path)
        // Cover is the alphabetically-first image file.
        XCTAssertEqual(URL(fileURLWithPath: entry.coverPath ?? "").lastPathComponent, "aaa_first.jpg")
        XCTAssertNotNil(entry.coverDate)
    }

    func testListSubfolders_coverFallbackToVideoWhenNoImage() throws {
        let sub = tmpDir.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile("only.mp4", in: sub)
        try writeFile("readme.txt", in: sub) // non-media ignored

        let result = FolderReader.listSubfolders(folderPath: tmpDir.path, bookmarkData: nil)
        let entry = try XCTUnwrap(result.first { $0.name == "Clips" })
        XCTAssertEqual(URL(fileURLWithPath: entry.coverPath ?? "").lastPathComponent, "only.mp4",
                       "falls back to any media file when no image exists")
    }

    func testListSubfolders_noCoverWhenNoMedia() throws {
        let sub = tmpDir.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile("a.txt", in: sub)

        let result = FolderReader.listSubfolders(folderPath: tmpDir.path, bookmarkData: nil)
        let entry = try XCTUnwrap(result.first { $0.name == "Docs" })
        XCTAssertNil(entry.coverPath)
        XCTAssertNil(entry.coverDate)
    }
}
