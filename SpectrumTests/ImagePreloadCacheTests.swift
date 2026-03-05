import XCTest
@testable import Spectrum

@MainActor
final class ImagePreloadCacheTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: ImageHDRDetectionTests.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            XCTFail("Missing fixture: \(name)")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    // MARK: - cachedEntry

    func testCachedEntry_returnsNilForUnknownPath() {
        let result = ImagePreloadCache.cachedEntry(for: "/no/such/file.jpg")
        XCTAssertNil(result)
    }

    // MARK: - loadImageEntry caching

    func testLoadImageEntry_returnsCachedOnSecondCall() async {
        let url = fixtureURL("sdr_photo.jpg")
        let entry1 = await ImagePreloadCache.loadImageEntry(path: url.path, bookmarkData: nil)
        XCTAssertNotNil(entry1.image)

        // Second call should return from cache (same object)
        let entry2 = await ImagePreloadCache.loadImageEntry(path: url.path, bookmarkData: nil)
        XCTAssertNotNil(entry2.image)
        XCTAssert(entry1.image === entry2.image, "Second call should return the same cached NSImage instance")
    }

    func testLoadImageEntry_nonExistentFile() async {
        let entry = await ImagePreloadCache.loadImageEntry(path: "/tmp/does_not_exist_\(UUID()).jpg", bookmarkData: nil)
        XCTAssertNil(entry.image)
        XCTAssertNil(entry.hdrFormat)
    }

    func testCachedEntry_returnsEntryAfterLoad() async {
        let url = fixtureURL("sdr_photo.jpg")
        _ = await ImagePreloadCache.loadImageEntry(path: url.path, bookmarkData: nil)
        let cached = ImagePreloadCache.cachedEntry(for: url.path)
        XCTAssertNotNil(cached, "cachedEntry should return the entry after loadImageEntry")
    }

    // MARK: - LRU eviction

    func testLRUEviction_removesOldestEntry() async {
        // Load 6 unique non-existent paths to exceed maxCacheSize (5)
        // The first path should be evicted
        var paths: [String] = []
        for i in 0..<6 {
            let path = "/tmp/lru_test_\(UUID())_\(i).jpg"
            paths.append(path)
            _ = await ImagePreloadCache.loadImageEntry(path: path, bookmarkData: nil)
        }

        // First path should have been evicted
        XCTAssertNil(ImagePreloadCache.cachedEntry(for: paths[0]),
                     "Oldest entry should be evicted when cache exceeds maxCacheSize")

        // Last 5 should still be cached
        for i in 1..<6 {
            XCTAssertNotNil(ImagePreloadCache.cachedEntry(for: paths[i]),
                            "Entry \(i) should still be in cache")
        }
    }

    func testLRUOrder_reaccesMovesToEnd() async {
        // Fill cache with 5 entries
        var paths: [String] = []
        for i in 0..<5 {
            let path = "/tmp/lru_order_\(UUID())_\(i).jpg"
            paths.append(path)
            _ = await ImagePreloadCache.loadImageEntry(path: path, bookmarkData: nil)
        }

        // Re-access the first entry to move it to end of LRU
        _ = await ImagePreloadCache.loadImageEntry(path: paths[0], bookmarkData: nil)

        // Now add a 6th entry — paths[1] (the oldest untouched) should be evicted, not paths[0]
        let newPath = "/tmp/lru_order_\(UUID())_new.jpg"
        _ = await ImagePreloadCache.loadImageEntry(path: newPath, bookmarkData: nil)

        XCTAssertNotNil(ImagePreloadCache.cachedEntry(for: paths[0]),
                        "Re-accessed entry should NOT be evicted")
        XCTAssertNil(ImagePreloadCache.cachedEntry(for: paths[1]),
                     "Oldest untouched entry should be evicted")
    }

    // MARK: - prefetch

    func testPrefetch_skipsIfAlreadyCached() async {
        let url = fixtureURL("sdr_photo.jpg")
        // Pre-load to populate cache
        let entry1 = await ImagePreloadCache.loadImageEntry(path: url.path, bookmarkData: nil)

        // Prefetch should be a no-op (already cached)
        ImagePreloadCache.prefetch(path: url.path, bookmarkData: nil)

        // Verify cache still has the same entry
        let cached = ImagePreloadCache.cachedEntry(for: url.path)
        XCTAssert(cached?.image === entry1.image)
    }

    // MARK: - SDR detection

    func testLoadImageEntry_sdrPhoto_noHDRFormat() async {
        let url = fixtureURL("sdr_photo.jpg")
        let entry = await ImagePreloadCache.loadImageEntry(path: url.path, bookmarkData: nil)
        XCTAssertNotNil(entry.image)
        XCTAssertNil(entry.hdrFormat, "SDR photo should have nil hdrFormat")
        XCTAssertNil(entry.hlgCGImage, "SDR photo should have nil hlgCGImage")
    }
}
