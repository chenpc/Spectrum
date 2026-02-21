import AppKit
import Foundation

enum NetworkVolumeService {

    /// If `path` is under /Volumes/, returns the volume root path (e.g. "/Volumes/MyNAS").
    /// Returns nil for local paths.
    static func volumeRoot(for path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return "/Volumes/\(components[2])"
    }

    /// Returns true if the volume hosting `path` is currently mounted (or the path is local).
    static func isVolumeMounted(path: String) -> Bool {
        guard let root = volumeRoot(for: path) else { return true }
        return FileManager.default.fileExists(atPath: root)
    }

    /// Triggers mount of the network volume for `folder` and waits up to ~15 s for it to appear.
    /// - If `folder.remountURL` is set, opens that URL (e.g. smb://server/share).
    /// - Falls back to opening the /Volumes/<name> path, which may prompt macOS to reconnect.
    /// Returns true once the volume is accessible, false on timeout.
    @MainActor
    static func ensureMounted(folder: ScannedFolder) async -> Bool {
        guard let volumeRoot = volumeRoot(for: folder.path) else { return true }
        guard !FileManager.default.fileExists(atPath: volumeRoot) else { return true }

        // Trigger mount
        if let remountString = folder.remountURL,
           let remountURL = URL(string: remountString) {
            NSWorkspace.shared.open(remountURL)
        } else {
            // Fallback: opening the /Volumes/<name> path can trigger macOS reconnect prompt
            NSWorkspace.shared.open(URL(fileURLWithPath: volumeRoot, isDirectory: true))
        }

        // Poll up to 15 s (30 × 0.5 s)
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if FileManager.default.fileExists(atPath: volumeRoot) { return true }
        }
        return false
    }
}
