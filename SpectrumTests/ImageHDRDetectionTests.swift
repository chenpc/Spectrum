import XCTest
import ImageIO
@testable import Spectrum

final class ImageHDRDetectionTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            XCTFail("Missing fixture: \(name)")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    private func makeSource(_ name: String) -> CGImageSource {
        let url = fixtureURL(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            XCTFail("Cannot create CGImageSource for \(name)")
            return CGImageSourceCreateWithData(Data() as CFData, nil)!
        }
        return source
    }

    /// 「應為 nil」的斷言在檔案無法解碼時也會通過——先確認 fixture 本身有效。
    private func assertDecodable(_ source: CGImageSource, depth: Int? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil),
                        "fixture should decode", file: file, line: line)
        if let depth {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            XCTAssertEqual(props?[kCGImagePropertyDepth] as? Int, depth,
                           "fixture bit depth", file: file, line: line)
        }
    }

    // MARK: - HLG Detection

    func testDetectHDR_correctlyTaggedHLG() {
        // 合成 10-bit HEIF，標記為 BT.2100 HLG（make_hlg_synthetic_fixture.swift hlg-patches）
        let source = makeSource("hlg_synthetic_patches.heic")
        let result = ImagePreloadCache.detectHDR(source: source)
        XCTAssertEqual(result, .hlg, "Correctly-tagged HLG HEIF should be detected as .hlg")
    }

    func testDetectHDR_mislabeledHLG() {
        // 合成 10-bit HEIF：HLG 訊號值但標記為 sRGB——重現部分 Sony 相機把 HLG 寫成 sRGB NCLX
        let source = makeSource("hlg_mislabeled_srgb.heic")
        assertDecodable(source, depth: 10)
        let result = ImagePreloadCache.detectHDR(source: source)
        // 標記為 sRGB 時無法從 metadata 得知內容是 HLG → nil
        XCTAssertNil(result, "Mislabeled HLG (sRGB NCLX) should not be detected as HDR")
    }

    func testDetectHDR_slog3() {
        // 合成 10-bit HEIF：S-Log3 編碼值，同樣標記為 sRGB
        let source = makeSource("slog3_mislabeled_srgb.heic")
        assertDecodable(source, depth: 10)
        let result = ImagePreloadCache.detectHDR(source: source)
        XCTAssertNil(result, "S-Log3 mislabeled HEIF should not be detected as HDR")
    }

    func testDetectHDR_sdrJPEG() {
        let source = makeSource("sdr_photo.jpg")
        assertDecodable(source)
        let result = ImagePreloadCache.detectHDR(source: source)
        XCTAssertNil(result, "SDR JPEG should return nil")
    }

    // MARK: - Badge Labels

    func testHDRFormatBadgeLabels() {
        XCTAssertEqual(HDRFormat.gainMap.badgeLabel, "HDR")
        XCTAssertEqual(HDRFormat.hlg.badgeLabel, "HLG")
    }
}
