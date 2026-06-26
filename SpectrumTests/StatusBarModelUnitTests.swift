import XCTest
@testable import Spectrum

@MainActor
final class StatusBarModelUnitTests: XCTestCase {

    private var model: StatusBarModel { StatusBarModel.shared }

    /// The model is a shared singleton; reset all observable state before each test.
    override func setUp() async throws {
        let m = model
        // Remove any lingering active tasks via the multi-task API.
        for task in m.activeTasks {
            m.finishTask(task.id)
        }
        // Clear timers/messages.
        m.setGlobal(nil)
        m.finishGlobal(nil)
        // finish() with no message clears the current single-task id without setting a done message.
        m.finish(nil)
    }

    override func tearDown() async throws {
        let m = model
        for task in m.activeTasks {
            m.finishTask(task.id)
        }
        m.setGlobal(nil)
        m.finishGlobal(nil)
    }

    // MARK: - ActiveTask value type

    func testActiveTaskDeterminate() {
        let determinate = StatusBarModel.ActiveTask(label: "Importing", total: 10)
        XCTAssertTrue(determinate.isDeterminate)
        XCTAssertEqual(determinate.done, 0)
        XCTAssertEqual(determinate.total, 10)
        XCTAssertEqual(determinate.label, "Importing")

        let indeterminate = StatusBarModel.ActiveTask(label: "Scanning")
        XCTAssertFalse(indeterminate.isDeterminate)
        XCTAssertEqual(indeterminate.total, 0)
        XCTAssertEqual(indeterminate.done, 0)
    }

    func testActiveTaskUniqueIDs() {
        let a = StatusBarModel.ActiveTask(label: "A")
        let b = StatusBarModel.ActiveTask(label: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Initial / reset state

    func testInitialStateInactive() {
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.activeTasks.isEmpty)
        XCTAssertNil(model.globalLabel)
    }

    // MARK: - Single-task backward-compatible API

    func testBeginIndeterminate() {
        model.begin("Loading")
        XCTAssertTrue(model.isActive)
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.activeTasks.count, 1)
        XCTAssertEqual(model.activeTasks.first?.label, "Loading")
        XCTAssertFalse(model.activeTasks.first?.isDeterminate ?? true)
    }

    func testBeginDeterminate() {
        model.begin("Copying", total: 50)
        XCTAssertEqual(model.activeTasks.count, 1)
        XCTAssertEqual(model.activeTasks.first?.total, 50)
        XCTAssertTrue(model.activeTasks.first?.isDeterminate ?? false)
        XCTAssertEqual(model.activeTasks.first?.done, 0)
    }

    func testUpdateAdvancesProgressAndLabel() {
        model.begin("Copying", total: 100)
        model.update(done: 25)
        XCTAssertEqual(model.activeTasks.first?.done, 25)
        XCTAssertEqual(model.activeTasks.first?.label, "Copying")

        model.update(done: 60, label: "Copying files")
        XCTAssertEqual(model.activeTasks.first?.done, 60)
        XCTAssertEqual(model.activeTasks.first?.label, "Copying files")
    }

    func testUpdateWithoutCurrentTaskIsNoOp() {
        // No begin() called → currentTaskId is nil; update must not crash or create tasks.
        model.update(done: 5)
        XCTAssertTrue(model.activeTasks.isEmpty)
    }

    func testFinishRemovesTaskAndShowsDoneMessage() {
        model.begin("Working")
        XCTAssertTrue(model.isActive)
        model.finish("Done!")
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.activeTasks.isEmpty)
        XCTAssertEqual(model.doneMessage, "Done!")
        // doneMessage keeps the bar visible even with no active tasks.
        XCTAssertTrue(model.isVisible)
    }

    func testFinishWithoutMessageClearsState() {
        model.begin("Working")
        model.finish(nil)
        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.doneMessage)
        XCTAssertFalse(model.isVisible)
    }

    func testBeginClearsPreviousDoneMessage() {
        model.begin("First")
        model.finish("Completed")
        XCTAssertEqual(model.doneMessage, "Completed")
        // Starting a new task clears the stale done message.
        model.begin("Second")
        XCTAssertNil(model.doneMessage)
        XCTAssertEqual(model.activeTasks.count, 1)
        XCTAssertEqual(model.activeTasks.first?.label, "Second")
    }

    // MARK: - Multi-task API

    func testBeginTaskReturnsDistinctIDs() {
        let id1 = model.beginTask("Import A", total: 10)
        let id2 = model.beginTask("Import B")
        XCTAssertNotEqual(id1, id2)
        XCTAssertEqual(model.activeTasks.count, 2)
        XCTAssertTrue(model.isActive)
    }

    func testUpdateTaskByID() {
        let id = model.beginTask("Import", total: 0)
        // Update done, total, and label together.
        model.updateTask(id, done: 3, total: 20, label: "Importing media")
        let task = model.activeTasks.first { $0.id == id }
        XCTAssertEqual(task?.done, 3)
        XCTAssertEqual(task?.total, 20)
        XCTAssertEqual(task?.label, "Importing media")
        XCTAssertTrue(task?.isDeterminate ?? false)
    }

    func testUpdateTaskPartial() {
        let id = model.beginTask("Import", total: 100)
        model.updateTask(id, done: 40)
        let task = model.activeTasks.first { $0.id == id }
        XCTAssertEqual(task?.done, 40)
        // total and label unchanged.
        XCTAssertEqual(task?.total, 100)
        XCTAssertEqual(task?.label, "Import")
    }

    func testUpdateTaskUnknownIDIsNoOp() {
        let id = model.beginTask("Import")
        model.updateTask(UUID(), done: 99)
        let task = model.activeTasks.first { $0.id == id }
        XCTAssertEqual(task?.done, 0, "Unknown id must not mutate other tasks")
    }

    func testFinishTaskRemovesOnlyThatTask() {
        let id1 = model.beginTask("A")
        let id2 = model.beginTask("B")
        model.finishTask(id1)
        XCTAssertEqual(model.activeTasks.count, 1)
        XCTAssertEqual(model.activeTasks.first?.id, id2)
        XCTAssertTrue(model.isActive)
    }

    func testFinishTaskWithMessage() {
        let id = model.beginTask("A")
        model.finishTask(id, message: "All set")
        XCTAssertTrue(model.activeTasks.isEmpty)
        XCTAssertEqual(model.doneMessage, "All set")
        XCTAssertTrue(model.isVisible)
    }

    func testBeginTaskClearsDoneMessage() {
        let id = model.beginTask("A")
        model.finishTask(id, message: "Finished")
        XCTAssertEqual(model.doneMessage, "Finished")
        _ = model.beginTask("B")
        XCTAssertNil(model.doneMessage)
    }

    // MARK: - Global background label

    func testSetGlobalLabel() {
        XCTAssertNil(model.globalLabel)
        model.setGlobal("Background sync")
        XCTAssertEqual(model.globalLabel, "Background sync")
        XCTAssertTrue(model.isVisible)
        XCTAssertFalse(model.isActive, "Global label alone does not make the model active")
    }

    func testSetGlobalNilClears() {
        model.setGlobal("Working")
        model.setGlobal(nil)
        XCTAssertNil(model.globalLabel)
        XCTAssertFalse(model.isVisible)
    }

    func testFinishGlobalWithMessageSetsLabel() {
        model.setGlobal("Syncing")
        model.finishGlobal("Sync complete")
        XCTAssertEqual(model.globalLabel, "Sync complete")
        XCTAssertTrue(model.isVisible)
    }

    func testFinishGlobalNilClearsImmediately() {
        model.setGlobal("Syncing")
        model.finishGlobal(nil)
        XCTAssertNil(model.globalLabel)
    }

    // MARK: - Visibility combinations

    func testIsVisibleReflectsAllSources() {
        XCTAssertFalse(model.isVisible)

        model.begin("Task")
        XCTAssertTrue(model.isVisible)
        model.finish(nil)
        XCTAssertFalse(model.isVisible)

        model.setGlobal("Global")
        XCTAssertTrue(model.isVisible)
        model.setGlobal(nil)
        XCTAssertFalse(model.isVisible)
    }
}
