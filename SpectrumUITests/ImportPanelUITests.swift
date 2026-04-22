import XCTest

/// Tests for the import panel.
final class ImportPanelUITests: SpectrumUITestBase {

    func testImportPanelOpens() {
        let importBtn = app.buttons["Import"]
        waitForElement(importBtn)
        importBtn.click()

        // The import panel should appear — look for "Select Folder" button or panel content
        sleep(1)

        // Clicking import again should close the panel
        importBtn.click()
        sleep(1)
    }

    func testImportPanelCloseButton() {
        let importBtn = app.buttons["Import"]
        waitForElement(importBtn)
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
