import XCTest

/// Tests for the Settings window.
final class SettingsUITests: SpectrumUITestBase {

    func testSettingsWindowOpens() {
        openSettings()
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings window should open")
    }

    func testGeneralTabExists() {
        openSettings()
        let generalTab = app.radioButtons["General"]
        XCTAssertTrue(generalTab.waitForExistence(timeout: 5), "General tab should exist")
    }

    func testCacheTabExists() {
        openSettings()
        let cacheTab = app.radioButtons["Cache"]
        XCTAssertTrue(cacheTab.waitForExistence(timeout: 5), "Cache tab should exist")
    }

    func testGyroTabExists() {
        openSettings()
        let gyroTab = app.radioButtons["Gyro"]
        XCTAssertTrue(gyroTab.waitForExistence(timeout: 5), "Gyro tab should exist")
    }

    func testSwitchToCacheTab() {
        openSettings()
        let cacheTab = app.radioButtons["Cache"]
        waitForElement(cacheTab)
        cacheTab.click()

        // "Reset All Data" button should be visible in Cache tab
        let resetBtn = app.buttons["Reset All Data…"]
        XCTAssertTrue(resetBtn.waitForExistence(timeout: 3), "Reset All Data button should exist in Cache tab")
    }

    func testSwitchToGyroTab() {
        openSettings()
        let gyroTab = app.radioButtons["Gyro"]
        waitForElement(gyroTab)
        gyroTab.click()

        // Gyro tab should show "Enable Gyro Stabilization" toggle
        let gyroToggle = app.checkBoxes.firstMatch
        XCTAssertTrue(gyroToggle.waitForExistence(timeout: 3), "Gyro tab should have toggles")
    }

    func testGeneralTabThemePicker() {
        openSettings()

        // Theme radio buttons should exist
        let systemRadio = app.radioButtons["System"]
        let lightRadio = app.radioButtons["Light"]
        let darkRadio = app.radioButtons["Dark"]

        XCTAssertTrue(systemRadio.waitForExistence(timeout: 5), "System theme option should exist")
        XCTAssertTrue(lightRadio.exists, "Light theme option should exist")
        XCTAssertTrue(darkRadio.exists, "Dark theme option should exist")
    }

    func testGeneralTabDiagBadgeToggle() {
        openSettings()
        let toggle = app.checkBoxes["Show diagnostics badge"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Diagnostics badge toggle should exist")
    }

    func testResetAllDataConfirmation() {
        openSettings()
        let cacheTab = app.radioButtons["Cache"]
        waitForElement(cacheTab)
        cacheTab.click()

        let resetBtn = app.buttons["Reset All Data…"]
        waitForElement(resetBtn)
        resetBtn.click()

        // Confirmation dialog should appear
        let confirmBtn = app.buttons["Reset All Data"]
        XCTAssertTrue(confirmBtn.waitForExistence(timeout: 3), "Reset confirmation dialog should appear")

        // Cancel instead of actually resetting
        let cancelBtn = app.buttons["Cancel"]
        if cancelBtn.exists { cancelBtn.click() }
    }
}
