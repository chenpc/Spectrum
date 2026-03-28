import Foundation
import SwiftData
import os

// MARK: - ThumbnailProgress

/// 掃描／縮圖進度旗標，供 sidebar 進度條判斷是否顯示。
///
/// 生命週期（以 add folder 為例）：
///   markScanStarted()   — 重置所有計數，isScanning = true（UI 立即顯示 0/0）
///   addScanCount()      — 枚舉到檔案時累加 scanFileCount（供 UI 顯示 "N files"）
///   addTotal()          — 枚舉到檔案時累加 thumbTotal（分母即時增長，顯示 0/N）
///   markScanFinished()  — isScanning = false；設 scanDone = true 橋接到 markRunning
///   markScheduled()     — schedule() 已呼叫但 run() 尚未開始（額外橋接）
///   markRunning(total:) — scanDone = false；thumbTotal 只增不減（scan 已設的值不縮小）
///   addDone()           — 每張縮圖完成時累加 thumbDone（分子即時增長，顯示 D/N）
///   finish()            — isGenerating = false（thumbDone/Total 保留至下次 markScanStarted）
@Observable @MainActor
final class ThumbnailProgress {
    static let shared = ThumbnailProgress()
    private(set) var isScanning   = false
    private(set) var isScheduled  = false
    private(set) var isGenerating = false
    /// 掃描已結束但縮圖生成尚未開始；橋接 markScanFinished → markRunning 的空窗，防止進度條閃失。
    private(set) var scanDone = false
    private(set) var removingCount = 0
    private(set) var removingName  = ""
    /// 掃描中已找到的媒體檔案數（枚舉完成後由 FolderScanner 回報）
    private(set) var scanFileCount: Int = 0
    /// 縮圖生成進度計數（累計跨 pass，不在 pass 間重置）
    private(set) var thumbDone: Int = 0
    private(set) var thumbTotal: Int = 0
    /// 縮圖生成速率（photos/sec），每批次更新。
    private(set) var thumbRate: Double = 0
    private var rateStartTime: Date = .distantPast
    private var rateStartDone: Int = 0
    var isRemoving: Bool { removingCount > 0 }
    var isActive: Bool { isScanning || scanDone || isScheduled || isGenerating || isRemoving }
    private init() {}

    /// 開始新的 add/rescan 操作：重置所有進度計數。
    func markScanStarted() {
        isScanning = true; scanDone = false
        thumbDone = 0; thumbTotal = 0; scanFileCount = 0; thumbRate = 0
    }
    /// 掃描完成：清 isScanning，設 scanDone 橋接到縮圖生成開始前的空窗。
    func markScanFinished() { isScanning = false; scanDone = true }
    /// FolderScanner 枚舉完媒體檔案後呼叫，回報找到的數量（供 UI 顯示 "N files"）。
    func addScanCount(_ n: Int) { scanFileCount += n }
    /// FolderScanner 枚舉到媒體檔案後呼叫，讓分母即時增長（UI 顯示 0/N）。
    func addTotal(_ n: Int) { thumbTotal += n }
    fileprivate func markScheduled() { isScheduled = true }
    /// 縮圖生成開始：清除橋接旗標；thumbTotal 只增不減（scan 已回報的值不覆蓋）。
    fileprivate func markRunning(total: Int) {
        isScheduled = false; isGenerating = true; scanDone = false
        let needed = thumbDone + total
        if needed > thumbTotal { thumbTotal = needed }
        rateStartTime = Date(); rateStartDone = thumbDone; thumbRate = 0
    }
    fileprivate func addDone(_ n: Int) {
        thumbDone += n
        let elapsed = Date().timeIntervalSince(rateStartTime)
        if elapsed > 0.1 {
            thumbRate = Double(thumbDone - rateStartDone) / elapsed
        }
    }
    /// 這一輪縮圖結束；thumbDone/Total 保留（顯示最終計數），下次 markScanStarted() 才重置。
    func finish() { isGenerating = false; isScheduled = false; scanDone = false; thumbRate = 0 }

    func markRemovalStarted(name: String) {
        removingCount += 1; removingName = name
    }
    func markRemovalFinished() {
        removingCount = max(0, removingCount - 1)
        if removingCount == 0 { removingName = "" }
    }
    /// 強制全部清除（cancel / reset all data 時使用）。
    func cancelAll() {
        isScanning = false; isScheduled = false; isGenerating = false; scanDone = false
        removingCount = 0; removingName = ""
        thumbDone = 0; thumbTotal = 0; scanFileCount = 0; thumbRate = 0
    }
}

// MARK: - Timing helper (file-private)

private func fmtDur(_ d: Duration) -> String {
    let ms = Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1_000_000_000_000_000
    return ms < 1_000 ? String(format: "%.1fms", ms) : String(format: "%.2fs", ms / 1_000)
}

// MARK: - ThumbnailScheduler

final class ThumbnailScheduler: @unchecked Sendable {
    static let shared = ThumbnailScheduler()

    private let lock = NSLock()
    private var currentTask: Task<Void, Never>?
    /// Set when schedule() is called while a task is already running.
    /// The running task will start another pass after it finishes.
    private var pendingRun = false

    private init() {}

    /// Request a thumbnail generation pass.
    /// If a pass is already running, marks it to restart after completion.
    /// - `priority`: `.userInitiated` for folder-add (eager), `.background` for app-launch pass.
    /// Safe to call from any context.
    func schedule(container: ModelContainer, priority: TaskPriority = .background) {
        lock.withLock {
            guard currentTask == nil else {
                pendingRun = true
                return
            }
            launchTask(container: container, priority: priority)
        }
        // 立即在 MainActor 設 isScheduled，橋接 schedule()→run()→markRunning() 的空窗。
        // 必須在 lock 外呼叫，避免死鎖。
        // 用 .userInitiated 確保 UI 更新不因呼叫方優先權（可能是 .background）而延遲。
        Task(priority: .userInitiated) { @MainActor in ThumbnailProgress.shared.markScheduled() }
    }

    /// Cancel any ongoing generation and clear the pending flag.
    /// Call when a folder is removed so we don't generate stale thumbnails.
    func cancel() {
        lock.withLock {
            currentTask?.cancel()
            currentTask = nil
            pendingRun = false
        }
        Task(priority: .userInitiated) { @MainActor in ThumbnailProgress.shared.cancelAll() }
    }

    // MARK: - Private

    /// Must be called while holding `lock`.
    private func launchTask(container: ModelContainer, priority: TaskPriority = .background) {
        currentTask = Task.detached(priority: priority) { [weak self] in
            await self?.run(container: container)
        }
    }

    private func run(container: ModelContainer) async {
        // Filesystem-first 架構不再使用 ThumbnailScheduler。
        await MainActor.run { ThumbnailProgress.shared.finish() }
        lock.withLock { currentTask = nil }
    }
}
