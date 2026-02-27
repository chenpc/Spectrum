import Foundation
import CoreServices

/// Monitors scanned folders via FSEvents and posts notifications when contents change.
final class FolderMonitor: @unchecked Sendable {
    static let shared = FolderMonitor()

    /// Posted when a monitored folder's contents change.
    /// `userInfo["path"]` contains the root folder path that was being monitored.
    static let folderDidChange = Notification.Name("FolderMonitorDidChange")

    private var streams: [String: FSEventStreamRef] = [:]
    private var retainedPaths: [String: Unmanaged<NSString>] = [:]
    private let lock = NSLock()

    private init() {}

    func startMonitoring(path: String) {
        lock.lock()
        defer { lock.unlock() }

        // If already monitoring this path, tear down the old stream first.
        teardownStream(for: path)

        let pathCFArray = [path] as CFArray
        let unmanaged = Unmanaged.passRetained(path as NSString)

        var context = FSEventStreamContext(
            version: 0,
            info: unmanaged.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventCallback,
            &context,
            pathCFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else {
            unmanaged.release()
            return
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        streams[path] = stream
        retainedPaths[path] = unmanaged
    }

    func stopMonitoring(path: String) {
        lock.lock()
        defer { lock.unlock() }
        teardownStream(for: path)
    }

    func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for path in Array(streams.keys) {
            teardownStream(for: path)
        }
    }

    /// Must be called while holding `lock`.
    private func teardownStream(for path: String) {
        if let stream = streams.removeValue(forKey: path) {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        retainedPaths.removeValue(forKey: path)?.release()
    }
}

private func fsEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo else { return }
    let monitoredPath = Unmanaged<NSString>.fromOpaque(clientInfo).takeUnretainedValue() as String
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: FolderMonitor.folderDidChange,
            object: nil,
            userInfo: ["path": monitoredPath]
        )
    }
}
