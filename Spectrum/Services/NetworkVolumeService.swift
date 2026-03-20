import AppKit
import Foundation
import os

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
    /// Uses NetFSMountURLSync (silent mount) so Finder does NOT open a new window.
    /// Returns true once the volume is accessible, false on timeout.
    @MainActor
    static func ensureMounted(folder: ScannedFolder) async -> Bool {
        guard let volumeRoot = volumeRoot(for: folder.path) else { return true }
        guard !FileManager.default.fileExists(atPath: volumeRoot) else {
            Log.debug(Log.network, "[network] volume already mounted: \(volumeRoot)")
            return true
        }

        // Trigger mount silently via NetFS (avoids Finder window popup).
        if let remountString = folder.remountURL,
           let remountURL = URL(string: remountString) {
            Log.debug(Log.network, "[network] triggering silent mount: \(remountString)")
            Task.detached {
                mountSilently(url: remountURL)
            }
        } else {
            // No stored remount URL — fall back to NSWorkspace (may open Finder).
            Log.debug(Log.network, "[network] no remountURL stored — falling back to NSWorkspace for \(volumeRoot)")
            NSWorkspace.shared.open(URL(fileURLWithPath: volumeRoot, isDirectory: true))
        }

        // Poll up to 15 s (30 × 0.5 s)
        for i in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if FileManager.default.fileExists(atPath: volumeRoot) {
                Log.network.info("[network] volume mounted successfully after \(String(format:"%.1f", Double(i+1)*0.5))s: \(volumeRoot, privacy: .public)")
                return true
            }
        }
        Log.network.error("[network] mount timed out after 15s: \(volumeRoot, privacy: .public)")
        return false
    }

    /// Mounts a network URL (e.g. smb://server/share) silently via NetFSMountURLSync
    /// loaded dynamically from NetFS.framework so no explicit framework link is needed.
    private static func mountSilently(url: URL) {
        typealias NetFSMountURLSyncFn = @convention(c) (
            CFURL,                             // url
            CFURL?,                            // mountDir (nil = /Volumes)
            CFString?,                         // user
            CFString?,                         // password
            CFMutableDictionary?,              // open_options
            CFMutableDictionary?,              // mount_options
            UnsafeMutablePointer<CFArray?>?    // mountpoints (out)
        ) -> Int32

        let netfsPath = "/System/Library/Frameworks/NetFS.framework/NetFS"
        guard let handle = dlopen(netfsPath, RTLD_LAZY | RTLD_LOCAL),
              let sym = dlsym(handle, "NetFSMountURLSync") else {
            // NetFS unavailable — should not happen on any supported macOS version.
            Log.network.error("[network] dlopen NetFS.framework failed — cannot mount silently")
            return
        }
        let mountFn = unsafeBitCast(sym, to: NetFSMountURLSyncFn.self)
        let rc = mountFn(url as CFURL, nil, nil, nil, nil, nil, nil)
        Log.debug(Log.network, "[network] NetFSMountURLSync(\(url.absoluteString)) → rc=\(rc)")
    }
}
