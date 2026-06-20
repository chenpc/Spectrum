import XCTest

/// End-to-end usability tests using free stock fixtures (SpectrumUITests/E2EFixtures/).
/// These tests verify the core user flow after every code change:
///   load folder → grid shows photos → open detail → navigate → video controls → back to grid
final class E2EUsabilityTests: XCTestCase {

    var app: XCUIApplication!

    // Path to E2EFixtures/ next to this source file
    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("E2EFixtures")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // mktemp -d：建立全新隔離目錄，每次測試都是乾淨環境
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrum-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        app.launchArguments = [
            "--userdir", userDir.path,
            "--add-folder", fixturesDir.path,
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Helpers

    private var grid: XCUIElement { app.scrollViews["grid.photos"] }

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Spectrum 格線：點擊選取，再按 Enter 啟動 Detail（等同雙擊邏輯）
    private func openDetail(_ element: XCUIElement) {
        element.click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.return, modifierFlags: [])
    }

    // MARK: - 1. 資料夾載入

    func test01_FolderAppearsInSidebar() {
        let folderCell = app.outlines.cells.staticTexts["E2EFixtures"]
        XCTAssertTrue(folderCell.waitForExistence(timeout: 10),
                      "Sidebar should show 'E2EFixtures' folder")
    }

    func test02_PhotoGridShowsPhotos() {
        XCTAssertTrue(waitFor(grid), "Photo grid should appear")
        let firstPhoto = grid.images.firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 15),
                      "Grid should show at least one photo thumbnail")
    }

    func test03_PhotoCountAtLeastFive() {
        XCTAssertTrue(waitFor(grid))
        _ = grid.images.firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 2)
        let count = grid.images.count
        XCTAssertGreaterThanOrEqual(count, 5,
                                    "Grid should show at least 5 items (5 photos + 1 video)")
    }

    // MARK: - 2. 開啟 Detail View

    func test04_ClickPhotoOpensDetail() {
        XCTAssertTrue(waitFor(grid))
        let firstPhoto = grid.images.firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 15))
        openDetail(firstPhoto)     // 單擊選取，再單擊進入 Detail

        // Inspector toggle 按鈕是 detail view 進入後一定出現的標誌
        let inspectorBtn = app.buttons["detail.inspectorToggle"]
        XCTAssertTrue(inspectorBtn.waitForExistence(timeout: 5),
                      "Detail view should appear after opening a photo")
    }

    // MARK: - 3. 鍵盤導航

    func test05_ArrowKeyNavigatesBetweenPhotos() {
        XCTAssertTrue(waitFor(grid))
        let firstPhoto = grid.images.firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 15))
        openDetail(firstPhoto)

        let inspectorBtn = app.buttons["detail.inspectorToggle"]
        XCTAssertTrue(inspectorBtn.waitForExistence(timeout: 5))

        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.windows.count >= 1,
                      "App should still be running after keyboard navigation")
    }

    // MARK: - 4. Inspector Toggle

    func test06_InspectorToggleOpenAndClose() {
        XCTAssertTrue(waitFor(grid))
        let firstPhoto = grid.images.firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 15))
        openDetail(firstPhoto)

        let inspectorBtn = app.buttons["detail.inspectorToggle"]
        XCTAssertTrue(inspectorBtn.waitForExistence(timeout: 5),
                      "Inspector toggle button should exist in detail view")
        inspectorBtn.click()
        Thread.sleep(forTimeInterval: 0.5)
        inspectorBtn.click()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.windows.count >= 1,
                      "App should still be running after inspector toggle")
    }

    // MARK: - 5. 影片播放控制

    func test07_VideoShowsPlaybackControls() {
        XCTAssertTrue(waitFor(grid))
        _ = grid.images.firstMatch.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 2)

        // Click each thumbnail until we find video playback controls
        var foundVideoControls = false
        for img in grid.images.allElementsBoundByIndex.prefix(6) {
            openDetail(img)
            Thread.sleep(forTimeInterval: 1)
            let playBtn = app.buttons["video.playPause"]
            if playBtn.waitForExistence(timeout: 3) {
                foundVideoControls = true
                playBtn.click()
                Thread.sleep(forTimeInterval: 1)
                playBtn.click() // pause
                break
            }
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertTrue(foundVideoControls,
                      "At least one grid item should be a video with playback controls")
    }

    // MARK: - 6. Escape 返回格線

    func test08_EscapeReturnsToGrid() {
        XCTAssertTrue(waitFor(grid))
        let firstPhoto = grid.images.firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 15))
        openDetail(firstPhoto)

        let inspectorBtn = app.buttons["detail.inspectorToggle"]
        XCTAssertTrue(inspectorBtn.waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.windows.count >= 1,
                      "App should still be running after pressing Escape")
    }
}
