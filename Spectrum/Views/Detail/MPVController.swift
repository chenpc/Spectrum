import SwiftUI

// MARK: - MPVController

/// Observable state for mpv playback; polled via background queue at ~4 Hz.
///
/// Property reads (mpv C API calls) happen on `pollQueue` (background) to keep the
/// main thread free for `layer.display()` calls — this is the primary fix for high CV.
/// Only the lightweight @Observable setter assignments are dispatched back to main.
@Observable
final class MPVController: @unchecked Sendable {
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    /// Actual render FPS measured in draw() — updated ~every frame.
    private(set) var renderFPS: Double = 0
    /// Coefficient of variation of frame intervals (stddev/mean).
    private(set) var renderCV: Double = 0
    /// 0 = jittery, 1 = perfectly stable.
    private(set) var renderStability: Double = 1
    /// Declared FPS of the video file.
    private(set) var videoFPS: Double = 0
    /// Cumulative VO-level dropped frames (render API queue replacement).
    private(set) var droppedFrames: Int = 0
    /// Cumulative decoder-level dropped frames (B-frame skip etc.).
    private(set) var decoderDroppedFrames: Int = 0
    /// Reflects the actual hardware decoder in use after file load (e.g. "videotoolbox").
    private(set) var hwdecInfo: String = "-"
    /// Latest gyro computeMatrix time in ms (0 when gyro inactive).
    private(set) var gyroComputeMs: Double = 0

    /// True when gyro stabilization is loaded and active.
    private(set) var gyroStabEnabled: Bool = false
    /// True once gyro loaded successfully for this video — survives stopGyroStab().
    /// Reset only on reset() (new video load).
    private(set) var gyroAvailable: Bool = false
    /// Retained during loading and playback; nil = stab off.
    private var activeGyroCore: GyroCore?
    /// When true, the user pressed play while gyro was loading — defer actual unpause
    /// until gyro is ready. This prevents mpv from decoding (and dropping) frames
    /// while `waitingForGyro` suppresses draw().
    private var deferredPlay = false

    private weak var nsView: MPVPlayerNSView?
    /// Serial background queue: reads mpv properties off the main thread.
    private let pollQueue = DispatchQueue(label: "com.spectrum.mpv.poll", qos: .utility)
    private var isPolling = false
    private var hwdecCheckTask: Task<Void, Never>?

    /// When false, all diagnostic reads (FPS, CV, hwdec) are skipped — zero overhead.
    var diagnosticsEnabled: Bool = true {
        didSet {
            let enabled = diagnosticsEnabled
            // nsView is @MainActor-isolated (NSView); dispatch to avoid
            // @Observable macro concurrency warning.
            Task { @MainActor [weak self] in
                self?.nsView?.diagnosticsEnabled = enabled
                if !enabled {
                    self?.hwdecCheckTask?.cancel()
                    self?.hwdecCheckTask = nil
                }
            }
        }
    }

    /// Call before loading a new file to clear stale state.
    func reset() {
        stopGyroStab()
        gyroAvailable = false
        currentTime = 0
        duration = 0
        isPlaying = false
        renderFPS = 0
        renderCV = 0
        renderStability = 1
        videoFPS = 0
        droppedFrames = 0
        decoderDroppedFrames = 0
        hwdecInfo = "-"
        gyroComputeMs = 0
        hwdecCheckTask?.cancel()
    }

    // MARK: - Gyro stabilization

    /// Start gyroflow stabilization for the given video path.
    /// Non-blocking: gyrocore_load runs in the background (~0.3s).
    func startGyroStab(videoPath: String, fps: Double,
                       config: GyroConfig = GyroConfig(),
                       lensPath: String? = nil) {
        stopGyroStab()
        // Suppress rendering until gyro is ready — prevents unstabilized first-frame flash.
        nsView?.setWaitingForGyro(true)
        // If config.readoutMs is 0, estimate from fps
        var cfg = config
        if cfg.readoutMs <= 0 {
            cfg.readoutMs = GyroCore.readoutMs(for: fps)
        }
        let core = GyroCore()
        activeGyroCore = core
        core.start(
            videoPath: videoPath,
            lensPath: lensPath,
            config: cfg,
            onReady: { [weak self] in
                guard let self else { return }
                self.gyroStabEnabled = true
                self.gyroAvailable = true
                self.nsView?.loadGyroCore(core)  // clears waitingForGyro
                // Actually unpause if user pressed play during gyro load
                if self.deferredPlay {
                    self.deferredPlay = false
                    self.nsView?.setPause(false)
                }
            },
            onError: { [weak self] msg in
                print("[gyro] ❌ \(msg)")
                self?.activeGyroCore = nil
                self?.nsView?.setWaitingForGyro(false)  // 失敗也要解除抑制
                // Still start playback if user pressed play during gyro load
                if self?.deferredPlay == true {
                    self?.deferredPlay = false
                    self?.nsView?.setPause(false)
                }
            }
        )
    }

    /// Stop and detach gyro stabilization.
    func stopGyroStab() {
        deferredPlay = false
        gyroStabEnabled = false
        nsView?.loadGyroCore(nil)
        activeGyroCore?.stop()
        activeGyroCore = nil
    }

    func startPolling(view: MPVPlayerNSView) {
        guard nsView !== view else { return }   // already polling this view
        nsView = view
        // After 1 s the file should be open; read the actual decoder for diagnostics.
        hwdecCheckTask?.cancel()
        if diagnosticsEnabled {
            hwdecCheckTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let v = self.nsView else { return }
                self.hwdecInfo = v.hwdecCurrent
            }
        }
        isPolling = true
        schedulePoll()
    }

    private func schedulePoll() {
        pollQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.doPoll()
        }
    }

    /// Runs on `pollQueue` (background). Reads all mpv properties off the main thread,
    /// then dispatches only the fast @Observable property assignments back to main.
    private func doPoll() {
        guard isPolling, let v = nsView else {
            isPolling = false
            return
        }
        // mpv C API (mpv_get_property_string) is thread-safe per mpv documentation.
        // Playback state (always needed for control bar)
        let d       = v.videoDuration
        let eof     = v.isEOFReached
        let ct      = eof ? 0.0 : v.currentTime
        let playing = eof ? false : !v.isPaused

        // Diagnostics (only read when badge is enabled — zero overhead otherwise)
        let diag = diagnosticsEnabled
        let fps     = diag ? v.renderFPS     : 0
        let cv      = diag ? v.renderCV      : 0
        let stab    = diag ? v.renderStability : 1
        let vfps    = diag ? v.videoFPS      : 0
        let dropped = diag ? v.droppedFrames : 0
        let decDropped = diag ? v.decoderDroppedFrames : 0
        let gyroMs = diag ? (activeGyroCore?.lastFetchMs ?? 0) : 0

        // Main thread only does fast property assignments — no mpv API calls here.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if d > 0 { self.duration = d }
            if eof {
                self.currentTime = 0
                self.isPlaying = false
            } else {
                self.currentTime = ct
                self.isPlaying = playing
            }
            if diag {
                self.renderFPS = fps
                self.renderCV = cv
                self.renderStability = stab
                if vfps > 0 { self.videoFPS = vfps }
                self.droppedFrames = dropped
                self.decoderDroppedFrames = decDropped
                self.gyroComputeMs = gyroMs
            }
        }

        schedulePoll()
    }

    func stopPolling() {
        hwdecCheckTask?.cancel()
        hwdecCheckTask = nil
        isPolling = false
        stopGyroStab()
        nsView = nil
    }

    func togglePlayPause() {
        if !isPlaying, let v = nsView, v.isEOFReached {
            // Replay from beginning
            v.seek(to: 0)
        }
        isPlaying.toggle()
        // Defer actual unpause while gyro is loading — mpv stays paused so no frames
        // are decoded (and dropped) while waitingForGyro suppresses draw().
        if isPlaying && activeGyroCore != nil && !gyroStabEnabled {
            deferredPlay = true
            return
        }
        deferredPlay = false
        nsView?.setPause(!isPlaying)
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        nsView?.seek(to: seconds)
    }
}
