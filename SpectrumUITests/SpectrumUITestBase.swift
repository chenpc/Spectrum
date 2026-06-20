import XCTest

/// Base class for all Spectrum UI tests.
/// Launches the app with `--userdir` pointing to a fresh mktemp directory
/// so tests run in a fully isolated environment (database + UserDefaults).
class SpectrumUITestBase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrum-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        app.launchArguments = ["--userdir", userDir.path]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Helpers

    /// Wait for an element to exist within `timeout` seconds.
    @discardableResult
    func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Element \(element.identifier) did not appear within \(timeout)s")
        return element
    }

    /// Open Settings via Cmd+, (universal macOS Settings shortcut)
    func openSettings() {
        // Wait for main window, then send Cmd+, to open Settings
        _ = app.windows.firstMatch.waitForExistence(timeout: 5)
        app.activate()
        app.typeKey(",", modifierFlags: .command)
    }
}
