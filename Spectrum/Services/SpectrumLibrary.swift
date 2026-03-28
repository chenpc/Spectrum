import Foundation
import AppKit

/// Spectrum Library 的磁碟佈局（~/Pictures/Spectrum Library/）
/// 以及從舊位置的一次性 migration。
enum SpectrumLibrary {

    /// 可在 `url` 第一次被存取之前設定，將 library 重導向到指定目錄。
    /// 由 `AppLaunchArgs` 在 `SpectrumApp.init()` 最開頭設定。
    nonisolated(unsafe) static var overrideURL: URL? = nil

    /// 根目錄：~/Pictures/Spectrum Library/（或 --spectrum-library 指定的路徑）
    static let url: URL = {
        let base: URL
        if let override = overrideURL {
            base = override
        } else {
            let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            base = pics.appendingPathComponent("Spectrum Library", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// SwiftData store：~/Pictures/Spectrum Library/default.store
    static var databaseURL: URL { url.appendingPathComponent("default.store") }

    /// 縮圖快取根目錄：~/Pictures/Spectrum Library/Thumbnails/
    static var thumbnailsURL: URL { url.appendingPathComponent("Thumbnails", isDirectory: true) }

    /// Lock file 的路徑：~/Pictures/Spectrum Library/default.store.lock
    static var lockFileURL: URL { url.appendingPathComponent("default.store.lock") }

    /// 保持 lock file 開啟的 fd，確保 process 存活期間 lock 不被釋放。
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    /// 嘗試取得 library 的 exclusive file lock。
    /// 若另一個 app instance 已持有 lock，顯示 alert 並終止。
    /// 必須在 `migrateFromLegacyLocationIfNeeded()` 之後、`ModelContainer` 建立之前呼叫。
    static func acquireOrTerminate() {
        let path = lockFileURL.path
        // 建立或開啟 lock file（不截斷內容）
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            Log.general.warning("[lock] Cannot open lock file: \(path)")
            return
        }
        // 嘗試非阻塞式 exclusive lock
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            // 另一個 instance 正在執行，顯示 alert 後終止
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Spectrum is already running"
            alert.informativeText = "Another instance of Spectrum is using this library. Please close it before opening a new window."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        lockFD = fd
        // 寫入目前 pid 方便除錯
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
    }

    /// 在開啟 ModelContainer 前呼叫一次。
    /// 若新位置的 store 尚不存在，把舊位置（~/Library/Application Support/com.spectrum.Spectrum/）
    /// 的 SQLite 三件組複製過來，讓現有資料夾書籤得以保留。
    static func migrateFromLegacyLocationIfNeeded() {
        guard !FileManager.default.fileExists(atPath: databaseURL.path) else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyDir = appSupport.appendingPathComponent("com.spectrum.Spectrum", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyDir.path) else { return }

        // 複製 SQLite WAL 三件組（main、-shm、-wal）
        for file in ["default.store", "default.store-shm", "default.store-wal"] {
            let src = legacyDir.appendingPathComponent(file)
            let dst = url.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }
}
