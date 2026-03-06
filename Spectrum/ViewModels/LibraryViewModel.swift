import SwiftUI
import SwiftData

@Observable
final class LibraryViewModel {
    var flatPhotos: [Photo] = []

    func navigatePhoto(from current: Photo?, direction: Int) -> Photo? {
        guard !flatPhotos.isEmpty else { return nil }
        guard let current,
              let index = flatPhotos.firstIndex(where: { $0.persistentModelID == current.persistentModelID })
        else {
            return flatPhotos.first
        }
        let newIndex = index + direction
        guard flatPhotos.indices.contains(newIndex) else { return current }
        return flatPhotos[newIndex]
    }
}
