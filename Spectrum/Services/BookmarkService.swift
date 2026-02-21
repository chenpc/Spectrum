import Foundation

enum BookmarkService {
    static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            // Bookmark needs refreshing — but don't fail if we can't create a new one yet.
            // The resolved URL is still valid for this session.
            _ = try? createBookmark(for: url)
        }
        return url
    }

    /// Returns the network remount URL (e.g. smb://server/share) for a URL on a network volume, or nil.
    static func remountURL(for url: URL) -> URL? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting
    }

    @discardableResult
    static func withSecurityScope<T>(_ url: URL, body: () throws -> T) rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try body()
    }

    @discardableResult
    static func withSecurityScope<T>(_ url: URL, body: () async throws -> T) async rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try await body()
    }
}
