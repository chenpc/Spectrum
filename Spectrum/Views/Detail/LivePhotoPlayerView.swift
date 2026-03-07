import SwiftUI
import AVFoundation

/// Lightweight AVPlayer overlay for Live Photo playback.
/// Plays a short companion .mov and loops until stopped.
struct LivePhotoPlayerView: NSViewRepresentable {
    let url: URL
    let bookmarkData: Data?
    let isPlaying: Bool
    var onEnded: (() -> Void)?

    func makeNSView(context: Context) -> LivePhotoNSView {
        let view = LivePhotoNSView()
        view.configure(url: url, bookmarkData: bookmarkData)
        view.onPlaybackEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: LivePhotoNSView, context: Context) {
        nsView.onPlaybackEnded = onEnded
        if isPlaying {
            nsView.play()
        } else {
            nsView.stop()
        }
    }
}

class LivePhotoNSView: NSView {
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    nonisolated(unsafe) private var endObserver: Any?
    var onPlaybackEnded: (() -> Void)?
    private var scopeURL: URL?
    private var scopeStarted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(url: URL, bookmarkData: Data?) {
        // Start security scope
        if let data = bookmarkData,
           let folderURL = try? BookmarkService.resolveBookmark(data) {
            scopeURL = folderURL
            scopeStarted = folderURL.startAccessingSecurityScopedResource()
        }

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = false
        let layer = AVPlayerLayer(player: p)
        layer.videoGravity = .resizeAspect
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        player = p
        playerLayer = layer

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onPlaybackEnded?()
            }
        }
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    func play() {
        player?.seek(to: .zero)
        player?.play()
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
    }

    deinit {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if scopeStarted, let url = scopeURL {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
