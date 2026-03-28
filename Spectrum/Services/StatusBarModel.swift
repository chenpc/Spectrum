import Foundation

@Observable @MainActor
final class StatusBarModel {
    static let shared = StatusBarModel()

    struct ActiveTask: Identifiable {
        let id: UUID
        var label: String
        var done: Int
        var total: Int
        var isDeterminate: Bool { total > 0 }

        init(label: String, total: Int = 0) {
            id = UUID()
            self.label = label
            self.done = 0
            self.total = total
        }
    }

    private(set) var activeTasks: [ActiveTask] = []
    private(set) var doneMessage: String?
    private(set) var globalLabel: String?

    var isActive: Bool { !activeTasks.isEmpty }
    var isVisible: Bool { isActive || doneMessage != nil || globalLabel != nil }

    private var currentTaskId: UUID?
    private var doneTimer: Task<Void, Never>?
    private var globalTimer: Task<Void, Never>?

    private init() {}

    // MARK: - Single-task backward-compatible API (non-concurrent callers)

    func begin(_ label: String) {
        doneMessage = nil
        let task = ActiveTask(label: label)
        currentTaskId = task.id
        activeTasks.append(task)
    }

    func begin(_ label: String, total: Int) {
        doneMessage = nil
        let task = ActiveTask(label: label, total: total)
        currentTaskId = task.id
        activeTasks.append(task)
    }

    func update(done: Int, label: String? = nil) {
        guard let id = currentTaskId,
              let idx = activeTasks.firstIndex(where: { $0.id == id }) else { return }
        activeTasks[idx].done = done
        if let label { activeTasks[idx].label = label }
    }

    func finish(_ message: String? = nil) {
        if let id = currentTaskId {
            activeTasks.removeAll { $0.id == id }
            currentTaskId = nil
        }
        showDone(message)
    }

    // MARK: - Multi-task API (concurrent imports)

    /// Start a new task and return its ID. Caller must call finishTask(_:) when done.
    func beginTask(_ label: String, total: Int = 0) -> UUID {
        doneMessage = nil
        let task = ActiveTask(label: label, total: total)
        activeTasks.append(task)
        return task.id
    }

    func updateTask(_ id: UUID, done: Int, total: Int? = nil, label: String? = nil) {
        guard let idx = activeTasks.firstIndex(where: { $0.id == id }) else { return }
        activeTasks[idx].done = done
        if let total { activeTasks[idx].total = total }
        if let label { activeTasks[idx].label = label }
    }

    func finishTask(_ id: UUID, message: String? = nil) {
        activeTasks.removeAll { $0.id == id }
        showDone(message)
    }

    // MARK: - Global background label

    func setGlobal(_ label: String?) {
        globalTimer?.cancel()
        globalLabel = label
    }

    func finishGlobal(_ message: String? = nil) {
        globalTimer?.cancel()
        globalLabel = message
        if message != nil {
            globalTimer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                globalLabel = nil
            }
        }
    }

    // MARK: - Private

    private func showDone(_ message: String?) {
        guard let message else { return }
        doneMessage = message
        doneTimer?.cancel()
        doneTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            doneMessage = nil
        }
    }
}
