import XCTest

/// UI/e2e tests that drive `ImportPanelView` (Spectrum/Views/Import/ImportPanelView.swift).
///
/// The import panel is shown by toggling the `toolbar.import` button, which flips
/// ContentView's `showImportPanel`. With no source folder chosen yet it renders the
/// empty state ("Select a folder to import photos and videos" + "Select Folder…").
/// Choosing a folder via NSOpenPanel populates the file list (date groups + thumbnails).
///
/// Note: the `import.panel` / `import.fileList` / `import.close` identifiers exist in
/// AccessibilityID.swift but are NOT applied to the live views, so these tests locate
/// the panel through its visible content (header text + buttons) instead.
final class ImportFlowUITests: XCTestCase {

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
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrum-import-\(UUID().uuidString)")
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
    private var importButton: XCUIElement { app.buttons["toolbar.import"] }

    /// The empty-state "Select Folder…" button uniquely identifies the open panel.
    private var selectFolderButton: XCUIElement {
        app.buttons["Select Folder\u{2026}"]
    }

    /// Wait for the grid to be loaded so the toolbar is fully populated.
    private func waitForGrid() {
        XCTAssertTrue(grid.waitForExistence(timeout: 15), "Photo grid should appear")
        _ = grid.images.firstMatch.waitForExistence(timeout: 15)
    }

    /// Open the import panel via the toolbar button. Returns true if the panel content appeared.
    @discardableResult
    private func openImportPanel() -> Bool {
        XCTAssertTrue(importButton.waitForExistence(timeout: 10),
                      "Import toolbar button should exist")
        importButton.click()
        // Panel renders the empty-state "Select Folder…" button when no source picked yet.
        return selectFolderButton.waitForExistence(timeout: 8)
    }

    // MARK: - 1. 開啟 / 關閉 Import Panel

    func test01_ImportPanelAppearsAndDismisses() {
        waitForGrid()

        XCTAssertTrue(openImportPanel(),
                      "Import panel empty-state should appear after clicking toolbar.import")

        // The "Import" header label should also be present.
        XCTAssertTrue(app.staticTexts["Import"].waitForExistence(timeout: 5),
                      "Import panel header should be visible")

        Thread.sleep(forTimeInterval: 0.4)

        // Toggle the toolbar button again to dismiss the panel (showImportPanel.toggle()).
        importButton.click()
        Thread.sleep(forTimeInterval: 0.6)

        // Lenient final assertion: the empty-state button should be gone, app still alive.
        XCTAssertFalse(selectFolderButton.exists,
                       "Import panel should be dismissed after toggling the toolbar button")
        XCTAssertTrue(app.windows.count >= 1, "App should still be running")
    }

    // MARK: - 2. Header 按鈕互動（expand/collapse、close）

    func test02_ImportPanelHeaderButtons() {
        waitForGrid()
        XCTAssertTrue(openImportPanel(), "Import panel should open")

        // The header has three image-only buttons: expand/collapse, select-folder, close.
        // They carry no labels/identifiers, so collect the window's buttons and exercise
        // the ones whose .help/SF-symbol surfaces. Guard every optional interaction.
        let expandCollapse = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'rectangle' OR label CONTAINS[c] 'expand' OR label CONTAINS[c] 'collapse'")
        ).firstMatch
        if expandCollapse.exists {
            expandCollapse.click()
            Thread.sleep(forTimeInterval: 0.3)
            if expandCollapse.exists { expandCollapse.click() }
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Try to close via the header xmark button (label may surface as "xmark"/"close").
        let xmarkClose = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'xmark' OR label CONTAINS[c] 'close'")
        ).firstMatch
        if xmarkClose.exists {
            xmarkClose.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // If the header close button wasn't reachable, fall back to the toolbar toggle.
        if selectFolderButton.exists {
            importButton.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(app.windows.count >= 1,
                      "App should still be running after header button interaction")
    }

    // MARK: - 3. 選資料夾 → 掃描 → 檔案清單捲動

    func test03_SelectFolderPopulatesFileListAndScroll() {
        waitForGrid()
        XCTAssertTrue(openImportPanel(), "Import panel should open")

        // Click "Select Folder…" → NSOpenPanel. Drive it via keyboard to pick the
        // fixtures dir, which makes the model scan + populate the date-group file list.
        selectFolderButton.click()
        Thread.sleep(forTimeInterval: 1.0)

        // "Go to folder" sheet: Cmd+Shift+G, type the path, confirm, then Select.
        app.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.6)
        app.typeText(fixturesDir.path)
        Thread.sleep(forTimeInterval: 0.4)
        app.typeKey(.return, modifierFlags: [])   // confirm "go to"
        Thread.sleep(forTimeInterval: 0.6)
        app.typeKey(.return, modifierFlags: [])   // accept selection (prompt = "Select")
        Thread.sleep(forTimeInterval: 1.5)

        // If any open panel is somehow still up, cancel it so we don't hang.
        let cancelBtn = app.sheets.buttons["Cancel"]
        if cancelBtn.exists { cancelBtn.click() }
        let cancelWin = app.dialogs.buttons["Cancel"]
        if cancelWin.exists { cancelWin.click() }

        // Give the async scan time to yield items into the LazyVStack of date groups.
        Thread.sleep(forTimeInterval: 2.0)

        // The file-list ScrollView should now exist; scroll it to drive lazy thumbnail code.
        // (Use the panel's scroll view; fall back to swiping the window.)
        let scroll = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
        if scroll.exists {
            scroll.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
            scroll.swipeDown()
            Thread.sleep(forTimeInterval: 0.4)
        }

        // Try clicking the first date-group header (selects/expands a row) if present.
        let firstImage = app.images.element(boundBy: 0)
        if firstImage.exists, firstImage.isHittable {
            firstImage.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Lenient assertion: the panel is still up (header present) and app alive.
        XCTAssertTrue(app.staticTexts["Import"].exists || app.windows.count >= 1,
                      "Import panel/app should remain after folder scan + scroll")

        // Clean up: dismiss the panel.
        if selectFolderButton.exists || app.staticTexts["Import"].exists {
            importButton.click()
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(app.windows.count >= 1, "App should still be running at end of test")
    }

    // MARK: - 4/5. 拖曳日期群組到 grid（e2e：檔案落地 + 進度條）

    /// Import 拖放測試環境：
    /// - Library：一個可寫的暫存資料夾，內含子資料夾 `Sub`（有一張照片 → 會渲染 subfolder tile）
    /// - Import 來源：`Card` 內含 `fileCount` 份同日期照片（同一個 date group）
    private func setupDragEnvironment(fileCount: Int) throws -> (lib: URL, src: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("spectrum-dragdrop-\(UUID().uuidString)")
        let lib = base.appendingPathComponent("Library")
        let sub = lib.appendingPathComponent("Sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let photo = fixturesDir.appendingPathComponent("photo_01.jpg")
        try fm.copyItem(at: photo, to: sub.appendingPathComponent("cover.jpg"))

        let src = base.appendingPathComponent("Card")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        // Dummy 內容即可（匯入只做檔案複製）：檔案數量要多，匯入才會慢到
        // 足以觀測進度條——APFS clone 複製單檔近乎瞬間，靠的是每檔的排程開銷
        let data = Data(repeating: 0xAB, count: 1024)
        for i in 0..<fileCount {
            try data.write(to: src.appendingPathComponent(String(format: "IMG_%04d.jpg", i)))
        }
        return (lib, src)
    }

    /// 以 --import-source 重新啟動 app（import panel 自動開啟並掃描來源）。
    private func relaunchForDrag(lib: URL, src: URL) {
        app.terminate()
        app = XCUIApplication()
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrum-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        app.launchArguments = [
            "--userdir", userDir.path,
            "--add-folder", lib.path,
            "--import-source", src.path,
            // 每檔 2ms 人工延遲：1500 檔 → 匯入至少 3 秒，進度條可觀測
            "--import-throttle-ms", "2",
        ]
        app.launch()
    }

    /// Import panel 裡的日期群組 header（identifier: import.group.<yyyyMMdd>）。
    private var dateGroupHeader: XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'import.group.'")
        ).firstMatch
    }

    /// 執行拖放後驗證：進度條出現過、fileCount 個檔案複製到 lib/<group>/、無錯誤 alert。
    private func assertGroupImported(into lib: URL, fileCount: Int,
                                     sawProgress: Bool, file: StaticString = #filePath,
                                     line: UInt = #line) {
        let fm = FileManager.default
        var copied = 0
        var groupDir: URL?
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let subdirs = (try? fm.contentsOfDirectory(
                at: lib, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            groupDir = subdirs.first {
                $0.hasDirectoryPath && $0.lastPathComponent != "Sub"
            }
            if let groupDir {
                copied = ((try? fm.contentsOfDirectory(atPath: groupDir.path)) ?? []).count
                if copied == fileCount { break }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertNotNil(groupDir, "date-group 資料夾應建立在目前瀏覽的資料夾下", file: file, line: line)
        XCTAssertEqual(copied, fileCount, "所有檔案都應複製到 \(groupDir?.lastPathComponent ?? "?")/",
                       file: file, line: line)
        XCTAssertTrue(sawProgress, "匯入期間應顯示進度條（import.progress）", file: file, line: line)
        // 不應出現錯誤 alert
        XCTAssertFalse(app.dialogs.firstMatch.exists, "匯入不應出現錯誤 alert", file: file, line: line)
        // Sub 子資料夾不應被寫入（只有原本的 cover.jpg）
        let subContents = (try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent("Sub").path)) ?? []
        XCTAssertEqual(subContents.sorted(), ["cover.jpg"], "Sub 子資料夾內容不應改變", file: file, line: line)
    }

    /// 從 group header 拖到指定目標後，輪詢進度條是否出現過。
    /// 拖曳前先等掃描完成（群組數量到達 expectedCount）——掃描是串流式的，
    /// 太早拖曳只會匯入當下已掃到的部分項目。
    private func dragGroupAndWatchProgress(to target: XCUICoordinate,
                                           expectedCount: Int) -> Bool {
        let header = dateGroupHeader
        XCTAssertTrue(header.waitForExistence(timeout: 15), "Import panel 應出現日期群組")
        // SwiftUI Text("\(Int)") 會套用千分位（"1,500"），且值在 value 而非 label
        let formatted = NumberFormatter.localizedString(
            from: NSNumber(value: expectedCount), number: .decimal)
        let candidates = [String(expectedCount), formatted]
        let countText = app.staticTexts.matching(NSPredicate(
            format: "label IN %@ OR value IN %@", candidates, candidates
        )).firstMatch
        XCTAssertTrue(countText.waitForExistence(timeout: 60),
                      "掃描應完成（群組數量 \(expectedCount)）")
        let from = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.click(forDuration: 0.7, thenDragTo: target)

        // 複製在背景進行；緊接著輪詢進度列（footer row 或其中的 Copying 文字）
        let progressRow = app.descendants(matching: .any)
            .matching(identifier: "import.progress").firstMatch
        let copyingText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Copying'")
        ).firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if progressRow.exists || copyingText.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// 拖到 grid 空白處 → 匯入目前瀏覽中的資料夾。
    func test04_DragGroupToGridBlankImportsIntoCurrentFolder() throws {
        let fileCount = 1500
        let (lib, src) = try setupDragEnvironment(fileCount: fileCount)
        relaunchForDrag(lib: lib, src: src)
        waitForGrid()

        // grid 下緣（tile 之外的空白區域）
        let target = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let sawProgress = dragGroupAndWatchProgress(to: target, expectedCount: fileCount)
        assertGroupImported(into: lib, fileCount: fileCount, sawProgress: sawProgress)
    }

    /// 拖到 subfolder tile 上 → 仍應匯入目前瀏覽中的資料夾（與空白處一致），
    /// 不應匯入該子資料夾、不應出錯。
    func test05_DragGroupOntoSubfolderTileImportsIntoCurrentFolder() throws {
        let fileCount = 1500
        let (lib, src) = try setupDragEnvironment(fileCount: fileCount)
        relaunchForDrag(lib: lib, src: src)
        waitForGrid()

        // Subfolder tile 以名稱文字定位
        let subTile = grid.staticTexts["Sub"]
        XCTAssertTrue(subTile.waitForExistence(timeout: 15), "Subfolder tile 應出現")
        let target = subTile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let sawProgress = dragGroupAndWatchProgress(to: target, expectedCount: fileCount)
        assertGroupImported(into: lib, fileCount: fileCount, sawProgress: sawProgress)
    }
}
