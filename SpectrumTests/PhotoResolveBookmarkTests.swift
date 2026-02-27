import XCTest
import SwiftData
@testable import Spectrum

final class PhotoResolveBookmarkTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([Photo.self, ScannedFolder.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    // MARK: - Bookmark Resolution

    func testFromRelationship() throws {
        let bookmark = Data("bookmark-data".utf8)
        let folder = ScannedFolder(path: "/Photos/Vacation", bookmarkData: bookmark)
        context.insert(folder)
        let photo = Photo(filePath: "/Photos/Vacation/IMG_001.jpg", fileName: "IMG_001.jpg", dateTaken: Date(), folder: folder)
        context.insert(photo)
        try context.save()

        let result = photo.resolveBookmarkData(from: [])
        XCTAssertEqual(result, bookmark, "Should resolve bookmark from relationship")
    }

    func testFallbackToPathMatching() throws {
        let bookmark = Data("folder-bookmark".utf8)
        let folder = ScannedFolder(path: "/Photos/Travel", bookmarkData: bookmark)
        context.insert(folder)

        // Photo with nil folder relationship — simulates SwiftData lazy load failure
        let photo = Photo(filePath: "/Photos/Travel/DSC_100.ARW", fileName: "DSC_100.ARW", dateTaken: Date())
        context.insert(photo)
        try context.save()

        let result = photo.resolveBookmarkData(from: [folder])
        XCTAssertEqual(result, bookmark, "Should fall back to path prefix matching")
    }

    func testNoMatch() throws {
        let folder = ScannedFolder(path: "/Photos/Family", bookmarkData: Data("fam".utf8))
        context.insert(folder)

        let photo = Photo(filePath: "/Videos/clip.mp4", fileName: "clip.mp4", dateTaken: Date())
        context.insert(photo)
        try context.save()

        let result = photo.resolveBookmarkData(from: [folder])
        XCTAssertNil(result, "Should return nil when no folder matches")
    }

    func testMultipleFolder_prefixMatch() throws {
        let bk1 = Data("bk1".utf8)
        let bk2 = Data("bk2".utf8)
        let folder1 = ScannedFolder(path: "/Photos", bookmarkData: bk1)
        let folder2 = ScannedFolder(path: "/Photos/Japan", bookmarkData: bk2)
        context.insert(folder1)
        context.insert(folder2)

        let photo = Photo(filePath: "/Photos/Japan/IMG.HIF", fileName: "IMG.HIF", dateTaken: Date())
        context.insert(photo)
        try context.save()

        // first(where:) returns the first match in array order
        let result = photo.resolveBookmarkData(from: [folder1, folder2])
        // Both match by prefix; first in array wins
        XCTAssertEqual(result, bk1, "Should return first matching folder's bookmark")
    }
}
