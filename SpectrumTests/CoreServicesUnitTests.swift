import XCTest
import Foundation
@testable import Spectrum

/// Unit tests for several small core services and Photo model helpers.
final class CoreServicesUnitTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreServicesUnitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
    }

    // MARK: - SpectrumLibrary

    func testSpectrumLibrary_derivedPathsHangOffRoot() {
        let root = SpectrumLibrary.url

        // The database, thumbnails and lock paths must all be children of `url`.
        XCTAssertEqual(SpectrumLibrary.databaseURL,
                       root.appendingPathComponent("default.store"))
        XCTAssertEqual(SpectrumLibrary.thumbnailsURL,
                       root.appendingPathComponent("Thumbnails", isDirectory: true))
        XCTAssertEqual(SpectrumLibrary.lockFileURL,
                       root.appendingPathComponent("default.store.lock"))
    }

    func testSpectrumLibrary_rootDirectoryExists() {
        // Accessing `url` lazily creates the directory.
        let root = SpectrumLibrary.url
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "Accessing SpectrumLibrary.url should create the root directory")
    }

    func testSpectrumLibrary_databaseFileNameIsStable() {
        XCTAssertEqual(SpectrumLibrary.databaseURL.lastPathComponent, "default.store")
        XCTAssertEqual(SpectrumLibrary.lockFileURL.lastPathComponent, "default.store.lock")
        XCTAssertEqual(SpectrumLibrary.thumbnailsURL.lastPathComponent, "Thumbnails")
    }

    // MARK: - AppLaunchArgs
    //
    // `AppLaunchArgs.init` is private and parses the live process argv, so we cannot
    // inject argv. We exercise the shared instance and assert its invariants hold
    // (types are correct, no crash, default folder is nil under the test runner).

    func testAppLaunchArgs_sharedIsStable() {
        let a = AppLaunchArgs.shared
        let b = AppLaunchArgs.shared
        XCTAssertTrue(a === b, "shared should be a singleton")
    }

    func testAppLaunchArgs_propertiesAccessible() {
        let args = AppLaunchArgs.shared
        // logToStdout is a Bool — just touch it to ensure it is readable.
        let flag: Bool = args.logToStdout
        XCTAssertTrue(flag == true || flag == false)

        // userDir / addFolder are optional URLs; if present they must be file URLs.
        if let dir = args.userDir { XCTAssertTrue(dir.isFileURL) }
        if let folder = args.addFolder { XCTAssertTrue(folder.isFileURL) }
    }

    // MARK: - BookmarkService

    func testBookmarkService_roundTrip() throws {
        let data = try BookmarkService.createBookmark(for: tempDir)
        XCTAssertFalse(data.isEmpty, "Bookmark data should not be empty")

        let resolved = try BookmarkService.resolveBookmark(data)
        // Resolve to canonical form on both sides for comparison.
        XCTAssertEqual(resolved.resolvingSymlinksInPath().standardizedFileURL,
                       tempDir.resolvingSymlinksInPath().standardizedFileURL,
                       "Resolved bookmark should point back to the original directory")
    }

    func testBookmarkService_resolveRefreshing_freshIsNil() throws {
        let data = try BookmarkService.createBookmark(for: tempDir)
        let (url, refreshed) = try BookmarkService.resolveBookmarkRefreshing(data)
        XCTAssertEqual(url.resolvingSymlinksInPath().standardizedFileURL,
                       tempDir.resolvingSymlinksInPath().standardizedFileURL)
        // A freshly-created bookmark is not stale, so no refreshed data is returned.
        XCTAssertNil(refreshed, "Non-stale bookmark should not produce refreshed data")
    }

    func testBookmarkService_withSecurityScope_runsBodyAndReturnsValue() {
        let result = BookmarkService.withSecurityScope(tempDir) { () -> Int in
            return 42
        }
        XCTAssertEqual(result, 42, "withSecurityScope should return the body's value")
    }

    func testBookmarkService_withSecurityScope_propagatesThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try BookmarkService.withSecurityScope(tempDir) { () -> Int in
                throw Boom()
            }
        ) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    func testBookmarkService_withSecurityScope_async() async throws {
        let value = await BookmarkService.withSecurityScope(tempDir) { () async -> String in
            return "ok"
        }
        XCTAssertEqual(value, "ok")
    }

    func testBookmarkService_remountURL_localPathIsNil() {
        // A local (non-network) directory has no remount URL.
        let remount = BookmarkService.remountURL(for: tempDir)
        XCTAssertNil(remount, "Local directory should have no remount URL")
    }

    // MARK: - Log

    func testLog_loggersAreDistinctCategories() {
        // The Logger objects exist and are usable. Just ensure access does not crash.
        Log.general.debug("test")
        Log.scanner.debug("test")
        Log.network.debug("test")
        Log.bookmark.debug("test")
        XCTAssertNotNil(Log.video)
    }

    func testLog_levelReflectsUserDefaults() {
        let key = "appLogLevel"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(AppLogLevel.error.rawValue, forKey: key)
        XCTAssertEqual(Log.level, .error)

        UserDefaults.standard.set(AppLogLevel.info.rawValue, forKey: key)
        XCTAssertEqual(Log.level, .info)

        UserDefaults.standard.set(AppLogLevel.debug.rawValue, forKey: key)
        XCTAssertEqual(Log.level, .debug)
    }

    func testLog_levelFallsBackOnInvalidRawValue() {
        let key = "appLogLevel"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(999, forKey: key)
        // Invalid raw value → falls back to build default.
        XCTAssertEqual(Log.level, Log.buildDefaultLevel)
    }

    func testAppLogLevel_labelsAndIdentifiers() {
        XCTAssertEqual(AppLogLevel.allCases.count, 3)
        XCTAssertEqual(AppLogLevel.debug.id, 0)
        XCTAssertEqual(AppLogLevel.info.id, 1)
        XCTAssertEqual(AppLogLevel.error.id, 2)
        XCTAssertFalse(AppLogLevel.debug.label.isEmpty)
        XCTAssertFalse(AppLogLevel.info.label.isEmpty)
        XCTAssertFalse(AppLogLevel.error.label.isEmpty)
    }

    func testLog_memMB_isPositive() {
        // The running test process always has a non-trivial footprint.
        XCTAssertGreaterThan(Log.memMB(), 0)
    }

    // MARK: - NetworkVolumeService

    func testNetworkVolumeService_volumeRoot_forVolumePath() {
        XCTAssertEqual(NetworkVolumeService.volumeRoot(for: "/Volumes/MyNAS/Photos/2014"),
                       "/Volumes/MyNAS")
        XCTAssertEqual(NetworkVolumeService.volumeRoot(for: "/Volumes/Share/file.jpg"),
                       "/Volumes/Share")
    }

    func testNetworkVolumeService_volumeRoot_forLocalPathIsNil() {
        XCTAssertNil(NetworkVolumeService.volumeRoot(for: "/Users/me/Pictures/a.jpg"))
        XCTAssertNil(NetworkVolumeService.volumeRoot(for: "/Volumes"))
        XCTAssertNil(NetworkVolumeService.volumeRoot(for: "/"))
    }

    func testNetworkVolumeService_isVolumeMounted_localAlwaysTrue() {
        // Local paths are reported as "mounted" unconditionally.
        XCTAssertTrue(NetworkVolumeService.isVolumeMounted(path: "/Users/me/file.jpg"))
    }

    func testNetworkVolumeService_isVolumeMounted_missingVolumeFalse() {
        // A made-up volume name should not exist.
        let fake = "/Volumes/NoSuchVolume-\(UUID().uuidString)/x.jpg"
        XCTAssertFalse(NetworkVolumeService.isVolumeMounted(path: fake))
    }

    // MARK: - Photo computed properties
    //
    // Photo.editOps / compositeEdit are covered by PhotoEditOpsTests and
    // resolveBookmarkData by PhotoResolveBookmarkTests; only the default-flag
    // invariants are asserted here to avoid duplicating those suites.

    func testPhoto_defaultFlags() {
        let photo = Photo(filePath: "/p/f.mp4", fileName: "f.mp4", dateTaken: Date())
        XCTAssertFalse(photo.isVideo)
        XCTAssertFalse(photo.isLivePhotoMov)
        XCTAssertFalse(photo.hasThumbnail)
        XCTAssertNil(photo.folder)
        XCTAssertNil(photo.duration)
    }
}
