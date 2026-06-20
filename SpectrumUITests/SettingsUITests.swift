import XCTest

/// Tests for the Settings window.
final class SettingsUITests: SpectrumUITestBase {

    func testSettingsWindowOpens() {
        openSettings()
        // Wait up to 8s for a second window to appear (the Settings window)
        let appeared = app.windows.element(boundBy: 1).waitForExistence(timeout: 8)
        XCTAssertTrue(appeared, "A second window (Settings) should appear")
    }

    func testGeneralTabExists() {
        openSettings()
        // On macOS 15+, Settings tab selector buttons are buttons (not radioButtons)
        let generalTab = app.buttons["General"]
        XCTAssertTrue(generalTab.waitForExistence(timeout: 5), "General tab should exist")
    }

    func testCacheTabExists() {
        openSettings()
        let cacheTab = app.buttons["Cache"]
        XCTAssertTrue(cacheTab.waitForExistence(timeout: 5), "Cache tab should exist")
    }

    func testGyroTabExists() {
        openSettings()
        let gyroTab = app.buttons["Gyro"]
        XCTAssertTrue(gyroTab.waitForExistence(timeout: 5), "Gyro tab should exist")
    }

    func testSwitchToCacheTab() {
        openSettings()
        let cacheTab = app.buttons["Cache"]
        XCTAssertTrue(cacheTab.waitForExistence(timeout: 5), "Cache tab button should exist")
        cacheTab.click()

        // "Reset All Data" button should be visible in Cache tab
        let resetBtn = app.buttons["Reset All Data\u{2026}"]
        XCTAssertTrue(resetBtn.waitForExistence(timeout: 3), "Reset All Data button should exist in Cache tab")
    }

    func testSwitchToGyroTab() {
        openSettings()
        let gyroTab = app.buttons["Gyro"]
        XCTAssertTrue(gyroTab.waitForExistence(timeout: 5), "Gyro tab button should exist")
        gyroTab.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Toggle may render as checkBox (<macOS 15) or switch (macOS 15+)
        let asCheckbox = app.checkBoxes["Enable Gyroflow stabilization"]
        let asSwitch = app.descendants(matching: .switch).firstMatch
        XCTAssertTrue(
            asCheckbox.waitForExistence(timeout: 5) || asSwitch.waitForExistence(timeout: 2),
            "Gyro tab should have at least one toggle"
        )
    }

    func testGeneralTabThemePicker() {
        openSettings()

        // Theme radio buttons should exist (General tab is default)
        let systemRadio = app.radioButtons["System"]
        let lightRadio = app.radioButtons["Light"]
        let darkRadio = app.radioButtons["Dark"]

        XCTAssertTrue(systemRadio.waitForExistence(timeout: 5), "System theme option should exist")
        XCTAssertTrue(lightRadio.exists, "Light theme option should exist")
        XCTAssertTrue(darkRadio.exists, "Dark theme option should exist")
    }

    func testGeneralTabDiagBadgeToggle() {
        openSettings()
        // Try checkBox first (macOS <15), then switch (macOS 15+)
        let pred = NSPredicate(format: "identifier == 'settings.diagBadge'")
        let asCheckbox = app.descendants(matching: .checkBox).matching(pred).firstMatch
        let asSwitch = app.descendants(matching: .switch).matching(pred).firstMatch
        let byLabel = app.checkBoxes["Show diagnostics badge"]
        XCTAssertTrue(
            asCheckbox.waitForExistence(timeout: 3) ||
            asSwitch.waitForExistence(timeout: 3) ||
            byLabel.waitForExistence(timeout: 3),
            "Diagnostics badge toggle should exist"
        )
    }

    func testResetAllDataConfirmation() {
        openSettings()
        let cacheTab = app.buttons["Cache"]
        XCTAssertTrue(cacheTab.waitForExistence(timeout: 5))
        cacheTab.click()

        let resetBtn = app.buttons["Reset All Data\u{2026}"]
        XCTAssertTrue(resetBtn.waitForExistence(timeout: 3))
        resetBtn.click()

        // confirmationDialog renders as a sheet on macOS
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Reset confirmation sheet should appear")

        // Cancel instead of actually resetting
        let cancelBtn = sheet.buttons["Cancel"]
        if cancelBtn.exists { cancelBtn.click() }
    }
}
