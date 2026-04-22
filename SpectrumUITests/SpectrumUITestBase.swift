import XCTest

/// Base class for all Spectrum UI tests.
/// Launches the app with `--spectrum-library` pointing to a temporary directory
/// so tests don't affect the user's real library.
class SpectrumUITestBase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Use an isolated library so tests don't touch real data
        let tmpLib = NSTemporaryDirectory() + "spectrum-uitest-\(UUID().uuidString)"
        app.launchArguments = ["--spectrum-library", tmpLib]
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

    /// Open Settings via menu bar: Spectrum → Settings…
    func openSettings() {
        app.menuBars.menuBarItems["Spectrum"].click()
        app.menuBars.menuItems["Settings…"].click()
    }
}
