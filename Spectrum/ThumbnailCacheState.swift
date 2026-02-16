import SwiftUI

@MainActor
@Observable
final class ThumbnailCacheState: Sendable {
    static let shared = ThumbnailCacheState()
    private(set) var generation: Int = 0

    func invalidate() {
        generation += 1
    }
}

private struct ThumbnailCacheStateKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = ThumbnailCacheState.shared
}

extension EnvironmentValues {
    var thumbnailCacheState: ThumbnailCacheState {
        get { self[ThumbnailCacheStateKey.self] }
        set { self[ThumbnailCacheStateKey.self] = newValue }
    }
}
