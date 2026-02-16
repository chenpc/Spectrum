import SwiftUI
import SwiftData

struct TimelineSection: Identifiable {
    let id: String  // yyyy-MM
    let label: String  // "January 2024"
    let photos: [Photo]
}

@Observable
final class LibraryViewModel {
    private(set) var flatPhotos: [Photo] = []

    func timelineSections(from photos: [Photo]) -> [TimelineSection] {
        let grouped = Dictionary(grouping: photos) { photo in
            photo.dateTaken.monthYearKey
        }

        let sections = grouped.map { key, photos in
            let label = photos.first?.dateTaken.timelineLabel ?? key
            return TimelineSection(
                id: key,
                label: label,
                photos: photos.sorted { $0.dateTaken > $1.dateTaken }
            )
        }
        .sorted { $0.id > $1.id }

        flatPhotos = sections.flatMap(\.photos)
        return sections
    }

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
