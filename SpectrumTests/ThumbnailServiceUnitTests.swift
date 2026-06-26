import XCTest
import SwiftData
import AppKit
@testable import Spectrum

/// Covers ThumbnailService (actor cache + generation), ThumbnailScheduler /
/// ThumbnailProgress (scheduling + progress state), and ThumbnailCacheState
/// (generation invalidation).
final class ThumbnailServiceUnitTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbSvcTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - Fixtures

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SpectrumUITests/E2EFixtures")
    }

    /// Copy a fixture image into the temp dir and return the destination path.
    private func copiedFixture(_ name: String) throws -> String {
        let src = fixturesDir.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "Fixture not available: \(name)")
        let dst = tempDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
        return dst.path
    }

    // MARK: - ThumbnailService: generation + caching

    func testThumbnail_generatesNonNilImage() async throws {
        let path = try copiedFixture("photo_01.jpg")
        let service = ThumbnailService()

        let image = await service.thumbnail(for: path, bookmarkData: nil)
        XCTAssertNotNil(image, "Should generate a thumbnail for a real JPEG fixture")

        if let image {
            // Generated thumbnail should be bounded by the configured thumbnail size.
            let maxDim = max(image.size.width, image.size.height)
            XCTAssertGreaterThan(maxDim, 0, "Thumbnail should have a non-zero size")
            XCTAssertLessThanOrEqual(maxDim, CGFloat(service.thumbnailSize) + 1,
                                     "Thumbnail longest edge should not exceed thumbnailSize")
        }
    }

    func testThumbnail_cachedRetrievalAfterGeneration() async throws {
        let path = try copiedFixture("photo_02.jpg")
        let service = ThumbnailService()

        // Not cached before generation.
        XCTAssertNil(service.cachedThumbnail(for: path),
                     "cachedThumbnail should be nil before generation")

        let generated = await service.thumbnail(for: path, bookmarkData: nil)
        XCTAssertNotNil(generated)

        // Now present in the memory cache.
        let cached = service.cachedThumbnail(for: path)
        XCTAssertNotNil(cached, "cachedThumbnail should return the freshly generated image")
        XCTAssert(cached === generated, "Cached object should be the same NSImage instance")
    }

    func testThumbnail_secondCallReturnsCachedInstance() async throws {
        let path = try copiedFixture("photo_03.jpg")
        let service = ThumbnailService()

        let first = await service.thumbnail(for: path, bookmarkData: nil)
        let second = await service.thumbnail(for: path, bookmarkData: nil)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssert(first === second, "Second thumbnail() call should hit the cache and return same instance")
    }

    func testThumbnail_nonexistentFileReturnsNil() async {
        let service = ThumbnailService()
        let missing = tempDir.appendingPathComponent("does_not_exist_\(UUID()).jpg").path

        let image = await service.thumbnail(for: missing, bookmarkData: nil)
        XCTAssertNil(image, "Missing source file should yield nil thumbnail")
        XCTAssertNil(service.cachedThumbnail(for: missing), "Nil result should not be cached")
    }

    func testClearCache_removesCachedThumbnail() async throws {
        let path = try copiedFixture("photo_04.jpg")
        let service = ThumbnailService()

        _ = await service.thumbnail(for: path, bookmarkData: nil)
        XCTAssertNotNil(service.cachedThumbnail(for: path))

        await service.clearCache()
        XCTAssertNil(service.cachedThumbnail(for: path),
                     "clearCache should evict all cached thumbnails")
    }

    func testCachedThumbnail_unknownPathIsNil() {
        let service = ThumbnailService()
        XCTAssertNil(service.cachedThumbnail(for: "/no/such/path/\(UUID()).jpg"))
    }

    func testUpdateMemoryCacheLimit_doesNotCrash() async throws {
        let path = try copiedFixture("photo_05.jpg")
        let service = ThumbnailService()

        // Generate, then shrink the limit and grow it again — must not crash
        // and an existing entry should remain retrievable after enlarging.
        _ = await service.thumbnail(for: path, bookmarkData: nil)
        service.updateMemoryCacheLimit(gb: 2.0)
        let stillCached = service.cachedThumbnail(for: path)
        XCTAssertNotNil(stillCached, "Entry should survive when raising the cache limit")

        service.updateMemoryCacheLimit(gb: 0.5)  // just verify no crash on shrink
    }

    func testThumbnail_invalidBookmarkDataStillGenerates() async throws {
        // A bookmark resolve failure should be logged but not prevent generation
        // when the file path itself is accessible.
        let path = try copiedFixture("photo_01.jpg")
        let service = ThumbnailService()

        let image = await service.thumbnail(for: path, bookmarkData: Data("not-a-real-bookmark".utf8))
        XCTAssertNotNil(image, "Generation should proceed even if bookmark resolution fails")
    }

    // MARK: - ThumbnailCacheState

    @MainActor
    func testThumbnailCacheState_invalidateIncrementsGeneration() {
        let state = ThumbnailCacheState.shared
        let before = state.generation
        state.invalidate()
        XCTAssertEqual(state.generation, before + 1, "invalidate should bump generation by 1")
        state.invalidate()
        XCTAssertEqual(state.generation, before + 2, "Each invalidate should increment generation")
    }

    // MARK: - ThumbnailProgress state transitions

    @MainActor
    func testThumbnailProgress_scanLifecycle() {
        let p = ThumbnailProgress.shared
        p.cancelAll()  // start from a clean slate

        XCTAssertFalse(p.isActive, "Should be inactive after cancelAll")

        p.markScanStarted()
        XCTAssertTrue(p.isScanning)
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.thumbDone, 0)
        XCTAssertEqual(p.thumbTotal, 0)
        XCTAssertEqual(p.scanFileCount, 0)

        p.addScanCount(3)
        p.addTotal(10)
        XCTAssertEqual(p.scanFileCount, 3)
        XCTAssertEqual(p.thumbTotal, 10)

        p.markScanFinished()
        XCTAssertFalse(p.isScanning)
        XCTAssertTrue(p.scanDone, "scanDone bridges scan finish to generation start")
        XCTAssertTrue(p.isActive)

        p.finish()
        XCTAssertFalse(p.isGenerating)
        XCTAssertFalse(p.scanDone)
        XCTAssertEqual(p.thumbRate, 0)

        p.cancelAll()
    }

    @MainActor
    func testThumbnailProgress_markScanStartedResetsCounts() {
        let p = ThumbnailProgress.shared
        p.markScanStarted()
        p.addTotal(42)
        p.addScanCount(7)
        XCTAssertEqual(p.thumbTotal, 42)
        XCTAssertEqual(p.scanFileCount, 7)

        // A new scan must reset accumulated counters.
        p.markScanStarted()
        XCTAssertEqual(p.thumbTotal, 0)
        XCTAssertEqual(p.scanFileCount, 0)
        XCTAssertEqual(p.thumbDone, 0)
        XCTAssertEqual(p.thumbRate, 0)
        p.cancelAll()
    }

    @MainActor
    func testThumbnailProgress_removalCounting() {
        let p = ThumbnailProgress.shared
        p.cancelAll()
        XCTAssertFalse(p.isRemoving)

        p.markRemovalStarted(name: "Vacation")
        XCTAssertTrue(p.isRemoving)
        XCTAssertEqual(p.removingCount, 1)
        XCTAssertEqual(p.removingName, "Vacation")
        XCTAssertTrue(p.isActive)

        p.markRemovalStarted(name: "Travel")
        XCTAssertEqual(p.removingCount, 2)

        p.markRemovalFinished()
        XCTAssertEqual(p.removingCount, 1)
        XCTAssertTrue(p.isRemoving, "Still removing while count > 0")
        XCTAssertEqual(p.removingName, "Travel", "Name retained until count hits zero")

        p.markRemovalFinished()
        XCTAssertEqual(p.removingCount, 0)
        XCTAssertFalse(p.isRemoving)
        XCTAssertEqual(p.removingName, "", "Name cleared when count reaches zero")
    }

    @MainActor
    func testThumbnailProgress_removalFinishedClampsAtZero() {
        let p = ThumbnailProgress.shared
        p.cancelAll()
        // Finishing with no pending removals must not go negative.
        p.markRemovalFinished()
        XCTAssertEqual(p.removingCount, 0)
        XCTAssertFalse(p.isRemoving)
    }

    @MainActor
    func testThumbnailProgress_cancelAllResetsEverything() {
        let p = ThumbnailProgress.shared
        p.markScanStarted()
        p.addTotal(5)
        p.addScanCount(2)
        p.markRemovalStarted(name: "X")

        p.cancelAll()
        XCTAssertFalse(p.isScanning)
        XCTAssertFalse(p.isScheduled)
        XCTAssertFalse(p.isGenerating)
        XCTAssertFalse(p.scanDone)
        XCTAssertFalse(p.isRemoving)
        XCTAssertEqual(p.removingCount, 0)
        XCTAssertEqual(p.removingName, "")
        XCTAssertEqual(p.thumbDone, 0)
        XCTAssertEqual(p.thumbTotal, 0)
        XCTAssertEqual(p.scanFileCount, 0)
        XCTAssertEqual(p.thumbRate, 0)
        XCTAssertFalse(p.isActive)
    }

    // MARK: - ThumbnailScheduler

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Photo.self, ScannedFolder.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func testScheduler_scheduleThenCancel() async throws {
        let container = try makeContainer()
        let scheduler = ThumbnailScheduler.shared

        // schedule() launches a detached task; run() simply finishes. This must
        // not crash and the singleton should settle. Calling twice exercises the
        // pendingRun path (second call while a task may still be in flight).
        scheduler.schedule(container: container, priority: .background)
        scheduler.schedule(container: container, priority: .userInitiated)

        // Give the detached run() task a moment to complete.
        try await Task.sleep(nanoseconds: 200_000_000)

        scheduler.cancel()

        // After cancel, scheduling again should still work (currentTask cleared).
        scheduler.schedule(container: container, priority: .background)
        try await Task.sleep(nanoseconds: 200_000_000)
        scheduler.cancel()

        // Reach a clean MainActor state for any subsequent tests.
        await MainActor.run { ThumbnailProgress.shared.cancelAll() }
    }

    func testScheduler_cancelWithoutScheduleIsSafe() async {
        let scheduler = ThumbnailScheduler.shared
        // Cancelling with nothing running must be a harmless no-op.
        scheduler.cancel()
        await MainActor.run {
            ThumbnailProgress.shared.cancelAll()
            XCTAssertFalse(ThumbnailProgress.shared.isActive)
        }
    }
}
