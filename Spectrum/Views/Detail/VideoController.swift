import SwiftUI

// MARK: - VideoController

/// Observable state for video playback; polled via background queue at ~4 Hz.
///
/// Property reads happen on `pollQueue` (background) to keep the main thread free.
/// Only the lightweight @Observable setter assignments are dispatched back to main.
@Observable
final class VideoController: @unchecked Sendable {
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
    /// Decode colorspace info (e.g. "Video BT.2020", "V.2020 HLG->PQ").
    private(set) var decodeColorspaceInfo: String = "-"
    /// Pixel format (e.g. "YCbCr 10bit Video Range").
    private(set) var pixelFormatInfo: String = "-"
    /// Codec info (e.g. "dvh1 DV P8.4"), nil for non-DV.
    private(set) var codecInfo: String? = nil
    /// Color space (e.g. "BT.2020", "BT.709").
    private(set) var colorSpaceInfo: String = "-"
    /// True when DV content uses AVPlayerLayer.
    private(set) var isAVFLayerMode: Bool = false
    /// Gyro Stability Index: RMS inter-frame rotation angle (radians). Lower = more stable.
    private(set) var gyroSI: Double = 0

    /// True while AVFMetalView is running analyzeVideo() (between load() and player creation).
    private(set) var videoIsAnalyzing: Bool = false
    /// True while AVPlayer is created but not yet readyToPlay.
    private(set) var videoIsBuffering: Bool = false

    /// True when gyro stabilization is loaded and active.
    private(set) var gyroStabEnabled: Bool = false
    /// True once gyro loaded successfully for this video — survives stopGyroStab().
    /// Reset only on reset() (new video load).
    private(set) var gyroAvailable: Bool = false
    /// Debug: last gyro error message (nil = no error or not attempted).
    private(set) var gyroLastError: String? = nil
    /// Debug: true while gyro is currently loading in background.
    private(set) var gyroIsLoading: Bool = false
    /// Gyro parse progress 0.0–1.0 while loading; -1.0 otherwise.
    private(set) var gyroLoadProgress: Double = -1.0
    /// Retained during loading and playback; nil = stab off.
    private var activeGyroCore: GyroCore?
    /// When true, the user pressed play while gyro was loading — defer actual unpause
    /// until gyro is ready. This prevents mpv from decoding (and dropping) frames
    /// while `waitingForGyro` suppresses draw().
    private var deferredPlay = false
    /// When true, gyro is loading but nsView hasn't been attached yet.
    /// startPolling() will set waitingForGyro on the view when it connects.
    private var gyroLoadPending = false

    /// Prevents repeated seek(0) when EOF persists across poll cycles.
    private var didRewindOnEOF = false
    private weak var nsView: VideoPlayerNSView?
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
        videoIsAnalyzing = false
        videoIsBuffering = false
        currentTime = 0
        duration = 0
        isPlaying = false
        renderFPS = 0
        renderCV = 0
        renderStability = 1
        videoFPS = 0
        layerColorspaceInfo = "-"
        decodeColorspaceInfo = "-"
        pixelFormatInfo = "-"
        codecInfo = nil
        colorSpaceInfo = "-"
        isAVFLayerMode = false
        didRewindOnEOF = false
    }

    // MARK: - Gyro stabilization

    /// Start gyroflow stabilization for the given video path.
    /// Non-blocking: gyrocore_load runs in the background (~0.3s).
    func startGyroStab(videoPath: String, fps: Double,
                       config: GyroConfig = GyroConfig(),
                       lensPath: String? = nil) {
        Log.debug(Log.gyro, "[gyro] startGyroStab path=\(URL(fileURLWithPath: videoPath).lastPathComponent) fps=\(String(format:"%.2f",fps)) lens=\(lensPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none")")
        stopGyroStab()
        // Suppress rendering until gyro is ready — prevents unstabilized first-frame flash.
        // If nsView isn't attached yet (early start before SwiftUI creates the view),
        // gyroLoadPending tells startPolling() to set waitingForGyro when it connects.
        if let v = nsView {
            // If already playing, pause player during gyro load so audio stays in sync.
            // deferredPlay / pendingPause will resume once loadGyroCore() fires.
            if isPlaying {
                v.setPause(true)
                deferredPlay = true
                Log.debug(Log.gyro, "[gyro] pausing player during gyro load (isPlaying=true)")
            }
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
        // Poll gyro load progress every 150 ms until done.
        Task { @MainActor [weak self] in
            while let self, self.gyroIsLoading, self.activeGyroCore === core {
                let p = core.loadProgress
                self.gyroLoadProgress = p
                try? await Task.sleep(for: .milliseconds(150))
            }
            self?.gyroLoadProgress = -1.0
        }

        core.start(
            videoPath: videoPath,
            lensPath: lensPath,
            config: cfg,
            onReady: { [weak self] in
                guard let self, self.activeGyroCore === core else { return }  // stale guard
                self.gyroLoadPending = false
                self.gyroIsLoading = false
                self.gyroLoadProgress = -1.0
                self.gyroStabEnabled = true
                self.gyroAvailable = true
                // loadGyroCore() clears waitingForGyro and resumes if pendingPause==false
                // (handles initial-load deferred play via AVFMetalView's pendingPause).
                self.nsView?.loadGyroCore(core)
                // Resume if user toggled gyro ON while playing (deferredPlay),
                // or pressed play during gyro load (togglePlayPause set deferredPlay).
                // Calling play() on an already-playing AVPlayer is a harmless no-op.
                if self.deferredPlay {
                    self.deferredPlay = false
                    self.nsView?.setPause(false)
                    Log.debug(Log.gyro, "[gyro] onReady → resuming via deferredPlay")
                }
            },
            onError: { [weak self] msg in
                Log.gyro.warning("❌ \(msg, privacy: .public)")
                guard let self, self.activeGyroCore === core else { return }  // stale guard
                self.gyroLoadPending = false
                self.gyroIsLoading = false
                self.gyroLoadProgress = -1.0
                self.gyroLastError = msg
                self.gyroAvailable = false
                self.activeGyroCore = nil
                self.nsView?.setWaitingForGyro(false)  // Release suppression on failure too
                // Resume player if it was paused waiting for gyro
                if self.deferredPlay {
                    self.deferredPlay = false
                    self.nsView?.setPause(false)
                    Log.debug(Log.gyro, "[gyro] onError → resuming via deferredPlay")
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

    func startPolling(view: VideoPlayerNSView) {
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
        // Sync playback + volume/mute state to new view
        view.setPause(!isPlaying)
        view.setVolume(volume)
        view.setMute(isMuted)
        view.startDisplayLink()
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
        if eof {
            Log.player.debug("EOF detected  duration=\(d)s  realTime=\(v.currentTime)s  paused=\(v.isPaused)")
        }

        // Diagnostics (only read when badge is enabled — zero overhead otherwise)
        let diag = diagnosticsEnabled
        let fps     = diag ? v.renderFPS     : 0
        let cv      = diag ? v.renderCV      : 0
        let stab    = diag ? v.renderStability : 1
        let vfps    = diag ? v.videoFPS      : 0
        let si      = diag ? v.gyroSI : 0
        let csInfo  = diag ? v.layerColorspaceInfo : "-"
        let decCS   = diag ? v.decodeColorspaceInfo : "-"
        let pixFmt  = diag ? v.pixelFormatInfo : "-"
        let codec   = diag ? v.codecInfo : nil
        let csInfo2 = diag ? v.colorSpaceInfo : "-"
        let avfLayer = v.isAVFLayerMode
        let analyzing = v.isAnalyzing
        let buffering = v.isBuffering

        // Main thread only does fast property assignments.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.videoIsAnalyzing = analyzing
            self.videoIsBuffering = buffering
            if d > 0 { self.duration = d }
            if eof {
                self.currentTime = 0
                self.isPlaying = false
                if !self.didRewindOnEOF {
                    self.didRewindOnEOF = true
                    v.seek(to: 0)
                    v.setPause(true)
                }
            } else {
                self.didRewindOnEOF = false
                self.currentTime = ct
                self.isPlaying = playing
            }
            if diag {
                self.renderFPS = fps
                self.renderCV = cv
                self.renderStability = stab
                if vfps > 0 { self.videoFPS = vfps }
                self.gyroSI = si
                self.layerColorspaceInfo = csInfo
                self.decodeColorspaceInfo = decCS
                self.pixelFormatInfo = pixFmt
                self.codecInfo = codec
                self.colorSpaceInfo = csInfo2
                self.isAVFLayerMode = avfLayer
            }
        }

        schedulePoll()
    }

    func stopPolling() {
        isPolling = false
        nsView?.stopDisplayLink()
        stopGyroStab()
        nsView = nil
    }

    func togglePlayPause() {
        didRewindOnEOF = false
        isPlaying.toggle()
        Log.debug(Log.player, "[player] togglePlayPause → isPlaying=\(isPlaying) gyroStabEnabled=\(gyroStabEnabled) gyroLoading=\(gyroIsLoading)")
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
        didRewindOnEOF = false
        currentTime = seconds
        Log.debug(Log.player, "[player] seek to \(String(format:"%.3f",seconds))s")
        nsView?.seek(to: seconds)
    }

    // MARK: - Volume

    var volume: Float = 1.0 {
        didSet { nsView?.setVolume(volume) }
    }
    var isMuted: Bool = false {
        didSet { nsView?.setMute(isMuted) }
    }

    func toggleMute() { isMuted.toggle() }

    // MARK: - Colorspace / Decode mode

    @MainActor func cycleColorspace() { nsView?.cycleColorspace() }
    func cycleDecodeMode() { nsView?.cycleDecodeMode() }
    @MainActor func setColorspace(index: Int) { nsView?.setColorspace(index: index) }
    func setDecodeMode(index: Int) { nsView?.setDecodeMode(index: index) }
}
