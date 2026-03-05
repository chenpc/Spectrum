import XCTest
import AVFoundation
@testable import Spectrum

final class VideoHDRDetectionTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            XCTFail("Missing fixture: \(name)")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    // MARK: - Video HDR Detection

    func testDetectVideoHDR_hlg() async {
        let url = fixtureURL("hlg_video.mp4")
        let result = await ImagePreloadCache.detectVideoHDRType(
            path: url.path, bookmarkData: nil
        )
        XCTAssertEqual(result, .hlg, "HLG HEVC video should be detected as .hlg")
    }

    func testDetectVideoHDR_sdr() async {
        let url = fixtureURL("sdr_video.mp4")
        let result = await ImagePreloadCache.detectVideoHDRType(
            path: url.path, bookmarkData: nil
        )
        XCTAssertNil(result, "SDR video should return nil")
    }

    // MARK: - VideoHDRType Properties

    func testVideoHDRTypeProperties() {
        XCTAssertEqual(VideoHDRType.dolbyVision.rawValue, "Dolby Vision")
        XCTAssertEqual(VideoHDRType.hlg.rawValue, "HLG")
        XCTAssertEqual(VideoHDRType.hdr10.rawValue, "HDR10")
        XCTAssertEqual(VideoHDRType.slog2.rawValue, "S-Log2")
        XCTAssertEqual(VideoHDRType.slog3.rawValue, "S-Log3")
    }

    func testVideoHDRTypeCaseIterable() {
        XCTAssertEqual(VideoHDRType.allCases.count, 5)
    }
}
