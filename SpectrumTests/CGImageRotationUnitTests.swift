import XCTest
import CoreGraphics
@testable import Spectrum

final class CGImageRotationUnitTests: XCTestCase {

    // MARK: - Helpers

    /// Premultiplied-last RGBA8 bitmap info used for all test images.
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    /// Build a small RGBA8 CGImage from explicit per-pixel colors.
    /// `pixels` is row-major, top-to-bottom, length == width*height, each a (r,g,b,a) tuple.
    private func makeImage(width: Int,
                           height: Int,
                           pixels: [(UInt8, UInt8, UInt8, UInt8)]) -> CGImage {
        precondition(pixels.count == width * height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<pixels.count {
            let (r, g, b, a) = pixels[i]
            data[i * 4 + 0] = r
            data[i * 4 + 1] = g
            data[i * 4 + 2] = b
            data[i * 4 + 3] = a
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &data,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: colorSpace,
                            bitmapInfo: Self.bitmapInfo)!
        return ctx.makeImage()!
    }

    /// A solid single-color 2x2 image (used where only dimensions/identity matter).
    private func makeSolid(width: Int, height: Int,
                           color: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)) -> CGImage {
        makeImage(width: width, height: height,
                  pixels: Array(repeating: color, count: width * height))
    }

    /// Read back the pixels of a CGImage as row-major top-to-bottom RGBA tuples
    /// by drawing it into a known-format context.
    private func readPixels(_ image: CGImage) -> [(UInt8, UInt8, UInt8, UInt8)] {
        let w = image.width
        let h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &data,
                            width: w,
                            height: h,
                            bitsPerComponent: 8,
                            bytesPerRow: w * 4,
                            space: colorSpace,
                            bitmapInfo: Self.bitmapInfo)!
        // For a plain CGBitmapContext the backing memory is stored top-row-first
        // (data[0] == visual top-left). Drawing an upright CGImage preserves that,
        // so we read memory in raw order to get top-to-bottom, left-to-right pixels.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [(UInt8, UInt8, UInt8, UInt8)] = []
        out.reserveCapacity(w * h)
        for row in 0..<h {
            for x in 0..<w {
                let idx = (row * w + x) * 4
                out.append((data[idx], data[idx + 1], data[idx + 2], data[idx + 3]))
            }
        }
        return out
    }

    private func assertColor(_ actual: (UInt8, UInt8, UInt8, UInt8),
                             _ expected: (UInt8, UInt8, UInt8, UInt8),
                             tolerance: UInt8 = 4,
                             _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        func close(_ a: UInt8, _ b: UInt8) -> Bool {
            return (a > b ? a - b : b - a) <= tolerance
        }
        XCTAssertTrue(close(actual.0, expected.0) && close(actual.1, expected.1) &&
                      close(actual.2, expected.2) && close(actual.3, expected.3),
                      "\(message) got=\(actual) expected=\(expected)",
                      file: file, line: line)
    }

    // Distinct corner colors for a 2x2 image:
    // index order top-to-bottom, left-to-right:
    // [TL, TR, BL, BR]
    private let red:   (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)   // TL
    private let green: (UInt8, UInt8, UInt8, UInt8) = (0, 255, 0, 255)   // TR
    private let blue:  (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 255)   // BL
    private let white: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255) // BR

    private func make2x2() -> CGImage {
        makeImage(width: 2, height: 2, pixels: [red, green, blue, white])
    }

    // MARK: - Convention sanity check

    /// Verifies makeImage (writes) and readPixels (reads) agree on orientation,
    /// so the orientation assertions below are meaningful.
    func testReadWriteRoundTrip_identity() {
        let img = make2x2()
        let p = readPixels(img)
        XCTAssertEqual(p.count, 4)
        assertColor(p[0], red,   "TL")
        assertColor(p[1], green, "TR")
        assertColor(p[2], blue,  "BL")
        assertColor(p[3], white, "BR")
    }

    // MARK: - rotateCGImage: identity / no-op branches

    func testRotate_zeroDegrees_returnsSameInstance() {
        let img = make2x2()
        let rotated = rotateCGImage(img, degrees: 0)
        XCTAssertNotNil(rotated)
        XCTAssertTrue(rotated === img, "0 degrees should return the same image instance")
    }

    func testRotate_360Degrees_returnsSameInstance() {
        let img = make2x2()
        // 360 % 360 == 0 -> no-op, same instance
        let rotated = rotateCGImage(img, degrees: 360)
        XCTAssertTrue(rotated === img, "360 degrees normalizes to 0 -> same instance")
    }

    func testRotate_negative360_returnsSameInstance() {
        let img = make2x2()
        let rotated = rotateCGImage(img, degrees: -360)
        XCTAssertTrue(rotated === img)
    }

    // MARK: - rotateCGImage: dimension swapping

    func testRotate_90_swapsDimensions() {
        let img = makeSolid(width: 4, height: 2)
        let rotated = rotateCGImage(img, degrees: 90)
        XCTAssertNotNil(rotated)
        XCTAssertEqual(rotated?.width, 2)
        XCTAssertEqual(rotated?.height, 4)
    }

    func testRotate_270_swapsDimensions() {
        let img = makeSolid(width: 4, height: 2)
        let rotated = rotateCGImage(img, degrees: 270)
        XCTAssertNotNil(rotated)
        XCTAssertEqual(rotated?.width, 2)
        XCTAssertEqual(rotated?.height, 4)
    }

    func testRotate_180_keepsDimensions() {
        let img = makeSolid(width: 4, height: 2)
        let rotated = rotateCGImage(img, degrees: 180)
        XCTAssertNotNil(rotated)
        XCTAssertEqual(rotated?.width, 4)
        XCTAssertEqual(rotated?.height, 2)
    }

    // MARK: - rotateCGImage: normalization of out-of-range / negative degrees

    func testRotate_450NormalizesTo90() {
        let img = makeSolid(width: 4, height: 2)
        let rotated = rotateCGImage(img, degrees: 450) // 450 % 360 = 90
        XCTAssertEqual(rotated?.width, 2)
        XCTAssertEqual(rotated?.height, 4)
    }

    func testRotate_negative90NormalizesTo270() {
        let img = make2x2()
        // -90 -> 270
        let viaNeg = rotateCGImage(img, degrees: -90)
        let via270 = rotateCGImage(img, degrees: 270)
        XCTAssertNotNil(viaNeg)
        XCTAssertNotNil(via270)
        XCTAssertEqual(readPixels(viaNeg!).map { "\($0)" },
                       readPixels(via270!).map { "\($0)" },
                       "-90 should produce identical pixels to 270")
    }

    // MARK: - rotateCGImage: pixel orientation correctness (2x2)

    // Original (top-to-bottom, left-to-right): TL=red TR=green BL=blue BR=white
    //
    // Expected layouts are derived directly from the CTM math in CGImageRotation.swift
    // (translate + rotate, with the image's visual top mapping to high-y of the draw rect).
    func testRotate_90_pixelOrientation() {
        let img = make2x2()
        let rotated = rotateCGImage(img, degrees: 90)!
        XCTAssertEqual(rotated.width, 2)
        XCTAssertEqual(rotated.height, 2)
        let p = readPixels(rotated)
        // 90 mapping: newTL=old TR(green), newTR=old BR(white),
        //             newBL=old TL(red),   newBR=old BL(blue)
        assertColor(p[0], green, "90 TL should be original TR (green)")
        assertColor(p[1], white, "90 TR should be original BR (white)")
        assertColor(p[2], red,   "90 BL should be original TL (red)")
        assertColor(p[3], blue,  "90 BR should be original BL (blue)")
    }

    func testRotate_180_pixelOrientation() {
        let img = make2x2()
        let rotated = rotateCGImage(img, degrees: 180)!
        let p = readPixels(rotated)
        // 180: everything mirrored both axes:
        // newTL=old BR(white), newTR=old BL(blue),
        // newBL=old TR(green), newBR=old TL(red)
        assertColor(p[0], white, "180 TL should be original BR (white)")
        assertColor(p[1], blue,  "180 TR should be original BL (blue)")
        assertColor(p[2], green, "180 BL should be original TR (green)")
        assertColor(p[3], red,   "180 BR should be original TL (red)")
    }

    func testRotate_270_pixelOrientation() {
        let img = make2x2()
        let rotated = rotateCGImage(img, degrees: 270)!
        let p = readPixels(rotated)
        // 270 mapping: newTL=old BL(blue), newTR=old TL(red),
        //              newBL=old BR(white), newBR=old TR(green)
        assertColor(p[0], blue,  "270 TL should be original BL (blue)")
        assertColor(p[1], red,   "270 TR should be original TL (red)")
        assertColor(p[2], white, "270 BL should be original BR (white)")
        assertColor(p[3], green, "270 BR should be original TR (green)")
    }

    func testRotate_90Then270_roundTripsToOriginal() {
        let img = make2x2()
        let once = rotateCGImage(img, degrees: 90)!
        let back = rotateCGImage(once, degrees: 270)!
        let original = readPixels(img)
        let result = readPixels(back)
        XCTAssertEqual(result.count, original.count)
        for i in 0..<original.count {
            assertColor(result[i], original[i], "round-trip pixel \(i)")
        }
    }

    func testRotate_four90sReturnsToOriginal() {
        var img = make2x2()
        for _ in 0..<4 {
            img = rotateCGImage(img, degrees: 90)!
        }
        let original = readPixels(make2x2())
        let result = readPixels(img)
        for i in 0..<original.count {
            assertColor(result[i], original[i], "four 90s pixel \(i)")
        }
    }

    // MARK: - flipCGImage

    func testFlip_horizontalFalse_returnsSameInstance() {
        let img = make2x2()
        let flipped = flipCGImage(img, horizontal: false)
        XCTAssertTrue(flipped === img, "horizontal:false should return the same instance")
    }

    func testFlip_keepsDimensions() {
        let img = makeSolid(width: 4, height: 2)
        let flipped = flipCGImage(img, horizontal: true)
        XCTAssertNotNil(flipped)
        XCTAssertEqual(flipped?.width, 4)
        XCTAssertEqual(flipped?.height, 2)
    }

    func testFlip_horizontal_pixelOrientation() {
        let img = make2x2()
        let flipped = flipCGImage(img, horizontal: true)!
        let p = readPixels(flipped)
        // Horizontal flip mirrors left<->right, rows unchanged:
        // newTL=old TR(green), newTR=old TL(red),
        // newBL=old BR(white), newBR=old BL(blue)
        assertColor(p[0], green, "flipH TL should be original TR (green)")
        assertColor(p[1], red,   "flipH TR should be original TL (red)")
        assertColor(p[2], white, "flipH BL should be original BR (white)")
        assertColor(p[3], blue,  "flipH BR should be original BL (blue)")
    }

    func testFlip_twiceReturnsToOriginal() {
        let img = make2x2()
        let once = flipCGImage(img, horizontal: true)!
        let twice = flipCGImage(once, horizontal: true)!
        let original = readPixels(img)
        let result = readPixels(twice)
        for i in 0..<original.count {
            assertColor(result[i], original[i], "double flip pixel \(i)")
        }
    }
}
