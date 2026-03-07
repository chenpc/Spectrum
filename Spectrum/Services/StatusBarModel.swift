import Foundation

@Observable @MainActor
final class StatusBarModel {
    static let shared = StatusBarModel()

    private(set) var isActive = false
    private(set) var label = ""
    private(set) var progressTotal = 0
    private(set) var progressDone = 0
    /// true = determinate (has total), false = indeterminate (spinner)
    private(set) var isDeterminate = false
    /// Shows "done" message after task completes, until next task starts
    private(set) var doneMessage: String?

    /// Global background task (e.g. folder tree prefetch) — independent of per-grid scan.
    private(set) var globalLabel: String?

    private init() {}

    /// Start an indeterminate task (e.g. scanning)
    func begin(_ label: String) {
        doneMessage = nil
        self.label = label
        progressTotal = 0
        progressDone = 0
        isDeterminate = false
        isActive = true
    }

    /// Start a determinate task with known total
    func begin(_ label: String, total: Int) {
        doneMessage = nil
        self.label = label
        progressTotal = total
        progressDone = 0
        isDeterminate = total > 0
        isActive = true
    }

    /// Update progress during a determinate task
    func update(done: Int, label: String? = nil) {
        progressDone = done
        if let label { self.label = label }
    }

    /// Mark current task as done
    func finish(_ message: String? = nil) {
        isActive = false
        label = ""
        progressTotal = 0
        progressDone = 0
        doneMessage = message ?? doneMessage
    }

    func setGlobal(_ label: String?) { globalLabel = label }

    var isVisible: Bool { isActive || doneMessage != nil || globalLabel != nil }
}
