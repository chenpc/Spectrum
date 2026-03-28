import Foundation

@Observable
final class LibraryViewModel {
    /// 目前資料夾顯示的照片（不含子資料夾、不含 isLivePhotoMov），供 detail view 左右導覽使用。
    var flatPhotos: [PhotoItem] = []

    /// 從 `current` 往 `direction`（+1 或 -1）移動，回傳相鄰的 PhotoItem。
    func navigatePhoto(from current: PhotoItem?, direction: Int) -> PhotoItem? {
        guard let current else { return nil }
        guard let idx = flatPhotos.firstIndex(where: { $0.filePath == current.filePath }) else { return nil }
        let newIdx = idx + direction
        guard flatPhotos.indices.contains(newIdx) else { return nil }
        return flatPhotos[newIdx]
    }
}
