import XCTest
import Foundation
import AVFoundation
@testable import Spectrum

final class VideoMetadataServiceUnitTests: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SpectrumUITests/E2EFixtures")
    }

    private var videoURL: URL {
        fixturesDir.appendingPathComponent("video_01.mp4")
    }

    // MARK: - VideoMetadata struct defaults

    func testVideoMetadata_defaultsAreNil() {
        let meta = VideoMetadata()
        XCTAssertNil(meta.duration)
        XCTAssertNil(meta.pixelWidth)
        XCTAssertNil(meta.pixelHeight)
        XCTAssertNil(meta.videoCodec)
        XCTAssertNil(meta.audioCodec)
        XCTAssertNil(meta.creationDate)
        XCTAssertNil(meta.latitude)
        XCTAssertNil(meta.longitude)
    }

    func testVideoMetadata_fieldsAreMutable() {
        var meta = VideoMetadata()
        meta.duration = 12.5
        meta.pixelWidth = 1920
        meta.pixelHeight = 1080
        meta.videoCodec = "hvc1"
        meta.audioCodec = "aac"
        meta.latitude = 35.0
        meta.longitude = 139.0
        XCTAssertEqual(meta.duration, 12.5)
        XCTAssertEqual(meta.pixelWidth, 1920)
        XCTAssertEqual(meta.pixelHeight, 1080)
        XCTAssertEqual(meta.videoCodec, "hvc1")
        XCTAssertEqual(meta.audioCodec, "aac")
        XCTAssertEqual(meta.latitude, 35.0)
        XCTAssertEqual(meta.longitude, 139.0)
    }

    // MARK: - Real fixture

    func testReadMetadata_realVideo_durationAndDimensions() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: videoURL.path),
                          "Fixture video_01.mp4 not present")

        let meta = await VideoMetadataService.readMetadata(from: videoURL)

        // Duration should be a finite positive value.
        let duration = try XCTUnwrap(meta.duration, "Expected a duration for a real video")
        XCTAssertTrue(duration.isFinite)
        XCTAssertGreaterThan(duration, 0)

        // A real video track should yield positive dimensions.
        let width = try XCTUnwrap(meta.pixelWidth, "Expected pixelWidth")
        let height = try XCTUnwrap(meta.pixelHeight, "Expected pixelHeight")
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)

        // Video codec should be a non-empty four-char code string.
        let codec = try XCTUnwrap(meta.videoCodec, "Expected a video codec")
        XCTAssertFalse(codec.isEmpty)
        // FourCC strings are at most 4 chars after trimming.
        XCTAssertLessThanOrEqual(codec.count, 4)
    }

    func testReadMetadata_realVideo_dimensionsMatchAsset() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: videoURL.path),
                          "Fixture video_01.mp4 not present")

        let meta = await VideoMetadataService.readMetadata(from: videoURL)

        // Cross-check against AVFoundation directly (accounting for transform).
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let transformed = size.applying(transform)

        XCTAssertEqual(meta.pixelWidth, Int(abs(transformed.width)))
        XCTAssertEqual(meta.pixelHeight, Int(abs(transformed.height)))
    }

    func testReadMetadata_isDeterministic() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: videoURL.path),
                          "Fixture video_01.mp4 not present")

        let a = await VideoMetadataService.readMetadata(from: videoURL)
        let b = await VideoMetadataService.readMetadata(from: videoURL)
        XCTAssertEqual(a.duration, b.duration)
        XCTAssertEqual(a.pixelWidth, b.pixelWidth)
        XCTAssertEqual(a.pixelHeight, b.pixelHeight)
        XCTAssertEqual(a.videoCodec, b.videoCodec)
        XCTAssertEqual(a.audioCodec, b.audioCodec)
    }

    // MARK: - Failure / nil paths

    func testReadMetadata_bogusURL_returnsEmptyMetadata() async {
        let bogus = URL(fileURLWithPath: "/no/such/dir/\(UUID().uuidString).mp4")
        let meta = await VideoMetadataService.readMetadata(from: bogus)

        // Nothing should load for a non-existent file.
        XCTAssertNil(meta.duration)
        XCTAssertNil(meta.pixelWidth)
        XCTAssertNil(meta.pixelHeight)
        XCTAssertNil(meta.videoCodec)
        XCTAssertNil(meta.audioCodec)
        XCTAssertNil(meta.creationDate)
        XCTAssertNil(meta.latitude)
        XCTAssertNil(meta.longitude)
    }

    func testReadMetadata_nonVideoFile_returnsNoTracks() async throws {
        // Write a bogus non-media file into a unique temp dir.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeURL = tmpDir.appendingPathComponent("not_a_video.mp4")
        try Data("this is not a video".utf8).write(to: fakeURL)

        let meta = await VideoMetadataService.readMetadata(from: fakeURL)

        // No decodable video/audio tracks → codec/dimension fields stay nil.
        XCTAssertNil(meta.pixelWidth)
        XCTAssertNil(meta.pixelHeight)
        XCTAssertNil(meta.videoCodec)
        XCTAssertNil(meta.audioCodec)
    }
}
