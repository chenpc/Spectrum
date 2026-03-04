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
    /// CALayer colorspace display name (e.g. "PQ", "HLG", "sRGB").
    private(set) var layerColorspaceInfo: String = "-"
    /// MDK setColorSpace value (e.g. "PQ", "HLG", "BT.709").
    private(set) var mdkColorspaceInfo: String = "-"
    /// Latest gyro computeMatrix time in ms (0 when gyro inactive).
    private(set) var gyroComputeMs: Double = 0

    /// True when gyro stabilization is loaded and active.
    private(set) var gyroStabEnabled: Bool = false
    /// True once gyro loaded successfully for this video — survives stopGyroStab().
    /// Reset only on reset() (new video load).
    private(set) var gyroAvailable: Bool = false
    /// Debug: last gyro error message (nil = no error or not attempted).
    private(set) var gyroLastError: String? = nil
    /// Debug: true while gyro is currently loading in background.
    private(set) var gyroIsLoading: Bool = false
    /// Retained during loading and playback; nil = stab off.
    private var activeGyroCore: GyroCore?
    /// Debug lens profile summary for diagnostics badge.
    var gyroLensInfo: String {
        guard let c = activeGyroCore else { return "" }
        let modelName: String
        switch c.distortionModel {
        case 1:  modelName = "OpenCVFish"
        case 3:  modelName = "Poly3"
        case 4:  modelName = "Poly5"
        case 7:  modelName = "Sony"
        default: modelName = "none(\(c.distortionModel))"
        }
        let k = (0..<4).map { String(format: "%.4f", c.distortionK[$0]) }.joined(separator: ",")
        let f = String(format: "%.1f,%.1f", c.gyroFx, c.gyroFy)
        let cx = String(format: "%.1f,%.1f", c.gyroCx, c.gyroCy)
        let lca = String(format: "%.2f", c.lensCorrectionAmount)
        let fov = String(format: "%.4f", c.frameFov)
        let fovRange = String(format: "[%.4f-%.4f]", c.fovMin, c.fovMax)
        let lens = c.lensProfileName
        return "\(modelName) f=[\(f)] c=[\(cx)]\nk=[\(k)]\nlens=\(lens)\nlca=\(lca) fov=\(fov) \(fovRange)"
    }
    /// When true, the user pressed play while gyro was loading — defer actual unpause
    /// until gyro is ready. This prevents mpv from decoding (and dropping) frames
    /// while `waitingForGyro` suppresses draw().
    private var deferredPlay = false
    /// When true, gyro is loading but nsView hasn't been attached yet.
    /// startPolling() will set waitingForGyro on the view when it connects.
    private var gyroLoadPending = false

    private weak var nsView: MPVPlayerNSView?
    /// Serial background queue: reads properties off the main thread.
    private let pollQueue = DispatchQueue(label: "com.spectrum.mpv.poll", qos: .utility)
    private var isPolling = false

    /// When false, all diagnostic reads (FPS, CV) are skipped — zero overhead.
    var diagnosticsEnabled: Bool = true {
        didSet {
            let enabled = diagnosticsEnabled
            Task { @MainActor [weak self] in
                self?.nsView?.diagnosticsEnabled = enabled
            }
        }
    }

    /// Call before loading a new file to clear stale state.
    func reset() {
        stopGyroStab()
        gyroAvailable = false
        gyroLastError = nil
        gyroIsLoading = false
        currentTime = 0
        duration = 0
        isPlaying = false
        renderFPS = 0
        renderCV = 0
        renderStability = 1
        videoFPS = 0
        layerColorspaceInfo = "-"
        mdkColorspaceInfo = "-"
        gyroComputeMs = 0
    }

    // MARK: - Gyro stabilization

    /// Start gyroflow stabilization for the given video path.
    /// Non-blocking: gyrocore_load runs in the background (~0.3s).
    func startGyroStab(videoPath: String, fps: Double,
                       config: GyroConfig = GyroConfig(),
                       lensPath: String? = nil) {
        stopGyroStab()
        // Suppress rendering until gyro is ready — prevents unstabilized first-frame flash.
        // If nsView isn't attached yet (early start before SwiftUI creates the view),
        // gyroLoadPending tells startPolling() to set waitingForGyro when it connects.
        if let v = nsView {
            v.setWaitingForGyro(true)
        }
        gyroLoadPending = true
        gyroLastError = nil
        gyroIsLoading = true
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
                guard let self, self.activeGyroCore === core else { return }  // stale guard
                self.gyroLoadPending = false
                self.gyroIsLoading = false
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
                guard let self, self.activeGyroCore === core else { return }  // stale guard
                self.gyroLoadPending = false
                self.gyroIsLoading = false
                self.gyroLastError = msg
                self.gyroAvailable = false
                self.activeGyroCore = nil
                self.nsView?.setWaitingForGyro(false)  // Release suppression on failure too
                // Still start playback if user pressed play during gyro load
                if self.deferredPlay {
                    self.deferredPlay = false
                    self.nsView?.setPause(false)
                }
            }
        )
    }

    /// Stop and detach gyro stabilization.
    func stopGyroStab() {
        deferredPlay = false
        gyroLoadPending = false
        gyroStabEnabled = false
        nsView?.loadGyroCore(nil)
        activeGyroCore?.stop()
        activeGyroCore = nil
    }

    func startPolling(view: MPVPlayerNSView) {
        guard nsView !== view else { return }   // already polling this view
        nsView = view
        // If gyro started loading before the view was attached, suppress rendering now.
        if gyroLoadPending {
            view.setWaitingForGyro(true)
        }
        // If gyro already finished loading before the view existed, pass it now.
        if gyroStabEnabled, let core = activeGyroCore {
            view.loadGyroCore(core)
        }
        isPolling = true
        schedulePoll()
    }

    private func schedulePoll() {
        pollQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.doPoll()
        }
    }

    /// Runs on `pollQueue` (background). Reads properties off the main thread,
    /// then dispatches only the fast @Observable property assignments back to main.
    private func doPoll() {
        guard isPolling, let v = nsView else {
            isPolling = false
            return
        }
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
        let gyroMs = diag ? (activeGyroCore?.lastFetchMs ?? 0) : 0
        let csInfo  = diag ? v.layerColorspaceInfo : "-"
        let mdkCS   = diag ? v.mdkColorspaceInfo : "-"

        // Main thread only does fast property assignments.
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
                self.gyroComputeMs = gyroMs
                self.layerColorspaceInfo = csInfo
                self.mdkColorspaceInfo = mdkCS
            }
        }

        schedulePoll()
    }

    func stopPolling() {
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
