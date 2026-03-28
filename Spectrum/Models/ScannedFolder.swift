import SwiftData
import Foundation

@Model
final class ScannedFolder {
    var path: String
    var bookmarkData: Data?
    /// Network volume remount URL (e.g. "smb://server/share") captured when the folder was added.
    /// Used to trigger auto-mount when the volume is offline.
    var remountURL: String?
    var dateAdded: Date
    var sortOrder: Int = 0
    /// 已觸發刪除但尚未完成（Photo + 縮圖刪除中）。App 重啟後會繼續完成刪除。
    var isPendingDeletion: Bool = false
    /// 縮圖生成尚未完成（掃描後設為 true，全部生成完畢後清除）。App 重啟後自動繼續。
    var needsThumbnails: Bool = false
    // `photos` inverse array 已移除：維護 inverse array 導致每次 photo.folder = folder
    // 時 SwiftData 線性掃描全部 photos（O(n²)），對大資料夾造成嚴重記憶體問題。
    // 刪除 folder 時由 FolderScanner.removePhotos(forFolder:) 手動清除 photos（已實作）。

    init(path: String, bookmarkData: Data, remountURL: String? = nil, sortOrder: Int = 0) {
        self.path = path
        self.bookmarkData = bookmarkData
        self.remountURL = remountURL
        self.dateAdded = Date()
        self.sortOrder = sortOrder
    }
}
