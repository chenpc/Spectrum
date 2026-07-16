import Foundation
import os

enum BookmarkService {
    static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves a security-scoped bookmark URL. Stale bookmarks are resolved but not refreshed —
    /// use `resolveBookmarkRefreshing` when the caller can persist the updated bookmark data.
    static func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            Log.bookmark.info("Stale bookmark resolved for \(url.path, privacy: .public) — caller should refresh")
        }
        return url
    }

    /// Like `resolveBookmark`, but also returns refreshed bookmark data when the stored data is stale.
    /// The caller is responsible for persisting `refreshedData` back to storage.
    static func resolveBookmarkRefreshing(_ data: Data) throws -> (url: URL, refreshedData: Data?) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        var refreshedData: Data?
        if isStale {
            if let fresh = try? createBookmark(for: url) {
                refreshedData = fresh
            } else {
                Log.bookmark.warning("Failed to refresh stale bookmark for \(url.path, privacy: .public)")
            }
        }
        return (url, refreshedData)
    }

    /// Returns the network remount URL (e.g. smb://server/share) for a URL on a network volume, or nil.
    static func remountURL(for url: URL) -> URL? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        do {
            return try url.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting
        } catch {
            Log.bookmark.warning("Failed to get remount URL: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 盡力而為的 security scope：bookmark 解析成功就在 scope 內執行 body，
    /// 解析失敗或無 bookmark 時直接執行——app 未沙盒化，直接路徑存取即可。
    /// 書籤過期不該讓檔案操作（刪除／改名／匯入）整個卡死。
    @discardableResult
    static func withScopeIfAvailable<T>(_ data: Data?, body: () throws -> T) rethrows -> T {
        if let data, let url = try? resolveBookmark(data) {
            return try withSecurityScope(url, body: body)
        }
        return try body()
    }

    @discardableResult
    static func withScopeIfAvailable<T>(_ data: Data?, body: () async throws -> T) async rethrows -> T {
        if let data, let url = try? resolveBookmark(data) {
            return try await withSecurityScope(url, body: body)
        }
        return try await body()
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
