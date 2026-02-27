import os

enum Log {
    static let general   = Logger(subsystem: "com.spectrum.app", category: "general")
    static let scanner   = Logger(subsystem: "com.spectrum.app", category: "scanner")
    static let thumbnail = Logger(subsystem: "com.spectrum.app", category: "thumbnail")
    static let bookmark  = Logger(subsystem: "com.spectrum.app", category: "bookmark")
    static let video     = Logger(subsystem: "com.spectrum.app", category: "video")
}
