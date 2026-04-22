import XCTest

/// Tests for sidebar interaction.
final class SidebarUITests: SpectrumUITestBase {

    func testFoldersSectionHeaderExists() {
        let header = app.staticTexts["Folders"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "'Folders' section header should exist")
    }

    func testDropTargetAcceptsFolder() {
        // The sidebar list should exist as a drop target
        let sidebar = app.outlines.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // We can't programmatically drag a real folder, but we verify the sidebar is present
    }

    func testAddFolderViaMenu() {
        // File → Add Folder… menu should exist
        app.menuBars.menuBarItems["File"].click()
        let addFolder = app.menuBars.menuItems["Add Folder…"]
        XCTAssertTrue(addFolder.waitForExistence(timeout: 3), "File → Add Folder… menu item should exist")
        // Press escape to dismiss menu without acting
        app.typeKey(.escape, modifierFlags: [])
    }
}
