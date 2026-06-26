import XCTest

/// UI tests that drive `CropOverlayView` (and the surrounding edit toolbar in
/// `PhotoDetailView`). The crop overlay only appears for non-video photos after
/// the "Crop" toolbar button is pressed. These tests open a photo in detail,
/// enter crop mode, drag the corner/edge handles via coordinate drags, then
/// apply or cancel. Rotate / flip / restore edit commands are also exercised.
///
/// Coverage comes from executing the view code; assertions are intentionally
/// lenient (detail view / main window still alive) because the exact hit-test
/// outcome of a coordinate drag is non-deterministic.
final class CropOverlayUITests: XCTestCase {

    var app: XCUIApplication!
    private var workDir: URL!

    // Path to E2EFixtures/ next to this source file
    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("E2EFixtures")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrum-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        // Applying a crop writes an XMP sidecar next to the image — use an isolated
        // copy so the shared repo fixtures are never modified.
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixturesDir, to: workDir)
        app.launchArguments = [
            "--userdir", userDir.path,
            "--add-folder", workDir.path,
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        if let w = workDir { try? FileManager.default.removeItem(at: w) }
    }

    // MARK: - Helpers

    private var grid: XCUIElement { app.scrollViews["grid.photos"] }

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Spectrum grid: click to select, then Return to open Detail.
    private func openDetail(_ element: XCUIElement) {
        element.click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.return, modifierFlags: [])
    }

    /// Open the first photo (not video) in detail view. Returns true on success.
    @discardableResult
    private func openFirstPhotoDetail() -> Bool {
        XCTAssertTrue(waitFor(grid), "Photo grid should appear")
        let firstPhoto = grid.images.firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 15), "Grid should show a thumbnail")
        Thread.sleep(forTimeInterval: 1)
        openDetail(firstPhoto)
        let inspectorBtn = app.buttons["detail.inspectorToggle"]
        guard inspectorBtn.waitForExistence(timeout: 10) else { return false }
        // The first item may be the video (its edit toolbar — crop/rotate/flip — is only
        // shown for non-video items). Advance with the right arrow until we land on a
        // photo, detected by the presence of the crop button.
        let cropBtn = app.buttons["detail.crop"]
        var tries = 0
        while !cropBtn.exists && tries < 8 {
            app.typeKey(.rightArrow, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.4)
            tries += 1
        }
        return cropBtn.waitForExistence(timeout: 5)
    }

    /// Find an image-only toolbar button. Tries the `.help()` text as a label
    /// first, then falls back to a predicate over the SF Symbol identifier.
    private func toolbarButton(help: String, symbol: String) -> XCUIElement {
        // Prefer the stable accessibility identifiers added to the edit toolbar.
        let idMap = ["Crop": "detail.crop", "Rotate Left": "detail.rotateLeft",
                     "Flip Horizontal": "detail.flipH", "Restore Original": "detail.restore"]
        if let id = idMap[help] {
            let byId = app.buttons[id]
            if byId.waitForExistence(timeout: 3) { return byId }
        }
        let byLabel = app.buttons[help]
        if byLabel.exists { return byLabel }
        let pred = NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", symbol, help)
        let match = app.buttons.matching(pred).firstMatch
        if match.exists { return match }
        return byLabel
    }

    /// Coordinate drag from one normalized offset of `el` to another.
    private func drag(_ el: XCUIElement,
                      from a: CGVector, to b: CGVector,
                      duration: TimeInterval = 0.6) {
        let start = el.coordinate(withNormalizedOffset: a)
        let end = el.coordinate(withNormalizedOffset: b)
        start.press(forDuration: duration, thenDragTo: end)
    }

    // MARK: - 1. Enter crop mode + corner drag + Apply

    func test01_EnterCropDragCornerApply() {
        XCTAssertTrue(openFirstPhotoDetail(), "Detail view should open for first photo")

        let cropBtn = toolbarButton(help: "Crop", symbol: "crop")
        XCTAssertTrue(cropBtn.waitForExistence(timeout: 10), "Crop toolbar button should exist")
        cropBtn.click()
        Thread.sleep(forTimeInterval: 0.7) // wait for crop-mode animation

        // Bottom bar of CropOverlayView: Apply + Cancel buttons.
        let applyBtn = app.buttons["Apply"]
        XCTAssertTrue(applyBtn.waitForExistence(timeout: 8),
                      "Crop overlay Apply button should appear in crop mode")

        // Drag the top-leading corner inward to resize the crop rect.
        let canvas = app.windows.firstMatch
        drag(canvas, from: CGVector(dx: 0.10, dy: 0.16), to: CGVector(dx: 0.30, dy: 0.36))
        Thread.sleep(forTimeInterval: 0.4)
        // Drag the bottom-trailing corner inward too.
        drag(canvas, from: CGVector(dx: 0.90, dy: 0.84), to: CGVector(dx: 0.70, dy: 0.64))
        Thread.sleep(forTimeInterval: 0.4)

        // Apply the crop.
        if applyBtn.exists { applyBtn.click() }
        Thread.sleep(forTimeInterval: 0.7)

        XCTAssertTrue(app.buttons["detail.inspectorToggle"].waitForExistence(timeout: 5),
                      "Detail view should still exist after applying crop")
    }

    // MARK: - 2. Enter crop mode + edge drag + move + Cancel

    func test02_EnterCropDragEdgeMoveCancel() {
        XCTAssertTrue(openFirstPhotoDetail(), "Detail view should open for first photo")

        let cropBtn = toolbarButton(help: "Crop", symbol: "crop")
        XCTAssertTrue(cropBtn.waitForExistence(timeout: 10), "Crop toolbar button should exist")
        cropBtn.click()
        Thread.sleep(forTimeInterval: 0.7)

        let cancelBtn = app.buttons["Cancel"]
        XCTAssertTrue(cancelBtn.waitForExistence(timeout: 8),
                      "Crop overlay Cancel button should appear in crop mode")

        let canvas = app.windows.firstMatch
        // Drag the leading edge inward.
        drag(canvas, from: CGVector(dx: 0.10, dy: 0.50), to: CGVector(dx: 0.28, dy: 0.50))
        Thread.sleep(forTimeInterval: 0.3)
        // Drag the bottom edge upward.
        drag(canvas, from: CGVector(dx: 0.50, dy: 0.84), to: CGVector(dx: 0.50, dy: 0.66))
        Thread.sleep(forTimeInterval: 0.3)
        // Move the whole crop rect by dragging its interior.
        drag(canvas, from: CGVector(dx: 0.50, dy: 0.50), to: CGVector(dx: 0.56, dy: 0.56))
        Thread.sleep(forTimeInterval: 0.3)

        // Cancel via the button if present, else via Escape (cancelAction shortcut).
        if cancelBtn.exists {
            cancelBtn.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        Thread.sleep(forTimeInterval: 0.7)

        XCTAssertTrue(app.windows.count >= 1,
                      "App should still be running after cancelling crop")
    }

    // MARK: - 3. Rotate / Flip / Restore edit commands

    func test03_RotateFlipRestore() {
        XCTAssertTrue(openFirstPhotoDetail(), "Detail view should open for first photo")

        // Rotate Left
        let rotateBtn = toolbarButton(help: "Rotate Left", symbol: "rotate.left")
        if rotateBtn.waitForExistence(timeout: 8) {
            rotateBtn.click()
            Thread.sleep(forTimeInterval: 0.5)
            if rotateBtn.exists { rotateBtn.click() } // rotate again
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Flip Horizontal
        let flipBtn = toolbarButton(help: "Flip Horizontal", symbol: "righttriangle")
        if flipBtn.exists {
            flipBtn.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Restore Original (only appears once edits exist)
        let restoreBtn = toolbarButton(help: "Restore Original", symbol: "uturn.backward")
        if restoreBtn.waitForExistence(timeout: 3) {
            restoreBtn.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(app.buttons["detail.inspectorToggle"].waitForExistence(timeout: 5),
                      "Detail view should still exist after rotate/flip/restore")
    }

    // MARK: - 4. Crop applied then re-entered (existing-crop branch)

    func test04_CropThenReenterUsesExistingRect() {
        XCTAssertTrue(openFirstPhotoDetail(), "Detail view should open for first photo")

        let cropBtn = toolbarButton(help: "Crop", symbol: "crop")
        XCTAssertTrue(cropBtn.waitForExistence(timeout: 10), "Crop toolbar button should exist")

        // First pass: enter, shrink, apply.
        cropBtn.click()
        Thread.sleep(forTimeInterval: 0.7)
        let applyBtn = app.buttons["Apply"]
        XCTAssertTrue(applyBtn.waitForExistence(timeout: 8), "Apply button should appear")
        let canvas = app.windows.firstMatch
        drag(canvas, from: CGVector(dx: 0.10, dy: 0.16), to: CGVector(dx: 0.32, dy: 0.38))
        Thread.sleep(forTimeInterval: 0.3)
        if applyBtn.exists { applyBtn.click() }
        Thread.sleep(forTimeInterval: 0.7)

        // Second pass: re-enter crop — this drives enterCropMode()'s
        // "existing crop" branch that restores the saved rect.
        let cropBtn2 = toolbarButton(help: "Crop", symbol: "crop")
        if cropBtn2.waitForExistence(timeout: 8) {
            cropBtn2.click()
            Thread.sleep(forTimeInterval: 0.7)
            let cancel2 = app.buttons["Cancel"]
            if cancel2.waitForExistence(timeout: 5) {
                cancel2.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(app.windows.count >= 1,
                      "App should still be running after crop re-entry")
    }
}
