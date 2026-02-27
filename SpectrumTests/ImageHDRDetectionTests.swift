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

    // MARK: - HLG Detection

    func testDetectHDR_correctlyTaggedHLG() {
        // DSC00227.HIF — PP=45, BT.2020/HLG correctly tagged in NCLX
        let source = makeSource("hlg_correctly_tagged.HIF")
        let result = ImagePreloadCache.detectHDR(source: source)
        XCTAssertEqual(result, .hlg, "Correctly-tagged HLG HEIF should be detected as .hlg")
    }

    func testDetectHDR_mislabeledHLG() {
        // HLG.HIF — HLG content but mislabeled as sRGB in NCLX
        let source = makeSource("hlg_mislabeled.HIF")
        let result = ImagePreloadCache.detectHDR(source: source)
        // CGColorSpaceUsesITUR_2100TF returns false for sRGB-tagged → nil
        XCTAssertNil(result, "Mislabeled HLG (sRGB NCLX) should not be detected as HDR")
    }

    func testDetectHDR_slog3() {
        // SLOG3.HIF — S-Log3 content, also mislabeled as sRGB
        let source = makeSource("slog3_mislabeled.HIF")
        let result = ImagePreloadCache.detectHDR(source: source)
        XCTAssertNil(result, "S-Log3 mislabeled HEIF should not be detected as HDR")
    }

    func testDetectHDR_sdrJPEG() {
        let source = makeSource("sdr_photo.jpg")
        let result = ImagePreloadCache.detectHDR(source: source)
        XCTAssertNil(result, "SDR JPEG should return nil")
    }

    // MARK: - Badge Labels

    func testHDRFormatBadgeLabels() {
        XCTAssertEqual(HDRFormat.gainMap.badgeLabel, "HDR")
        XCTAssertEqual(HDRFormat.hlg.badgeLabel, "HLG")
    }
}
