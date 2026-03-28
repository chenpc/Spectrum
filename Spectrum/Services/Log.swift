import Foundation
import os
import MachO

// MARK: - App Log Level

enum AppLogLevel: Int, CaseIterable, Identifiable {
    case debug = 0
    case info  = 1
    case error = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .debug: return "Debug (verbose)"
        case .info:  return "Info"
        case .error: return "Error only (silent)"
        }
    }
}

// MARK: - Log

enum Log {
    static let general   = Logger(subsystem: "com.spectrum.app", category: "general")
    static let scanner   = Logger(subsystem: "com.spectrum.app", category: "scanner")
    static let thumbnail = Logger(subsystem: "com.spectrum.app", category: "thumbnail")
    static let bookmark  = Logger(subsystem: "com.spectrum.app", category: "bookmark")
    static let video     = Logger(subsystem: "com.spectrum.app", category: "video")
    static let gyro      = Logger(subsystem: "com.spectrum.app", category: "gyro")
    static let player    = Logger(subsystem: "com.spectrum.app", category: "player")
    static let network   = Logger(subsystem: "com.spectrum.app", category: "network")

    // Build-time default: Debug build → debug, Release build → error (silent)
    static let buildDefaultLevel: AppLogLevel = {
        #if DEBUG
        return .debug
        #else
        return .error
        #endif
    }()

    /// Current minimum log level. Read from UserDefaults each call (cheap int lookup).
    static var level: AppLogLevel {
        let raw = UserDefaults.standard.object(forKey: "appLogLevel") as? Int
                  ?? buildDefaultLevel.rawValue
        return AppLogLevel(rawValue: raw) ?? buildDefaultLevel
    }

    /// Log at debug level — message closure is not evaluated when level > debug.
    static func debug(_ logger: Logger, _ message: @autoclosure () -> String) {
        guard level.rawValue <= AppLogLevel.debug.rawValue else { return }
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        if AppLaunchArgs.shared.logToStdout { print("[D] \(msg)") }
    }

    /// Log at info level — message closure is not evaluated when level > info.
    static func info(_ logger: Logger, _ message: @autoclosure () -> String) {
        guard level.rawValue <= AppLogLevel.info.rawValue else { return }
        let msg = message()
        logger.info("\(msg, privacy: .public)")
        if AppLaunchArgs.shared.logToStdout { print("[I] \(msg)") }
    }

    /// Returns the process's physical memory footprint in megabytes.
    static func memMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kern == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}
