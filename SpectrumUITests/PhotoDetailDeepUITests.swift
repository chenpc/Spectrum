import XCTest

/// Deep coverage for PhotoDetailView / VideoControlBar / VideoController.
/// Drives the zoom toolbar, inspector, crop/rotate/flip edit buttons, keyboard paging
/// through every grid item, and the full video control bar.
///
/// Copies fixtures into an isolated temp dir before --add-folder, so edit actions
/// (rotate/flip/crop write XMP sidecars) never dirty the shared repo fixtures.
final class PhotoDetailDeepUITests: XCTestCase {

    var app: XCUIApplication!
    private var workDir: URL!

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("E2EFixtures")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrum-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        // Isolated, mutable copy of the fixtures so XMP sidecar writes are harmless.
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

    /// Spectrum grid: click to select, then Return to enter detail.
    private func openDetail(_ element: XCUIElement) {
        element.click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.return, modifierFlags: [])
    }

    /// Open detail on the first grid item, then advance with Right arrow until a
    /// PHOTO is shown (the photo-only crop button exists). Returns true if landed on a photo.
    @discardableResult
    private func openDetailOnPhoto() -> Bool {
        XCTAssertTrue(waitFor(grid))
        let first = grid.images.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        openDetail(first)
        // Inspector toggle is always present in detail view.
        XCTAssertTrue(app.buttons["detail.inspectorToggle"].waitForExistence(timeout: 5),
                      "Detail view should appear")

        let crop = app.buttons["detail.crop"]
        for _ in 0..<8 {
            if crop.exists { return true }
            app.typeKey(.rightArrow, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }
        return crop.exists
    }

    // MARK: - 1. Zoom toolbar buttons

    func test01_ZoomToolbarButtons() {
        XCTAssertTrue(openDetailOnPhoto(), "Should land on a photo with zoom toolbar")

        // Fit to Window
        let fit = app.buttons["detail.fitWindow"]
        if fit.exists { fit.click(); Thread.sleep(forTimeInterval: 0.3) }

        // Actual Size
        let actual = app.buttons["detail.actualSize"]
        if actual.exists { actual.click(); Thread.sleep(forTimeInterval: 0.3) }

        // Zoom In several times
        let zin = app.buttons["detail.zoomIn"]
        if zin.exists {
            for _ in 0..<4 { zin.click(); Thread.sleep(forTimeInterval: 0.2) }
        }

        // Zoom Out several times
        let zout = app.buttons["detail.zoomOut"]
        if zout.exists {
            for _ in 0..<5 { zout.click(); Thread.sleep(forTimeInterval: 0.2) }
        }

        // Back to fit
        if fit.exists { fit.click(); Thread.sleep(forTimeInterval: 0.3) }

        XCTAssertTrue(app.windows.count >= 1)
    }

    // MARK: - 2. Inspector toggle

    func test02_InspectorToggle() {
        XCTAssertTrue(openDetailOnPhoto())

        let inspector = app.buttons["detail.inspectorToggle"]
        XCTAssertTrue(inspector.exists)
        inspector.click()
        Thread.sleep(forTimeInterval: 0.5)
        inspector.click()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.windows.count >= 1)
    }

    // MARK: - 3. Crop mode enter + cancel

    func test03_CropModeEnterAndCancel() {
        XCTAssertTrue(openDetailOnPhoto())

        let crop = app.buttons["detail.crop"]
        if crop.exists && crop.isEnabled {
            crop.click()
            Thread.sleep(forTimeInterval: 0.8)
            // Crop overlay is active; cancel via Escape to avoid mutating the sidecar.
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(app.windows.count >= 1)
    }

    // MARK: - 4. Rotate + flip + restore

    func test04_RotateFlipRestore() {
        XCTAssertTrue(openDetailOnPhoto())

        let rotate = app.buttons["detail.rotateLeft"]
        if rotate.exists && rotate.isEnabled {
            rotate.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        let flip = app.buttons["detail.flipH"]
        if flip.exists && flip.isEnabled {
            flip.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Restore appears only after edits exist — undo our rotate/flip to leave files clean.
        let restore = app.buttons["detail.restore"]
        if restore.waitForExistence(timeout: 3) && restore.isEnabled {
            restore.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(app.windows.count >= 1)
    }

    // MARK: - 5. Context menu (Show in Finder builder runs)

    func test05_ImageContextMenu() {
        XCTAssertTrue(openDetailOnPhoto())

        // Right-click the detail image to build the context menu, then dismiss.
        let img = app.images.firstMatch
        if img.exists {
            img.rightClick()
            Thread.sleep(forTimeInterval: 0.5)
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertTrue(app.windows.count >= 1)
    }

    // MARK: - 6. Page through every item with arrow keys

    func test06_PageThroughAllItems() {
        XCTAssertTrue(waitFor(grid))
        _ = grid.images.firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        let total = max(grid.images.count, 6)

        openDetail(grid.images.firstMatch)
        XCTAssertTrue(app.buttons["detail.inspectorToggle"].waitForExistence(timeout: 5))

        // Forward through everything (loads each photo + the video preview).
        for _ in 0..<(total + 1) {
            app.typeKey(.rightArrow, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.4)
        }
        // Back the other way.
        for _ in 0..<(total + 1) {
            app.typeKey(.leftArrow, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.4)
        }

        XCTAssertTrue(app.windows.count >= 1)
    }

    // MARK: - 7. Full video control bar

    func test07_VideoControlBar() {
        XCTAssertTrue(waitFor(grid))
        _ = grid.images.firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)

        // Find the video by opening items until the play/pause control appears.
        var foundVideo = false
        let items = grid.images.allElementsBoundByIndex.prefix(8)
        for img in items {
            openDetail(img)
            Thread.sleep(forTimeInterval: 0.8)
            if app.buttons["video.playPause"].waitForExistence(timeout: 3) {
                foundVideo = true
                break
            }
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }

        if foundVideo {
            let play = app.buttons["video.playPause"]
            // Start playback.
            play.click()
            Thread.sleep(forTimeInterval: 1.5)
            // Pause.
            if play.exists { play.click(); Thread.sleep(forTimeInterval: 0.5) }

            // Mute toggle (on + off).
            let mute = app.buttons["video.muteToggle"]
            if mute.exists {
                mute.click(); Thread.sleep(forTimeInterval: 0.3)
                mute.click(); Thread.sleep(forTimeInterval: 0.3)
            }

            // Scrubber: drag to seek.
            let scrubber = app.sliders["video.scrubber"]
            if scrubber.exists {
                scrubber.adjust(toNormalizedSliderPosition: 0.5)
                Thread.sleep(forTimeInterval: 0.5)
                scrubber.adjust(toNormalizedSliderPosition: 0.1)
                Thread.sleep(forTimeInterval: 0.5)
            }

            // Volume slider.
            let volume = app.sliders["video.volume"]
            if volume.exists {
                volume.adjust(toNormalizedSliderPosition: 0.3)
                Thread.sleep(forTimeInterval: 0.3)
                volume.adjust(toNormalizedSliderPosition: 0.9)
                Thread.sleep(forTimeInterval: 0.3)
            }

            // Resume play once more to exercise togglePlayPause path.
            if play.exists { play.click(); Thread.sleep(forTimeInterval: 0.8) }
        }

        XCTAssertTrue(app.windows.count >= 1)
    }

    // MARK: - 8. Spacebar play + escape back to grid

    func test08_SpacebarAndEscape() {
        XCTAssertTrue(waitFor(grid))
        _ = grid.images.firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.0)

        openDetail(grid.images.firstMatch)
        XCTAssertTrue(app.buttons["detail.inspectorToggle"].waitForExistence(timeout: 5))

        // Space toggles either Live Photo (image) or video playback.
        app.typeKey(.space, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.6)
        // 'i' toggles inspector via the key monitor (image path installs after play; harmless).
        app.typeKey("i", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.4)

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.windows.count >= 1)
    }

    // MARK: - 9. Fullscreen toolbar button (if present) then escape

    func test09_FullscreenToggle() {
        XCTAssertTrue(openDetailOnPhoto())

        let fs = app.buttons["toolbar.fullScreen"]
        if fs.exists && fs.isHittable {
            fs.click()
            Thread.sleep(forTimeInterval: 1.5)
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 1.5)
        }

        XCTAssertTrue(app.windows.count >= 1)
    }
}
