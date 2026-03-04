import Darwin
import Foundation

/// Loads mdk.framework at runtime via dlopen.
///
/// Search order:
///   1. App bundle Resources/lib/mdk.framework  — distribution
///   2. Gyroflow.app Frameworks/mdk.framework   — development fallback
///   3. Homebrew /opt/homebrew / /usr/local      — development fallback
///
/// MDK C API symbols are resolved via the bridging header + `-undefined dynamic_lookup`
/// linker flag. No dlsym needed — just call C functions directly after dlopen succeeds.
class LibMDK: @unchecked Sendable {
    static let shared = LibMDK()

    private(set) var ok = false
    private(set) var loadedPath: String?
    private var handle: UnsafeMutableRawPointer?

    private init() {
        var searchPaths: [String] = []
        if let resPath = Bundle.main.resourcePath {
            searchPaths.append("\(resPath)/lib/mdk.framework/mdk")
        }
        searchPaths += [
            "/Applications/Gyroflow.app/Contents/Frameworks/mdk.framework/Versions/A/mdk",
            "/opt/homebrew/lib/mdk.framework/mdk",
            "/usr/local/lib/mdk.framework/mdk",
        ]
        for path in searchPaths {
            handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL)
            if handle != nil { loadedPath = path; break }
        }
        guard handle != nil else { return }
        ok = true
    }
}
