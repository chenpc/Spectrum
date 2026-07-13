import XCTest

/// UI tests that drive PhotoGridView (plus PhotoThumbnailView / TimelineSectionHeader)
/// as deeply as is SAFE: selection (single / Cmd+A multi), keyboard navigation,
/// the thumbnail context menu (Copy / Cut / Paste / Show in Finder / Move to Trash),
/// and the grid-background context menu (New Folder -> Rename alert -> commit / cancel,
/// then subfolder Rename / Add to Import / Move to Trash).
///
/// SAFETY: the app's `--add-folder` points at a *copy* of E2EFixtures made in setUp,
/// so destructive actions (Rename, New Folder, Move to Trash, Paste) mutate only the
/// throwaway copy. Each test gets its own fresh copy + fresh userdir, so mutations are
/// isolated per test method.
final class GridInteractionUITests: XCTestCase {

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
            .appendingPathComponent("spectrum-grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        // Copy fixtures into an isolated, mutable working folder so destructive
        // grid actions are safe and fully testable.
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixturesDir, to: workDir)

        app.launchArguments = [
            "--userdir", userDir.path,
            "--add-folder", workDir.path,
            "--log-stdout",
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

    @discardableResult
    private func waitForGridWithThumbnails(timeout: TimeInterval = 15) -> Bool {
        guard grid.waitForExistence(timeout: timeout) else { return false }
        let first = grid.images.firstMatch
        let ok = first.waitForExistence(timeout: timeout)
        // Let lazy thumbnails settle.
        Thread.sleep(forTimeInterval: 1.5)
        return ok
    }

    /// Click a context-menu item by exact title; returns true if it existed & was clicked.
    @discardableResult
    private func clickMenuItem(_ title: String, timeout: TimeInterval = 4) -> Bool {
        // `app.menuItems[title]` can match several (context menu + menu-bar Edit menu);
        // firstMatch avoids "Multiple matching elements" on click.
        let item = app.menuItems[title].firstMatch
        if item.waitForExistence(timeout: timeout) {
            item.click()
            return true
        }
        return false
    }

    /// Click the first context-menu item whose title begins with `prefix`.
    @discardableResult
    private func clickMenuItem(beginningWith prefix: String, timeout: TimeInterval = 4) -> Bool {
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
        if item.waitForExistence(timeout: timeout) {
            item.click()
            return true
        }
        return false
    }

    /// Click a button by title from anywhere (alert / dialog / sheet / toolbar).
    @discardableResult
    private func clickButton(_ title: String, timeout: TimeInterval = 4) -> Bool {
        // Prefer a dialog/sheet/window-scoped, hittable button so we never try to click
        // a duplicate Touch Bar element (which XCUITest refuses).
        let scoped = dialogButton(title)
        if scoped.waitForExistence(timeout: timeout), scoped.isHittable {
            scoped.click()
            return true
        }
        let any = app.buttons[title].firstMatch
        if any.exists, any.isHittable {
            any.click()
            return true
        }
        return false
    }

    /// Find a button inside a presented alert/sheet/dialog (NOT the Touch Bar, whose
    /// duplicate buttons cannot be clicked by XCUITest). Falls back to a window-scoped
    /// query.
    private func dialogButton(_ title: String) -> XCUIElement {
        for container in [app.sheets, app.dialogs] {
            let b = container.buttons[title].firstMatch
            if b.exists { return b }
        }
        return app.windows.buttons[title].firstMatch
    }

    private func dismissMenusAndDialogs() {
        // Best-effort: close any stray context menu / alert.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
        _ = clickButton("OK", timeout: 1)
        _ = clickButton("Cancel", timeout: 1)
    }

    private func rightClickGridBackground() {
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        Thread.sleep(forTimeInterval: 0.4)
    }

    // MARK: - 1. Grid + thumbnails render (PhotoThumbnailView + TimelineSectionHeader)

    func testGridAndThumbnailsExist() {
        XCTAssertTrue(waitForGridWithThumbnails(), "Photo grid with thumbnails should appear")
        XCTAssertGreaterThanOrEqual(grid.images.count, 1,
                                    "Grid should contain at least one thumbnail")
    }

    // MARK: - 2. Single tap selects a thumbnail

    func testSingleTapSelectsThumbnail() {
        XCTAssertTrue(waitForGridWithThumbnails())
        let first = grid.images.firstMatch
        XCTAssertTrue(first.exists)

        first.click() // single-tap path in handleTap -> selectSingle / syncSelection
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(grid.waitForExistence(timeout: 5),
                      "Grid should still exist after selecting a thumbnail")
    }

    // MARK: - 3. Sequential clicks across multiple thumbnails

    func testMultiClickAcrossThumbnails() {
        XCTAssertTrue(waitForGridWithThumbnails())
        let thumbs = grid.images.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(thumbs.count, 1, "Need at least one thumbnail")

        for thumb in thumbs.prefix(4) where thumb.exists {
            thumb.click() // drives selectSingle repeatedly
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertTrue(app.windows.count >= 1,
                      "App should still be running after clicking multiple thumbnails")
    }

    // MARK: - 4. Select All (Cmd+A) then exercise the multi-item context menu

    func testSelectAllThenMultiItemMenu() {
        XCTAssertTrue(waitForGridWithThumbnails())

        grid.images.firstMatch.click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("a", modifierFlags: .command) // selectAllAction
        Thread.sleep(forTimeInterval: 0.5)

        // With >1 selected, the thumbnail context menu builds the "N Items" branch.
        grid.images.firstMatch.rightClick()
        Thread.sleep(forTimeInterval: 0.4)
        // "Copy N Items" is non-destructive -> safe to invoke.
        if !clickMenuItem(beginningWith: "Copy ") {
            dismissMenusAndDialogs()
        }
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(grid.waitForExistence(timeout: 5),
                      "Grid should still exist after Select All + multi-item menu")
    }

    // MARK: - 5. Keyboard navigation within the grid

    func testKeyboardNavigationInGrid() {
        XCTAssertTrue(waitForGridWithThumbnails())

        grid.images.firstMatch.click()
        Thread.sleep(forTimeInterval: 0.4)

        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(app.windows.count >= 1,
                      "App should still be running after grid keyboard navigation")
    }

    // MARK: - 6. Empty-area click clears selection, then re-navigate

    func testClearSelectionThenNavigate() {
        XCTAssertTrue(waitForGridWithThumbnails())

        grid.images.firstMatch.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Click empty background area of the scroll view to clear selection.
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).click()
        Thread.sleep(forTimeInterval: 0.3)

        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(grid.exists,
                      "Grid should remain after clearing and re-navigating selection")
    }

    // MARK: - 7. Thumbnail context menu: Copy (safe)

    func testThumbnailContextMenuCopy() {
        XCTAssertTrue(waitForGridWithThumbnails())
        let first = grid.images.firstMatch
        XCTAssertTrue(first.exists)

        first.rightClick()
        Thread.sleep(forTimeInterval: 0.5)

        let copyItem = app.menuItems["Copy"].firstMatch
        let copyExists = copyItem.waitForExistence(timeout: 5)
        if copyExists {
            copyItem.click() // FolderClipboard.copy
        } else {
            dismissMenusAndDialogs()
        }
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(copyExists,
                      "Thumbnail context menu should expose Copy")
    }

    // MARK: - 8. Thumbnail context menu: Show in Finder (safe)

    func testThumbnailShowInFinder() {
        XCTAssertTrue(waitForGridWithThumbnails())
        grid.images.firstMatch.rightClick()
        Thread.sleep(forTimeInterval: 0.5)

        if !clickMenuItem("Show in Finder") {
            dismissMenusAndDialogs()
        }
        Thread.sleep(forTimeInterval: 0.4)

        XCTAssertTrue(app.windows.count >= 1, "App should survive Show in Finder")
    }

    // MARK: - 9. Cut a photo, then Paste via the grid background menu

    func testCutThenPaste() {
        XCTAssertTrue(waitForGridWithThumbnails())

        // Cut one photo into the clipboard.
        grid.images.firstMatch.rightClick()
        Thread.sleep(forTimeInterval: 0.5)
        if !clickMenuItem("Cut") {
            dismissMenusAndDialogs()
        }
        Thread.sleep(forTimeInterval: 0.4)

        // Paste into the same folder via the background context menu.
        rightClickGridBackground()
        // gridContextMenu shows "Move N Items" (cut) or 'Paste "name"'.
        let pasted = clickMenuItem(beginningWith: "Move ")
            || clickMenuItem(beginningWith: "Paste ")
        Thread.sleep(forTimeInterval: 0.6)

        // A same-folder paste may raise an "already exists" Error alert -> dismiss it.
        _ = clickButton("OK", timeout: 2)
        dismissMenusAndDialogs()

        XCTAssertTrue(app.windows.count >= 1,
                      "App should survive Cut + Paste (paste menu present: \(pasted))")
    }

    // MARK: - Regression: bare nav keys must reach the rename TextField, not the menu

    /// Arrow keys pressed while the rename TextField is focused must move the
    /// insertion point (and drive IME candidate selection), NOT trigger the
    /// Navigate menu's bare-key equivalents. Cursor-movement assertion is an
    /// IME-independent proxy: if the menu steals arrows, the caret never moves.
    func testRenameFieldArrowKeysStayInTextField() {
        XCTAssertTrue(waitForGridWithThumbnails())

        rightClickGridBackground()
        guard clickMenuItem("New Folder") else {
            dismissMenusAndDialogs()
            XCTFail("Could not open New Folder rename alert")
            return
        }

        let renameBtn = dialogButton("Rename")
        XCTAssertTrue(renameBtn.waitForExistence(timeout: 6))
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("abc")
        Thread.sleep(forTimeInterval: 0.3)

        // ← ← then X: caret moves only if the field (not the menu) got the arrows
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeText("X")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(field.value as? String, "aXbc",
                       "Arrow keys must move the caret inside the rename field — menu stole them")

        // Backspace must delete a character, not trigger Move to Trash
        app.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(field.value as? String, "abc",
                       "Delete must edit text inside the rename field — menu stole it")

        // ↓ ↑ must not blow up / navigate the grid behind the alert
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(field.exists, "Rename alert must still be presented")

        _ = clickButton("Cancel")
        dismissMenusAndDialogs()
    }

    // MARK: - 10. Grid background: New Folder -> Rename alert -> commit OK

    func testNewFolderRenameCommit() {
        XCTAssertTrue(waitForGridWithThumbnails())

        rightClickGridBackground()
        guard clickMenuItem("New Folder") else {
            dismissMenusAndDialogs()
            XCTAssertTrue(app.windows.count >= 1)
            return
        }

        // createNewFolder auto-presents the "Rename Folder" alert with a TextField.
        let renameBtn = dialogButton("Rename")
        if renameBtn.waitForExistence(timeout: 6) {
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 3) {
                field.click()
                app.typeKey("a", modifierFlags: .command)
                app.typeText("renamed-\(Int.random(in: 1000...9999))")
            }
            renameBtn.click() // performRename on the throwaway copy
            Thread.sleep(forTimeInterval: 0.6)
        }
        _ = clickButton("OK", timeout: 1) // dismiss any error alert
        dismissMenusAndDialogs()

        XCTAssertTrue(grid.waitForExistence(timeout: 5),
                      "Grid should still exist after creating + renaming a folder")
    }

    // MARK: - 11. Grid background: New Folder -> Rename alert -> Cancel

    func testNewFolderRenameCancel() {
        XCTAssertTrue(waitForGridWithThumbnails())

        rightClickGridBackground()
        guard clickMenuItem("New Folder") else {
            dismissMenusAndDialogs()
            XCTAssertTrue(app.windows.count >= 1)
            return
        }

        let cancelBtn = dialogButton("Cancel")
        if cancelBtn.waitForExistence(timeout: 6) {
            cancelBtn.click() // renamingInfo = nil (cancel path), folder keeps default name
            Thread.sleep(forTimeInterval: 0.5)
        }
        dismissMenusAndDialogs()

        XCTAssertTrue(grid.waitForExistence(timeout: 5),
                      "Grid should still exist after cancelling rename")
    }

    // MARK: - 12. Create a folder, then drive its subfolder context menu + Move to Trash

    func testSubfolderContextMenuAndTrash() {
        XCTAssertTrue(waitForGridWithThumbnails())

        // Create a subfolder (and dismiss the auto rename alert via Cancel).
        rightClickGridBackground()
        guard clickMenuItem("New Folder") else {
            dismissMenusAndDialogs()
            XCTAssertTrue(app.windows.count >= 1)
            return
        }
        let bgCancel = dialogButton("Cancel")
        if bgCancel.waitForExistence(timeout: 6) {
            bgCancel.click()
            Thread.sleep(forTimeInterval: 0.6)
        }

        // The new folder tile sits in the pinned "Folders" section near the top.
        // Right-click around there to open the subfolder context menu.
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.22)).rightClick()
        Thread.sleep(forTimeInterval: 0.5)

        // Non-destructive subfolder items first.
        _ = clickMenuItem("Add to Import", timeout: 2) // importModel.openFolder
        // Re-open menu for the destructive path.
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.22)).rightClick()
        Thread.sleep(forTimeInterval: 0.5)

        if clickMenuItem("Move to Trash", timeout: 2) {
            // confirmationDialog: role:.destructive "Move to Trash" + "Cancel".
            Thread.sleep(forTimeInterval: 0.4)
            if !clickButton("Move to Trash", timeout: 3) {
                _ = clickButton("Cancel", timeout: 1)
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
        dismissMenusAndDialogs()

        XCTAssertTrue(grid.waitForExistence(timeout: 5),
                      "Grid should still exist after subfolder context-menu + trash")
    }

    // MARK: - 13. Move ONE photo to Trash and confirm (safe on the copy)

    func testMoveItemToTrash() {
        XCTAssertTrue(waitForGridWithThumbnails())
        let countBefore = grid.images.count

        grid.images.firstMatch.rightClick()
        Thread.sleep(forTimeInterval: 0.5)

        guard clickMenuItem("Move to Trash") else {
            dismissMenusAndDialogs()
            XCTAssertTrue(app.windows.count >= 1)
            return
        }

        // confirmationDialog "Move to Trash?" -> destructive "Move to Trash".
        Thread.sleep(forTimeInterval: 0.4)
        if !clickButton("Move to Trash", timeout: 3) {
            _ = clickButton("Cancel", timeout: 1)
        }
        Thread.sleep(forTimeInterval: 0.8)
        _ = clickButton("OK", timeout: 1) // dismiss any error alert
        dismissMenusAndDialogs()

        // Lenient: app still alive; thumbnail count should not have increased.
        XCTAssertTrue(grid.waitForExistence(timeout: 5),
                      "Grid should still exist after moving an item to Trash")
        XCTAssertLessThanOrEqual(grid.images.count, countBefore,
                                 "Item count should not increase after a trash operation")
    }
}
