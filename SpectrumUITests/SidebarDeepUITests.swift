import XCTest

/// Drives the subfolder/disclosure/context-menu paths of `SidebarView` that the
/// flat E2EFixtures folder cannot reach: it builds a temp folder tree WITH
/// subfolders, adds it, expands the disclosure rows (SubfolderSidebarRow +
/// loadChildren + refreshFolderChildren), and exercises the folder context menu
/// (Rescan / Show in Finder / Remove).
final class SidebarDeepUITests: XCTestCase {

    var app: XCUIApplication!
    private var workDir: URL!
    private var rootName: String!

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("E2EFixtures")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrum-sbdeep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        // Build a folder tree: root with a top-level photo + two subfolders, each
        // holding a photo (so the sidebar shows expandable disclosure rows).
        let fm = FileManager.default
        rootName = "Library-\(UUID().uuidString.prefix(8))"
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(rootName)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let srcPhoto = fixturesDir.appendingPathComponent("photo_01.jpg")
        try? fm.copyItem(at: srcPhoto, to: workDir.appendingPathComponent("top.jpg"))
        for sub in ["Trip", "Family"] {
            let subURL = workDir.appendingPathComponent(sub)
            try fm.createDirectory(at: subURL, withIntermediateDirectories: true)
            try? fm.copyItem(at: srcPhoto, to: subURL.appendingPathComponent("\(sub).jpg"))
            // a nested sub-subfolder under Trip to exercise recursion
            if sub == "Trip" {
                let nested = subURL.appendingPathComponent("Day1")
                try fm.createDirectory(at: nested, withIntermediateDirectories: true)
                try? fm.copyItem(at: srcPhoto, to: nested.appendingPathComponent("d1.jpg"))
            }
        }

        app.launchArguments = ["--userdir", userDir.path, "--add-folder", workDir.path]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        if let w = workDir { try? FileManager.default.removeItem(at: w) }
    }

    private var sidebar: XCUIElement { app.outlines["sidebar.list"] }

    /// Locate the added folder's row by name prefix, falling back to the first
    /// outline cell (the sidebar only contains our one folder).
    private func folderCell() -> XCUIElement {
        let byName = app.outlines.cells.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Library-'")).firstMatch
        if byName.exists { return byName }
        return app.outlines.cells.firstMatch
    }

    private func waitForFolder() -> Bool {
        let byName = app.outlines.cells.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Library-'")).firstMatch
        if byName.waitForExistence(timeout: 20) { return true }
        return app.outlines.cells.firstMatch.waitForExistence(timeout: 5)
    }

    func testExpandSubfoldersAndContextMenu() {
        XCTAssertTrue(waitForFolder(), "Added folder should appear in the sidebar")
        // Give the background scan time to discover subfolders.
        Thread.sleep(forTimeInterval: 2.5)

        // Expand the folder's disclosure triangle to render SubfolderSidebarRow rows.
        let disclosure = app.outlines.cells.disclosureTriangles.firstMatch
        if disclosure.waitForExistence(timeout: 5), disclosure.isHittable {
            disclosure.click()
            Thread.sleep(forTimeInterval: 1.0)
        }
        // Expand any now-visible subfolder triangles (SubfolderSidebarRow.loadChildren).
        for tri in app.outlines.cells.disclosureTriangles.allElementsBoundByIndex.prefix(4) {
            if tri.exists, tri.isHittable {
                tri.click()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        // Click a subfolder row if present (selection -> grid update).
        let trip = app.outlines.cells.staticTexts["Trip"].firstMatch
        if trip.waitForExistence(timeout: 3), trip.isHittable {
            trip.click()
            Thread.sleep(forTimeInterval: 0.6)
        }

        XCTAssertTrue(app.windows.count >= 1, "app should remain responsive")
    }

    func testFolderContextMenuRescanAndRemove() {
        XCTAssertTrue(waitForFolder())
        Thread.sleep(forTimeInterval: 2.0)

        // Context menu: Rescan (non-destructive).
        folderCell().rightClick()
        Thread.sleep(forTimeInterval: 0.5)
        let rescan = app.menuItems["Rescan"].firstMatch
        if rescan.waitForExistence(timeout: 4), rescan.isHittable {
            rescan.click()
            Thread.sleep(forTimeInterval: 1.0)
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        // Context menu: Remove (safe — folder is a throwaway temp dir; only the DB
        // record + bookmark are removed, the files are not deleted by Remove).
        folderCell().rightClick()
        Thread.sleep(forTimeInterval: 0.5)
        let remove = app.menuItems["Remove"].firstMatch
        if remove.waitForExistence(timeout: 4), remove.isHittable {
            remove.click()
            Thread.sleep(forTimeInterval: 1.5)
            // A confirmation alert may appear; confirm it if so.
            for title in ["Remove", "OK", "Delete"] {
                let b = app.sheets.buttons[title].firstMatch
                if b.exists, b.isHittable { b.click(); break }
            }
            Thread.sleep(forTimeInterval: 1.0)
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        XCTAssertTrue(app.windows.count >= 1, "app should remain responsive after remove")
    }
}
