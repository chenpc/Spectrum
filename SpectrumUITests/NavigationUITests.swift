import XCTest

/// Tests for navigation flows and keyboard shortcuts.
final class NavigationUITests: SpectrumUITestBase {

    func testImportPanelToggle() {
        // Click import button — panel should appear
        let importBtn = app.buttons["Import"]
        waitForElement(importBtn)
        importBtn.click()

        // Import panel should appear (look for "Select Folder" or related UI)
        // Since no folder is selected, the panel may show a button to select one
        sleep(1)  // Allow animation

        // Click again to dismiss
        importBtn.click()
        sleep(1)
    }

    func testSearchFieldTyping() {
        let search = app.searchFields.firstMatch
        waitForElement(search)
        search.click()
        search.typeText("test")

        // Search text should be entered
        let value = search.value as? String
        XCTAssertTrue(value?.contains("test") == true, "Search field should contain typed text")

        // Clear search
        search.typeKey(.escape, modifierFlags: [])
    }

    func testMenuBarFileMenu() {
        app.menuBars.menuBarItems["File"].click()
        let menuItems = app.menuBars.menus.firstMatch
        XCTAssertTrue(menuItems.waitForExistence(timeout: 3), "File menu should open")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMenuBarEditMenu() {
        app.menuBars.menuBarItems["Edit"].click()
        let menuItems = app.menuBars.menus.firstMatch
        XCTAssertTrue(menuItems.waitForExistence(timeout: 3), "Edit menu should open")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMenuBarViewMenu() {
        app.menuBars.menuBarItems["View"].click()
        let menuItems = app.menuBars.menus.firstMatch
        XCTAssertTrue(menuItems.waitForExistence(timeout: 3), "View menu should open")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testEscapeInEmptyState() {
        // Pressing escape in empty state should not crash
        app.typeKey(.escape, modifierFlags: [])
        // App should still be running
        XCTAssertTrue(app.windows.count >= 1)
    }

    func testKeyboardShortcutCmdComma() {
        // Cmd+, should open Settings
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Cmd+, should open Settings")
    }
}
