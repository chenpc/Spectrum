import Foundation

/// Parsed command-line launch arguments for automated testing / headless debugging.
///
/// Usage:
///   ./Spectrum.app/Contents/MacOS/Spectrum \
///       --spectrum-library /tmp/test-lib \
///       --add-folder /Volumes/home/Photos/2014
///
/// When `spectrumLibrary` is set, the library at that path is wiped clean on launch
/// so each test run starts from a fresh state.
final class AppLaunchArgs: Sendable {
    static let shared = AppLaunchArgs()

    /// Override path for the Spectrum Library (database + thumbnails).
    /// Set this before `SpectrumLibrary.url` is first accessed.
    let spectrumLibrary: URL?

    /// Folder to add automatically after the app finishes initialising.
    let addFolder: URL?

    /// When true, `Log.info/debug` also writes to stdout for easy shell capture.
    let logToStdout: Bool

    private init() {
        let args = CommandLine.arguments
        var library: URL? = nil
        var folder: URL? = nil
        var stdout = false

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--spectrum-library":
                i += 1
                if i < args.count {
                    library = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath,
                                  isDirectory: true)
                }
            case "--add-folder":
                i += 1
                if i < args.count {
                    folder = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath,
                                 isDirectory: true)
                }
            case "--log-stdout":
                stdout = true
            default:
                break
            }
            i += 1
        }

        self.spectrumLibrary = library
        self.addFolder = folder
        self.logToStdout = stdout
    }
}
