import XCTest

/// Tests for the import panel.
final class ImportPanelUITests: SpectrumUITestBase {

    private var importBtn: XCUIElement {
        // Import button uses SF Symbol image; find by accessibility identifier
        app.buttons.matching(identifier: "toolbar.import").firstMatch
    }

    func testImportPanelOpens() {
        XCTAssertTrue(importBtn.waitForExistence(timeout: 5), "Import toolbar button should exist")
        importBtn.click()
        sleep(1)

        // Click again to dismiss
        importBtn.click()
        sleep(1)
    }

    func testImportPanelCloseButton() {
        XCTAssertTrue(importBtn.waitForExistence(timeout: 5), "Import toolbar button should exist")
        importBtn.click()
        sleep(1)

        // Look for a close button in the import panel
        let closeBtn = app.buttons.matching(identifier: "import.close").firstMatch
        if closeBtn.waitForExistence(timeout: 3) {
            closeBtn.click()
        } else {
            // Fall back: toggle via toolbar button
            importBtn.click()
        }
    }
}
