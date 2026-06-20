import XCTest

final class BenchmarkUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testTimeToFirstPhoto() throws {
        let testDir = try prepareTestData()

        let tmpLib = NSTemporaryDirectory() + "spectrum-bench-\(UUID().uuidString)"
        app.launchArguments = ["--spectrum-library", tmpLib, "--add-folder", testDir.path]
        app.launch()

        // Wait for the grid to appear (folder is auto-selected via --add-folder)
        let grid = app.scrollViews["grid.photos"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))

        // Measure time from now (app is already launched, grid is visible)
        // Wait for first photo image inside the grid
        let measureStart = Date()
        let firstPhoto = grid.images.firstMatch
        let found = firstPhoto.waitForExistence(timeout: 30)
        let elapsed = Date().timeIntervalSince(measureStart)

        if found {
            print("[BENCHMARK] Time to first photo: \(String(format: "%.3f", elapsed))s")

            // Wait a bit more for additional photos to appear
            let settleStart = Date()
            var lastCount = 0
            while Date().timeIntervalSince(settleStart) < 15 {
                Thread.sleep(forTimeInterval: 0.5)
                let count = grid.images.count
                if count > 0 && count == lastCount {
                    break
                }
                lastCount = count
            }
            let totalTime = Date().timeIntervalSince(measureStart)
            print("[BENCHMARK] Total settled: \(String(format: "%.3f", totalTime))s — \(lastCount) images")
        } else {
            XCTFail("No photo appeared within 30s")
        }
    }
}

// MARK: - Test Data

extension BenchmarkUITests {
    private var fixturesDir: URL {
        // SpectrumUITests/BenchmarkUITests.swift → SpectrumUITests/ → Spectrum/ → SpectrumTests/Fixtures/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SpectrumTests/Fixtures")
    }

    private func prepareTestData() throws -> URL {
        if let envDir = ProcessInfo.processInfo.environment["TEST_BENCHMARK_DIR"] {
            let url = URL(fileURLWithPath: envDir)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("TEST_BENCHMARK_DIR does not exist: \(url.path)")
            }
            return url
        }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spectrum-bench-data-\(UUID().uuidString)")

        let contents = try FileManager.default.contentsOfDirectory(
            at: fixturesDir, includingPropertiesForKeys: nil
        )
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for url in contents {
            try FileManager.default.copyItem(at: url, to: tmpDir.appendingPathComponent(url.lastPathComponent))
        }

        return tmpDir
    }
}
