import XCTest
import Foundation
@testable import Spectrum

@MainActor
final class FolderClipboardUnitTests: XCTestCase {

    private var clipboard: FolderClipboard { FolderClipboard.shared }

    override func setUp() {
        super.setUp()
        clipboard.clear()
    }

    override func tearDown() {
        clipboard.clear()
        super.tearDown()
    }

    // MARK: - FolderClipboard: initial / empty state

    func testInitiallyEmpty() {
        clipboard.clear()
        XCTAssertNil(clipboard.content)
        XCTAssertNil(clipboard.files)
        XCTAssertFalse(clipboard.hasContent)
    }

    // MARK: - copy(path:)

    func testCopyFolderSetsContentNotCut() {
        let bm = Data("bm-copy".utf8)
        clipboard.copy(path: "/Photos/Vacation", bookmarkData: bm)

        XCTAssertNotNil(clipboard.content)
        XCTAssertNil(clipboard.files)
        XCTAssertTrue(clipboard.hasContent)
        XCTAssertEqual(clipboard.content?.sourcePath, "/Photos/Vacation")
        XCTAssertEqual(clipboard.content?.bookmarkData, bm)
        XCTAssertEqual(clipboard.content?.isCut, false)
        XCTAssertEqual(clipboard.content?.name, "Vacation")
    }

    // MARK: - cut(path:)

    func testCutFolderSetsContentIsCut() {
        let bm = Data("bm-cut".utf8)
        clipboard.cut(path: "/Photos/Travel/Japan", bookmarkData: bm)

        XCTAssertNotNil(clipboard.content)
        XCTAssertNil(clipboard.files)
        XCTAssertTrue(clipboard.hasContent)
        XCTAssertEqual(clipboard.content?.sourcePath, "/Photos/Travel/Japan")
        XCTAssertEqual(clipboard.content?.isCut, true)
        XCTAssertEqual(clipboard.content?.name, "Japan")
    }

    // MARK: - copyFiles / cutFiles

    func testCopyFilesSetsFilesNotCut() {
        let paths = ["/a/1.jpg", "/a/2.jpg", "/a/3.jpg"]
        let bm = Data("bm-files".utf8)
        clipboard.copyFiles(paths: paths, bookmarkData: bm)

        XCTAssertNil(clipboard.content)
        XCTAssertNotNil(clipboard.files)
        XCTAssertTrue(clipboard.hasContent)
        XCTAssertEqual(clipboard.files?.paths, paths)
        XCTAssertEqual(clipboard.files?.bookmarkData, bm)
        XCTAssertEqual(clipboard.files?.isCut, false)
        XCTAssertEqual(clipboard.files?.count, 3)
    }

    func testCutFilesSetsFilesIsCut() {
        let paths = ["/x/only.arw"]
        clipboard.cutFiles(paths: paths, bookmarkData: Data("z".utf8))

        XCTAssertNil(clipboard.content)
        XCTAssertNotNil(clipboard.files)
        XCTAssertEqual(clipboard.files?.isCut, true)
        XCTAssertEqual(clipboard.files?.count, 1)
    }

    // MARK: - Mutual exclusion between folder content and files

    func testCopyFolderClearsFiles() {
        clipboard.copyFiles(paths: ["/a/1.jpg"], bookmarkData: Data())
        XCTAssertNotNil(clipboard.files)

        clipboard.copy(path: "/a", bookmarkData: Data())
        XCTAssertNotNil(clipboard.content)
        XCTAssertNil(clipboard.files)
    }

    func testCopyFilesClearsFolderContent() {
        clipboard.copy(path: "/a", bookmarkData: Data())
        XCTAssertNotNil(clipboard.content)

        clipboard.cutFiles(paths: ["/a/1.jpg"], bookmarkData: Data())
        XCTAssertNil(clipboard.content)
        XCTAssertNotNil(clipboard.files)
    }

    // MARK: - clear

    func testClearResetsEverything() {
        clipboard.cut(path: "/a", bookmarkData: Data("d".utf8))
        XCTAssertTrue(clipboard.hasContent)

        clipboard.clear()
        XCTAssertNil(clipboard.content)
        XCTAssertNil(clipboard.files)
        XCTAssertFalse(clipboard.hasContent)
    }

    // MARK: - ClipboardFolder.name derived property

    func testClipboardFolderNameTrailingSlash() {
        let f = ClipboardFolder(sourcePath: "/Photos/Album", bookmarkData: Data(), isCut: false)
        XCTAssertEqual(f.name, "Album")
    }

    func testClipboardFilesCount() {
        let f = ClipboardFiles(paths: ["1", "2"], bookmarkData: Data(), isCut: true)
        XCTAssertEqual(f.count, 2)
        XCTAssertTrue(f.isCut)
    }

    // PhotoItem identity / fileURL / compositeEdit / field invariants are covered
    // by ExtraModelTests, so they are intentionally not re-asserted here.
}
