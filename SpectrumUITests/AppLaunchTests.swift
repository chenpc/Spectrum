import XCTest

/// Tests that the app launches correctly and shows the expected initial UI.
final class AppLaunchTests: SpectrumUITestBase {

    func testAppLaunches() {
        // The window should exist
        XCTAssertTrue(app.windows.count >= 1, "App should have at least one window")
    }

    func testSidebarVisible() {
        // Sidebar list should be present
        let sidebar = app.outlines.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Sidebar should be visible")
    }

    func testEmptyStateShown() {
        // With no folders added, "Select a Folder" should appear
        let empty = app.staticTexts["Select a Folder"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "Empty state should show 'Select a Folder'")
    }

    func testSidebarNoFoldersMessage() {
        // Sidebar should show "No Folders" when empty
        let noFolders = app.staticTexts["No Folders"]
        XCTAssertTrue(noFolders.waitForExistence(timeout: 5), "Sidebar should show 'No Folders' when empty")
    }

    func testImportButtonExists() {
        let importBtn = app.buttons["Import"]
        XCTAssertTrue(importBtn.waitForExistence(timeout: 5), "Import button should exist in toolbar")
    }

    func testSearchFieldExists() {
        // The searchable toolbar field
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Search field should exist")
    }
}
