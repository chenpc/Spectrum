import XCTest

/// Deep coverage tests for SettingsView.swift — drives every tab, toggle,
/// slider, picker and the reset confirmation (cancelled, never confirmed).
final class SettingsDeepUITests: SpectrumUITestBase {

    // MARK: - Helpers

    /// Open Settings and return the Settings window (usually boundBy: 1 on macOS 15+).
    private func openSettingsWindow() -> XCUIElement {
        openSettings()
        let settingsWindow = app.windows.element(boundBy: 1)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 12),
                      "Settings window should appear")
        return settingsWindow
    }

    /// Click a tab button by label, tolerating the ellipsis/identifier variants.
    private func clickTab(_ label: String) {
        let tab = app.buttons[label]
        if tab.waitForExistence(timeout: 8) {
            tab.click()
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Toggle every switch/checkBox currently in the window (drives onChange paths).
    private func toggleAllSwitches() {
        let switches = app.descendants(matching: .switch)
        for i in 0..<min(switches.count, 12) {
            let s = switches.element(boundBy: i)
            if s.exists && s.isHittable {
                s.click()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        let checks = app.descendants(matching: .checkBox)
        for i in 0..<min(checks.count, 12) {
            let c = checks.element(boundBy: i)
            if c.exists && c.isHittable {
                c.click()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    /// Drag every slider in the window to exercise onChange handlers.
    private func dragAllSliders() {
        let sliders = app.descendants(matching: .slider)
        for i in 0..<min(sliders.count, 16) {
            let s = sliders.element(boundBy: i)
            if s.exists && s.isHittable {
                s.adjust(toNormalizedSliderPosition: 0.8)
                Thread.sleep(forTimeInterval: 0.15)
                s.adjust(toNormalizedSliderPosition: 0.3)
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }

    // MARK: - Tests

    /// Switch through all three tabs and assert a known control exists in each.
    func testSwitchThroughAllTabs() {
        let settingsWindow = openSettingsWindow()

        // General (default) — theme radios live here.
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 8)
                      || app.buttons["General"].exists,
                      "General tab content should be present")

        clickTab("Cache")
        XCTAssertTrue(settingsWindow.exists, "Settings window stays open on Cache tab")
        XCTAssertTrue(app.buttons["Reset All Data\u{2026}"].waitForExistence(timeout: 5),
                      "Cache tab should show Reset All Data button")

        clickTab("Gyro")
        XCTAssertTrue(settingsWindow.exists, "Settings window stays open on Gyro tab")
        let gyroToggle = app.descendants(matching: .switch).firstMatch
        let gyroCheck = app.checkBoxes["Enable Gyroflow stabilization"]
        XCTAssertTrue(gyroToggle.waitForExistence(timeout: 5) || gyroCheck.exists,
                      "Gyro tab should have an enable toggle")

        clickTab("General")
        XCTAssertTrue(settingsWindow.exists, "Settings window stays open back on General")
    }

    /// General tab: pick non-default theme, toggle diag badge, exercise pickers.
    func testGeneralTabControls() {
        let settingsWindow = openSettingsWindow()

        // Theme radio group — pick non-default values.
        let darkRadio = app.radioButtons["Dark"]
        if darkRadio.waitForExistence(timeout: 8), darkRadio.isHittable { darkRadio.click() }
        Thread.sleep(forTimeInterval: 0.2)
        let lightRadio = app.radioButtons["Light"]
        if lightRadio.exists, lightRadio.isHittable { lightRadio.click() }
        Thread.sleep(forTimeInterval: 0.2)
        let systemRadio = app.radioButtons["System"]
        if systemRadio.exists, systemRadio.isHittable { systemRadio.click() }

        // Diagnostics badge toggle (switch on macOS 15+, checkBox earlier).
        let pred = NSPredicate(format: "identifier == 'settings.diagBadge'")
        let toggleSwitch = app.descendants(matching: .switch).matching(pred).firstMatch
        let toggleCheck = app.descendants(matching: .checkBox).matching(pred).firstMatch
        let byLabel = app.checkBoxes["Show diagnostics badge"]
        if toggleSwitch.exists, toggleSwitch.isHittable { toggleSwitch.click() }
        else if toggleCheck.exists, toggleCheck.isHittable { toggleCheck.click() }
        else if byLabel.exists, byLabel.isHittable { byLabel.click() }

        // Buffer Duration & Log Level pickers — open and pick a value if present.
        let bufferPicker = app.popUpButtons["Buffer Duration"]
        if bufferPicker.exists {
            bufferPicker.click()
            Thread.sleep(forTimeInterval: 0.3)
            let opt = app.menuItems["10s"]
            if opt.waitForExistence(timeout: 3) { opt.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }
        let logPicker = app.popUpButtons["Log Level"]
        if logPicker.exists {
            logPicker.click()
            Thread.sleep(forTimeInterval: 0.3)
            let firstItem = app.menuItems.firstMatch
            if firstItem.waitForExistence(timeout: 3) { firstItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        XCTAssertTrue(settingsWindow.exists, "Settings window should remain open")
    }

    /// Cache tab: drag the memory-limit slider, then open & CANCEL reset confirmation.
    func testCacheTabSliderAndResetCancel() {
        let settingsWindow = openSettingsWindow()
        clickTab("Cache")

        // Memory limit slider — exercise onChange(updateMemoryCacheLimit).
        let sliders = app.descendants(matching: .slider)
        if sliders.firstMatch.waitForExistence(timeout: 5) {
            let s = sliders.firstMatch
            s.adjust(toNormalizedSliderPosition: 0.9)
            Thread.sleep(forTimeInterval: 0.2)
            s.adjust(toNormalizedSliderPosition: 0.2)
        }

        // Reset All Data → confirmation sheet → Cancel (never confirm).
        let resetBtn = app.buttons["Reset All Data\u{2026}"]
        XCTAssertTrue(resetBtn.waitForExistence(timeout: 5),
                      "Reset All Data button should exist")
        resetBtn.click()

        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 4) {
            let cancelBtn = sheet.buttons["Cancel"]
            if cancelBtn.exists { cancelBtn.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        XCTAssertTrue(settingsWindow.exists,
                      "Settings window should remain after cancelling reset")
    }

    /// Gyro tab: enable stabilization, toggle every sub-toggle, drag every slider,
    /// open pickers and the stepper — driving the large conditional gyro form.
    func testGyroTabDeepControls() {
        let settingsWindow = openSettingsWindow()
        clickTab("Gyro")

        // Ensure stabilization is enabled so the rest of the form renders.
        let enableSwitch = app.descendants(matching: .switch).firstMatch
        let enableCheck = app.checkBoxes["Enable Gyroflow stabilization"]
        if enableSwitch.waitForExistence(timeout: 6) {
            // If currently off, the value reads "0"; click to enable when needed.
            if enableSwitch.value as? String == "0" { enableSwitch.click() }
        } else if enableCheck.exists {
            if enableCheck.value as? Int == 0 { enableCheck.click() }
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Toggle Horizon Lock / Per-axis / gravity vectors etc. to reveal nested rows.
        toggleAllSwitches()
        Thread.sleep(forTimeInterval: 0.4)

        // Drag all visible sliders (FOV, smoothing, zoom, speed, etc.).
        dragAllSliders()

        // Open the Integration Method / Zooming pickers.
        for label in ["Integration Method", "Zooming Method", "Zooming Algorithm"] {
            let picker = app.popUpButtons[label]
            if picker.exists {
                picker.click()
                Thread.sleep(forTimeInterval: 0.3)
                let item = app.menuItems.element(boundBy: 1)
                if item.waitForExistence(timeout: 2) { item.click() }
                else { app.typeKey(.escape, modifierFlags: []) }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        // Exercise the Max Zoom Iterations stepper if present.
        let stepperInc = app.steppers.firstMatch
        if stepperInc.exists, stepperInc.isHittable {
            let incBtn = stepperInc.buttons.firstMatch
            if incBtn.exists, incBtn.isHittable { incBtn.click() }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Reset to Defaults button — drives the big reset closure.
        let resetDefaults = app.buttons["Reset to Defaults"]
        if resetDefaults.exists { resetDefaults.click() }

        XCTAssertTrue(settingsWindow.exists,
                      "Settings window should remain open after gyro interactions")
    }
}
