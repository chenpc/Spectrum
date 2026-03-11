import Foundation

// MARK: - GyroConfig
/// All configurable parameters for gyroflow-core stabilization.
/// Serialized to JSON and passed to gyrocore_load() via config_json.
struct GyroConfig: Codable {
    var readoutMs:            Double = 0      // RS readout time; 0 = auto from metadata
    var smooth:               Double = 0      // Global smoothness; 0 = default 0.5
    var gyroOffsetMs:         Double = 0      // Gyro-video sync offset
    var integrationMethod:    Int?   = nil    // nil=auto; 0=Complementary 1=Complementary2 2=VQF
    var imuOrientation:       String? = nil   // nil=auto from video metadata
    var fov:                  Double = 1.0    // FOV scale
    var lensCorrectionAmount: Double = 1.0    // 0.0–1.0
    var zoomingMethod:        Int    = 1      // 0=None 1=Dynamic 2=Static
    var zoomingAlgorithm:     Int    = 1      // 0=GaussianFilter 1=EnvelopeFollower (Dynamic only)
    var adaptiveZoom:         Double = 4.0    // Adaptive zoom window in seconds (Dynamic only)
    var maxZoom:              Double = 130.0  // Max zoom percent
    var maxZoomIterations:    Int    = 5
    var useGravityVectors:    Bool   = false
    var videoSpeed:           Double = 1.0
    var horizonLockEnabled:   Bool   = false
    var horizonLockAmount:    Double = 1.0    // 0.0–1.0
    var horizonLockRoll:      Double = 0      // Degrees
    var perAxis:              Bool   = false
    var smoothnessPitch:      Double = 0      // 0 = use global
    var smoothnessYaw:        Double = 0
    var smoothnessRoll:       Double = 0
    var lensDbDir:            String? = nil  // Dir containing camera_presets/ (e.g. Gyroflow.app)

    enum CodingKeys: String, CodingKey {
        case readoutMs            = "readout_ms"
        case smooth
        case gyroOffsetMs         = "gyro_offset_ms"
        case integrationMethod    = "integration_method"
        case imuOrientation       = "imu_orientation"
        case fov
        case lensCorrectionAmount = "lens_correction_amount"
        case zoomingMethod        = "zooming_method"
        case zoomingAlgorithm     = "zooming_algorithm"
        case adaptiveZoom         = "adaptive_zoom"
        case maxZoom              = "max_zoom"
        case maxZoomIterations    = "max_zoom_iterations"
        case useGravityVectors    = "use_gravity_vectors"
        case videoSpeed           = "video_speed"
        case horizonLockEnabled   = "horizon_lock_enabled"
        case horizonLockAmount    = "horizon_lock_amount"
        case horizonLockRoll      = "horizon_lock_roll"
        case perAxis              = "per_axis"
        case smoothnessPitch      = "smoothness_pitch"
        case smoothnessYaw        = "smoothness_yaw"
        case smoothnessRoll       = "smoothness_roll"
        case lensDbDir            = "lens_db_dir"
    }
}

// MARK: - GyroCoreProvider

/// Common interface for gyro stabilization cores.
/// Used by the GPU warp pipeline to render stabilized frames.
protocol GyroCoreProvider: AnyObject {
    var isReady: Bool { get }
    var gyroVideoW: Float { get }
    var gyroVideoH: Float { get }
    var gyroFps: Double { get }
    var frameCount: Int { get }
    func computeMatrixAtTime(timeSec: Double) -> (UnsafeBufferPointer<Float>, Bool)?
    var frameFx: Float { get }
    var frameFy: Float { get }
    var frameCx: Float { get }
    var frameCy: Float { get }
    var frameK: [Float] { get }
    var distortionK: [Float] { get }
    var distortionModel: Int32 { get }
    var rLimit: Float { get }
    var frameFov: Float { get }
    var lensCorrectionAmount: Float { get }
    var lastFetchMs: Double { get }
    func stop()
}
