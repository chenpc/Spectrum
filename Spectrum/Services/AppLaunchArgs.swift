import Foundation

/// Parsed command-line launch arguments for automated testing / headless debugging.
///
/// Usage:
///   ./Spectrum.app/Contents/MacOS/Spectrum \
///       --userdir /tmp/spectrum-test-XXXX \
///       --add-folder /Volumes/home/Photos/2014
///
/// `--userdir` 指向一個由 `mktemp -d` 建立的乾淨目錄，
/// app 把所有 library、thumbnails、UserDefaults 都放到這裡，
/// 確保每次測試都是完全隔離的新環境。
final class AppLaunchArgs: Sendable {
    static let shared = AppLaunchArgs()

    /// 測試隔離目錄：由外部（測試或 shell）用 mktemp 建立，app 直接使用不清除。
    /// 設定後 SpectrumLibrary 和 UserDefaults 都會重導向到此目錄下。
    let userDir: URL?

    /// Folder to add automatically after the app finishes initialising.
    let addFolder: URL?

    /// When true, `Log.info/debug` also writes to stdout for easy shell capture.
    let logToStdout: Bool

    private init() {
        let args = CommandLine.arguments
        var userDir: URL? = nil
        var folder: URL? = nil
        var stdout = false

        var i = 1
        while i < args.count {
            let arg = args[i]
            // 支援 --userdir PATH 和 --userdir=PATH 兩種格式
            if arg.hasPrefix("--userdir=") {
                let path = String(arg.dropFirst("--userdir=".count))
                userDir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                              isDirectory: true)
            } else if arg == "--userdir" {
                i += 1
                if i < args.count {
                    userDir = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath,
                                  isDirectory: true)
                }
            } else if arg == "--add-folder" {
                i += 1
                if i < args.count {
                    folder = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath,
                                 isDirectory: true)
                }
            } else if arg == "--log-stdout" {
                stdout = true
            }
            i += 1
        }

        self.userDir = userDir
        self.addFolder = folder
        self.logToStdout = stdout
    }
}
