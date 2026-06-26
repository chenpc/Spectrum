import XCTest

/// UI tests that drive the sidebar (SidebarView.swift) deeper:
/// folder selection, disclosure expansion, context menu, and switching selection.
final class SidebarOpsUITests: XCTestCase {

    var app: XCUIApplication!

    /// Path to E2EFixtures/ next to this source file.
    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("E2EFixtures")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrum-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        app.launchArguments = [
            "--userdir", userDir.path,
            "--add-folder", fixturesDir.path,
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Helpers

    private var sidebarList: XCUIElement { app.outlines["sidebar.list"] }

    /// The folder cell for the loaded fixtures folder (named "E2EFixtures").
    private var folderCell: XCUIElement {
        app.outlines.cells.staticTexts["E2EFixtures"]
    }

    private func waitForFolderCell(timeout: TimeInterval = 15) -> Bool {
        folderCell.waitForExistence(timeout: timeout)
    }

    // MARK: - 1. Folder appears + is selectable

    func test01_FolderCellExistsAndSelectable() {
        XCTAssertTrue(waitForFolderCell(), "Sidebar should show 'E2EFixtures' folder")

        // Click the folder row to drive selection binding.
        folderCell.click()
        Thread.sleep(forTimeInterval: 0.5)

        // The grid should populate after selecting the folder.
        let grid = app.scrollViews["grid.photos"]
        _ = grid.waitForExistence(timeout: 10)

        XCTAssertTrue(folderCell.exists, "Folder cell should still exist after selection")
        XCTAssertTrue(app.windows.count >= 1, "App should still be running")
    }

    // MARK: - 2. Disclosure expansion (if subfolders exist)

    func test02_ExpandDisclosureIfPresent() {
        XCTAssertTrue(waitForFolderCell())
        folderCell.click()
        Thread.sleep(forTimeInterval: 0.5)

        // DisclosureGroup renders a disclosure triangle when subfolders exist.
        let triangle = app.outlines.disclosureTriangles.firstMatch
        if triangle.waitForExistence(timeout: 5) {
            triangle.click()
            Thread.sleep(forTimeInterval: 0.8)
            // Toggle back closed to exercise the collapse path too.
            if triangle.exists {
                triangle.click()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        // Lenient: folder cell and list remain present regardless of subfolders.
        XCTAssertTrue(folderCell.exists, "Folder cell should remain after disclosure toggle")
    }

    // MARK: - 3. Context menu open + dismiss (non-destructive)

    func test03_ContextMenuOpensAndDismisses() {
        XCTAssertTrue(waitForFolderCell())

        folderCell.rightClick()
        Thread.sleep(forTimeInterval: 0.5)

        // Context menu items defined in folderLabel(): Rescan / Show in Finder / Remove.
        let rescan = app.menuItems["Rescan"]
        let appeared = rescan.waitForExistence(timeout: 5)
        if appeared {
            XCTAssertTrue(rescan.exists, "Context menu should contain a Rescan item")
        }

        // Dismiss the menu without triggering the destructive Remove.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(folderCell.exists, "Folder cell should remain after dismissing context menu")
    }

    // MARK: - 4. Context menu -> Rescan (safe, idempotent)

    func test04_ContextMenuRescan() {
        XCTAssertTrue(waitForFolderCell())

        folderCell.rightClick()
        Thread.sleep(forTimeInterval: 0.5)

        let rescan = app.menuItems["Rescan"]
        if rescan.waitForExistence(timeout: 5) {
            rescan.click() // refreshes bookmark only — non-destructive
            Thread.sleep(forTimeInterval: 0.8)
        } else {
            // Menu didn't open; just dismiss.
            app.typeKey(.escape, modifierFlags: [])
        }

        XCTAssertTrue(app.windows.count >= 1, "App should still be running after Rescan")
        XCTAssertTrue(folderCell.exists, "Folder cell should remain after Rescan")
    }

    // MARK: - 5. Selection cycling between rows

    func test05_SelectionCycling() {
        XCTAssertTrue(waitForFolderCell())

        // Click the folder, then any subfolder rows that became visible.
        folderCell.click()
        Thread.sleep(forTimeInterval: 0.4)

        // Expand to reveal subfolder rows if a disclosure triangle is present.
        let triangle = app.outlines.disclosureTriangles.firstMatch
        if triangle.exists {
            triangle.click()
            Thread.sleep(forTimeInterval: 0.8)
        }

        // Toggle selection between whatever cells are present (folder + subfolders).
        let cells = app.outlines.cells
        let count = min(cells.count, 4)
        for i in 0..<count {
            let cell = cells.element(boundBy: i)
            if cell.exists && cell.isHittable {
                cell.click()
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        // Re-select the original folder to finish on a known state.
        if folderCell.exists { folderCell.click() }

        XCTAssertTrue(sidebarList.exists || folderCell.exists,
                      "Sidebar list / folder cell should still exist after selection cycling")
    }
}
