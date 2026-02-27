import XCTest
@testable import Spectrum

final class GyroConfigTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Round-trip

    func testDefaultRoundTrip() throws {
        let config = GyroConfig()
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(GyroConfig.self, from: data)
        XCTAssertEqual(decoded.readoutMs, 0)
        XCTAssertEqual(decoded.smooth, 0)
        XCTAssertEqual(decoded.integrationMethod, 2)
        XCTAssertEqual(decoded.imuOrientation, "YXz")
        XCTAssertEqual(decoded.fov, 1.0)
        XCTAssertEqual(decoded.lensCorrectionAmount, 1.0)
        XCTAssertEqual(decoded.maxZoom, 130.0)
        XCTAssertEqual(decoded.videoSpeed, 1.0)
        XCTAssertFalse(decoded.useGravityVectors)
        XCTAssertFalse(decoded.perAxis)
    }

    func testCustomValuesRoundTrip() throws {
        var config = GyroConfig()
        config.readoutMs = 15.5
        config.smooth = 0.8
        config.gyroOffsetMs = -3.0
        config.integrationMethod = 1
        config.imuOrientation = "XYz"
        config.fov = 1.2
        config.horizonLockAmount = 0.5
        config.perAxis = true
        config.smoothnessPitch = 0.3
        config.smoothnessYaw = 0.4
        config.smoothnessRoll = 0.5

        let data = try encoder.encode(config)
        let decoded = try decoder.decode(GyroConfig.self, from: data)

        XCTAssertEqual(decoded.readoutMs, 15.5)
        XCTAssertEqual(decoded.smooth, 0.8)
        XCTAssertEqual(decoded.gyroOffsetMs, -3.0)
        XCTAssertEqual(decoded.integrationMethod, 1)
        XCTAssertEqual(decoded.imuOrientation, "XYz")
        XCTAssertEqual(decoded.fov, 1.2)
        XCTAssertEqual(decoded.horizonLockAmount, 0.5)
        XCTAssertTrue(decoded.perAxis)
        XCTAssertEqual(decoded.smoothnessPitch, 0.3)
        XCTAssertEqual(decoded.smoothnessYaw, 0.4)
        XCTAssertEqual(decoded.smoothnessRoll, 0.5)
    }

    // MARK: - JSON Keys

    func testJSONKeysAreSnakeCase() throws {
        let config = GyroConfig()
        let data = try encoder.encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let expectedKeys: Set<String> = [
            "readout_ms", "smooth", "gyro_offset_ms", "integration_method",
            "imu_orientation", "fov", "lens_correction_amount", "zooming_method",
            "adaptive_zoom", "max_zoom", "max_zoom_iterations", "use_gravity_vectors",
            "video_speed", "horizon_lock_amount", "horizon_lock_roll",
            "per_axis", "smoothness_pitch", "smoothness_yaw", "smoothness_roll",
        ]
        XCTAssertEqual(Set(json.keys), expectedKeys, "JSON keys should be snake_case")
    }

    // MARK: - GyroCore dylib

    func testDylibFoundDoesNotCrash() {
        // Just instantiate — if dylib is missing, GyroCore logs a warning but doesn't crash
        let core = GyroCore()
        XCTAssertFalse(core.isReady, "Fresh GyroCore should not be ready")
    }
}
