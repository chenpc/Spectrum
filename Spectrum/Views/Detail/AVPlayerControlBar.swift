import SwiftUI
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - AVPlayerController

/// Observable wrapper around AVPlayer exposing playback state and frame-timing diagnostics.
///
/// Frame timing uses CVDisplayLink + AVPlayerItemVideoOutput — same measurement methodology
/// as MPVOpenGLLayer so the CV/FPS numbers are directly comparable.
@Observable
final class AVPlayerController: @unchecked Sendable {
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    /// Codec name, e.g. "HEVC", "H.264". Populated async after attach.
    private(set) var codecInfo: String = "-"
    /// Declared FPS from the video track.
    private(set) var videoFPS: Double = 0
    /// Render FPS measured via display link + frame detection.
    private(set) var renderFPS: Double = 0
    /// Coefficient of variation of frame intervals. Lower = more stable.
    private(set) var renderCV: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CVDisplayLink?

    // Frame timing — updated on display link background thread only.
    // isAttached guards against stale dispatch blocks reaching the main thread
    // after detach() has cleared state (arm64 Bool r/w is single-instruction).
    private var isAttached: Bool = false
    private var frameIntervals: [Double] = []
    private var lastFrameTime: CFTimeInterval = 0
    private var lastStatsUpdate: CFTimeInterval = 0
    private var cachedFPS: Double = 0
    private var cachedCV: Double = 0
    // Tracks the presentation timestamp of the last detected frame.
    // hasNewPixelBuffer returns true on every display link tick for the same frame
    // until copyPixelBuffer is called; comparing presentationTime deduplicates this.
    private var lastPresentationItemTime: CMTime = .invalid

    // MARK: - Attach / Detach

    func attach(player: AVPlayer) {
        detach()
        isAttached = true
        self.player = player

        // Periodic time observer at 4 Hz (main thread — lightweight property assignments)
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            guard let self, let player else { return }
            let secs = CMTimeGetSeconds(time)
            if secs.isFinite && secs >= 0 { self.currentTime = secs }
            if let item = player.currentItem {
                let d = CMTimeGetSeconds(item.duration)
                if d.isFinite && d > 0 { self.duration = d }
            }
            self.isPlaying = player.timeControlStatus == .playing
        }

        // Frame-timing: AVPlayerItemVideoOutput detects new frames;
        // CVDisplayLink measures inter-frame intervals (fires at display refresh rate).
        if let item = player.currentItem {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            videoOutput = output
            setupDisplayLink()
        }

        // Async codec name + video FPS from the asset track
        if let item = player.currentItem {
            Task { @MainActor [weak self] in
                async let codec = Self.loadCodecInfo(item: item)
                async let fps   = Self.loadVideoFPS(item: item)
                let (c, f) = await (codec, fps)
                guard let self, self.isAttached else { return }
                self.codecInfo = c
                self.videoFPS  = f
            }
        }
    }

    func detach() {
        // Set flag BEFORE stopping display link so any in-flight dispatch blocks skip.
        isAttached = false
        if let dl = displayLink { CVDisplayLinkStop(dl); displayLink = nil }
        if let obs = timeObserver, let p = player { p.removeTimeObserver(obs) }
        if let output = videoOutput, let item = player?.currentItem { item.remove(output) }
        videoOutput = nil
        timeObserver = nil
        player = nil
        currentTime = 0; duration = 0; isPlaying = false
        codecInfo = "-"; videoFPS = 0; renderFPS = 0; renderCV = 0
        frameIntervals = []; lastFrameTime = 0; lastStatsUpdate = 0
        cachedFPS = 0; cachedCV = 0; lastPresentationItemTime = .invalid
    }

    // MARK: - Playback control

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0 && currentTime >= duration - 0.5 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    // MARK: - CVDisplayLink

    private func setupDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, ctx -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            Unmanaged<AVPlayerController>.fromOpaque(ctx).takeUnretainedValue().handleDisplayLinkTick()
            return kCVReturnSuccess
        }, selfRef)
        CVDisplayLinkStart(dl)
        displayLink = dl
    }

    /// Runs on the CVDisplayLink background thread (~60–120 Hz).
    /// Uses copyPixelBuffer to detect new frames and their presentation timestamps.
    /// Deduplicates same-frame ticks: on a 120 Hz display, hasNewPixelBuffer returns true
    /// on every tick for the same frame until copyPixelBuffer is called, which would
    /// incorrectly double-count frames (e.g. 120 fps measured for a 60 fps video).
    private func handleDisplayLinkTick() {
        guard isAttached,
              let output = videoOutput,
              let player  = player,
              let item    = player.currentItem else { return }

        let itemTime = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }

        // copyPixelBuffer returns the actual presentation timestamp of the frame.
        // Compare with the last seen presentation time to skip duplicate detections.
        var presentationTime = CMTime.zero
        guard output.copyPixelBuffer(forItemTime: itemTime,
                                     itemTimeForDisplay: &presentationTime) != nil else { return }
        // buffer released here (Swift ARC — no pixel data copied, IOSurface ref only)

        if lastPresentationItemTime.isValid,
           CMTimeCompare(presentationTime, lastPresentationItemTime) == 0 { return }
        lastPresentationItemTime = presentationTime

        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt < 2.0 {   // ignore gaps during pause/seek
                frameIntervals.append(dt)
                if frameIntervals.count > 60 { frameIntervals.removeFirst() }

                if frameIntervals.count >= 5 {
                    let mean = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                    cachedFPS = mean > 0 ? 1.0 / mean : 0

                    let variance = frameIntervals
                        .map { ($0 - mean) * ($0 - mean) }
                        .reduce(0, +) / Double(frameIntervals.count)
                    cachedCV = mean > 0 ? variance.squareRoot() / mean : 1

                    // Dispatch @Observable updates at ~4 Hz to avoid flooding main thread
                    if now - lastStatsUpdate > 0.25 {
                        lastStatsUpdate = now
                        let fps = cachedFPS, cv = cachedCV
                        DispatchQueue.main.async { [weak self] in
                            guard self?.isAttached == true else { return }
                            self?.renderFPS = fps
                            self?.renderCV  = cv
                        }
                    }
                }
            }
        }
        lastFrameTime = now
    }

    // MARK: - Asset helpers

    private static func loadCodecInfo(item: AVPlayerItem) async -> String {
        guard let tracks  = try? await item.asset.loadTracks(withMediaType: .video),
              let track   = tracks.first,
              let formats = try? await track.load(.formatDescriptions),
              let desc    = formats.first else { return "-" }
        let sub = CMFormatDescriptionGetMediaSubType(desc)
        switch sub {
        case kCMVideoCodecType_H264:             return "H.264"
        case kCMVideoCodecType_HEVC:             return "HEVC"
        case kCMVideoCodecType_AppleProRes422:   return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444:  return "ProRes 4444"
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes HQ"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes LT"
        default:
            let chars = [
                Character(UnicodeScalar((sub >> 24) & 0xFF)!),
                Character(UnicodeScalar((sub >> 16) & 0xFF)!),
                Character(UnicodeScalar((sub >>  8) & 0xFF)!),
                Character(UnicodeScalar( sub        & 0xFF)!)
            ]
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func loadVideoFPS(item: AVPlayerItem) async -> Double {
        guard let tracks = try? await item.asset.loadTracks(withMediaType: .video),
              let track  = tracks.first,
              let fps    = try? await track.load(.nominalFrameRate) else { return 0 }
        return Double(fps)
    }
}

// MARK: - AVPlayerControlBar

/// Custom floating control bar for AVPlayer — identical visual style to MPVControlBar.
struct AVPlayerControlBar: View {
    let controller: AVPlayerController
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0   // normalised 0…1

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Text(formatTime(displaySeconds))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: {
                        isScrubbing ? scrubPosition
                            : (controller.duration > 0
                               ? controller.currentTime / controller.duration
                               : 0)
                    },
                    set: { scrubPosition = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        controller.seek(to: scrubPosition * controller.duration)
                    }
                }
            )
            .controlSize(.small)

            Text(formatTime(controller.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var displaySeconds: Double {
        isScrubbing ? scrubPosition * controller.duration : controller.currentTime
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
