import XCTest
import SwiftData
import Foundation
@testable import Spectrum

/// Unit tests for `FolderScanner` (a SwiftData @ModelActor) driving the public
/// scan entry points against a temp folder populated with real E2E fixtures.
///
/// The host app is NOT sandboxed, so creating/resolving security-scoped
/// bookmarks for a real temp directory works; if the environment forbids it,
/// the affected test skips rather than fails.
final class FolderScannerUnitTests: XCTestCase {

    private var container: ModelContainer!
    private var tempDir: URL!

    // MARK: - Fixtures

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SpectrumTests/
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("SpectrumUITests/E2EFixtures")
    }

    private func requireFixture(_ name: String) throws -> URL {
        let url = fixturesDir.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "Missing fixture: \(url.path)")
        return url
    }

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        let schema = Schema([Photo.self, ScannedFolder.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])

        // Canonicalize via realpath so the stored path matches the
        // bookmark-resolved canonical path (/var -> /private/var on macOS).
        // NOTE: URL.resolvingSymlinksInPath() does the OPPOSITE here — it
        // strips /private, yielding /var/... which never matches the
        // bookmark-resolved /private/var/... that FolderScanner stores.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScannerUnitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDir = Self.canonicalURL(base)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        container = nil
    }

    // MARK: - Helpers

    /// Fully resolve symlinks to the true canonical path (e.g. /var -> /private/var)
    /// using realpath(3). The directory must already exist.
    private static func canonicalURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Copy a fixture into a destination directory under a new name.
    @discardableResult
    private func copyFixture(_ fixtureName: String, to dir: URL, as newName: String) throws -> URL {
        let src = try requireFixture(fixtureName)
        let dst = dir.appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    /// Create a ScannedFolder row for `url`, save it, and return its identifier.
    /// Skips the test if a security-scoped bookmark cannot be created.
    private func makeFolder(at url: URL) throws -> PersistentIdentifier {
        let bookmark: Data
        do {
            bookmark = try BookmarkService.createBookmark(for: url)
        } catch {
            throw XCTSkip("Cannot create security-scoped bookmark here: \(error)")
        }
        let ctx = ModelContext(container)
        let folder = ScannedFolder(path: url.path, bookmarkData: bookmark)
        ctx.insert(folder)
        try ctx.save()
        return folder.persistentModelID
    }

    /// Fetch all photos via a fresh context (sees the actor's committed writes).
    private func fetchPhotos() throws -> [Photo] {
        try ModelContext(container).fetch(FetchDescriptor<Photo>())
    }

    private func fetchFolders() throws -> [ScannedFolder] {
        try ModelContext(container).fetch(FetchDescriptor<ScannedFolder>())
    }

    // MARK: - scanFolderDeep

    func testScanFolderDeep_insertsAllImages() async throws {
        try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        try copyFixture("photo_02.jpg", to: tempDir, as: "b.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolderDeep(id: id)

        let photos = try fetchPhotos()
        XCTAssertEqual(photos.count, 2, "Both copied images should be inserted")
        let names = Set(photos.map(\.fileName))
        XCTAssertEqual(names, ["a.jpg", "b.jpg"])
        XCTAssertTrue(photos.allSatisfy { $0.filePath.hasPrefix(tempDir.path + "/") })
        XCTAssertTrue(photos.allSatisfy { !$0.isVideo })
    }

    func testScanFolderDeep_idempotentOnRescan() async throws {
        try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        try copyFixture("photo_02.jpg", to: tempDir, as: "b.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolderDeep(id: id)
        try await scanner.scanFolderDeep(id: id)

        // Deep scan deletes existing rows for the folder before reinserting,
        // so the count must remain stable (and unique constraint not violated).
        XCTAssertEqual(try fetchPhotos().count, 2, "Re-scan should be idempotent")
    }

    func testScanFolderDeep_recursesIntoSubdirectories() async throws {
        let sub = tempDir.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try copyFixture("photo_01.jpg", to: tempDir, as: "root.jpg")
        try copyFixture("photo_02.jpg", to: sub, as: "nested.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolderDeep(id: id)

        let photos = try fetchPhotos()
        XCTAssertEqual(photos.count, 2)
        XCTAssertTrue(photos.contains { $0.filePath == sub.appendingPathComponent("nested.jpg").path },
                      "Nested image should be discovered recursively")
    }

    func testScanFolderDeep_marksVideoAsVideo() async throws {
        try copyFixture("video_01.mp4", to: tempDir, as: "clip.mp4")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolderDeep(id: id)

        let photos = try fetchPhotos()
        XCTAssertEqual(photos.count, 1)
        XCTAssertTrue(photos[0].isVideo, "mp4 fixture should be flagged isVideo")
        // Deep scan defers metadata, so duration stays nil at this point.
        XCTAssertNil(photos[0].duration)
    }

    // MARK: - scanFolder (single level)

    func testScanFolder_insertsAndDedups() async throws {
        try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        try copyFixture("photo_02.jpg", to: tempDir, as: "b.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolder(id: id)
        XCTAssertEqual(try fetchPhotos().count, 2)

        // Add a third file and re-scan: only the new one is inserted, no dupes.
        try copyFixture("photo_03.jpg", to: tempDir, as: "c.jpg")
        try await scanner.scanFolder(id: id)

        let photos = try fetchPhotos()
        XCTAssertEqual(photos.count, 3, "Re-scan inserts only the new file")
        XCTAssertEqual(Set(photos.map(\.fileName)), ["a.jpg", "b.jpg", "c.jpg"])
    }

    func testScanFolder_rescanWithoutChangesIsStable() async throws {
        try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        try copyFixture("photo_02.jpg", to: tempDir, as: "b.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolder(id: id)
        try await scanner.scanFolder(id: id)

        XCTAssertEqual(try fetchPhotos().count, 2, "Idempotent re-scan keeps row count")
    }

    func testScanFolder_deltaRemovesDeletedFiles() async throws {
        let a = try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        try copyFixture("photo_02.jpg", to: tempDir, as: "b.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolder(id: id)
        XCTAssertEqual(try fetchPhotos().count, 2)

        // Remove one file from disk, then re-scan: the stale DB row is deleted.
        try FileManager.default.removeItem(at: a)
        try await scanner.scanFolder(id: id)

        let photos = try fetchPhotos()
        XCTAssertEqual(photos.count, 1, "Deleted-on-disk file should be removed from DB")
        XCTAssertEqual(photos.first?.fileName, "b.jpg")
    }

    func testScanFolder_ignoresNonMediaFiles() async throws {
        try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        let txt = tempDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: txt)
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolder(id: id)

        let photos = try fetchPhotos()
        XCTAssertEqual(photos.count, 1, "Only media files are inserted")
        XCTAssertEqual(photos.first?.fileName, "a.jpg")
    }

    func testScanFolder_subPathScansOnlySubdirectory() async throws {
        let sub = tempDir.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try copyFixture("photo_01.jpg", to: tempDir, as: "root.jpg")
        try copyFixture("photo_02.jpg", to: sub, as: "inner.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolder(id: id, subPath: sub.path)

        let photos = try fetchPhotos()
        // Only the subdirectory level was scanned.
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.fileName, "inner.jpg")
    }

    // MARK: - listSubfolders

    func testListSubfolders_returnsChildDirectoriesFromDB() async throws {
        let trip = tempDir.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: trip, withIntermediateDirectories: true)
        try copyFixture("photo_01.jpg", to: trip, as: "x.jpg")
        try copyFixture("photo_02.jpg", to: tempDir, as: "root.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolderDeep(id: id)

        let subs = await scanner.listSubfolders(id: id)
        XCTAssertEqual(subs.count, 1, "Exactly one subdirectory expected")
        XCTAssertEqual(subs.first?.name, "Trip")
        XCTAssertEqual(subs.first?.path, trip.path)
        XCTAssertNotNil(subs.first?.coverPath, "Subfolder should get a cover from its newest photo")
    }

    func testListSubfolders_emptyWhenNoSubdirs() async throws {
        try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolderDeep(id: id)

        let subs = await scanner.listSubfolders(id: id)
        XCTAssertTrue(subs.isEmpty, "No subdirectories => empty list")
    }

    // MARK: - removePhotos / removeFolderRecord

    func testRemovePhotos_clearsPhotosButKeepsFolder() async throws {
        try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        try copyFixture("photo_02.jpg", to: tempDir, as: "b.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        try await scanner.scanFolderDeep(id: id)
        XCTAssertEqual(try fetchPhotos().count, 2)

        await scanner.removePhotos(forFolder: id)

        XCTAssertEqual(try fetchPhotos().count, 0, "All photos removed")
        XCTAssertEqual(try fetchFolders().count, 1, "Folder record itself is preserved")
    }

    func testRemoveFolderRecord_deletesFolder() async throws {
        try copyFixture("photo_01.jpg", to: tempDir, as: "a.jpg")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        await scanner.removeFolderRecord(id: id)

        XCTAssertEqual(try fetchFolders().count, 0, "Folder record should be deleted")
    }

    // MARK: - clearNeedsThumbnails

    func testClearNeedsThumbnails_resetsFlag() async throws {
        let id = try makeFolder(at: tempDir)
        // Set the flag on the saved folder via a fresh context.
        let ctx = ModelContext(container)
        if let folder = try ctx.fetch(FetchDescriptor<ScannedFolder>()).first {
            folder.needsThumbnails = true
            try ctx.save()
        }

        let scanner = FolderScanner(modelContainer: container)
        await scanner.clearNeedsThumbnails()

        let folder = try fetchFolders().first
        XCTAssertNotNil(folder)
        XCTAssertFalse(folder?.needsThumbnails ?? true, "needsThumbnails should be cleared")
        _ = id
    }

    // MARK: - Unused / no-op API surface

    func testAllUncachedPhotos_returnsEmpty() async throws {
        let scanner = FolderScanner(modelContainer: container)
        let result = await scanner.allUncachedPhotos()
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - fillMissingDurations

    func testFillMissingDurations_backfillsVideoDuration() async throws {
        try copyFixture("video_01.mp4", to: tempDir, as: "clip.mp4")
        let id = try makeFolder(at: tempDir)

        let scanner = FolderScanner(modelContainer: container)
        // Deep scan inserts the video with nil duration.
        try await scanner.scanFolderDeep(id: id)
        XCTAssertEqual(try fetchPhotos().filter(\.isVideo).count, 1)
        XCTAssertNil(try fetchPhotos().first?.duration)

        await scanner.fillMissingDurations(id: id)

        let video = try fetchPhotos().first { $0.isVideo }
        XCTAssertNotNil(video?.duration, "Duration should be back-filled from the asset")
        if let d = video?.duration { XCTAssertGreaterThan(d, 0) }
    }
}
