import SwiftUI

// MARK: - VideoControlBar

struct VideoControlBar: View {
    let controller: VideoController
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0   // normalised 0…1

    var body: some View {
        HStack(spacing: 8) {
            // Play / Pause — matches AVPlayerView button weight & size
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

            // Elapsed time
            Text(formatTime(displaySeconds))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            // Scrubber
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

            // Remaining / total
            Text(formatTime(controller.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            // Mute toggle
            Button {
                controller.toggleMute()
            } label: {
                Image(systemName: controller.isMuted ? "speaker.slash.fill"
                      : controller.volume > 0.5 ? "speaker.wave.2.fill"
                      : controller.volume > 0 ? "speaker.wave.1.fill"
                      : "speaker.fill")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.isMuted ? .secondary : .primary)

            // Volume slider
            Slider(value: Binding(
                get: { controller.isMuted ? 0 : controller.volume },
                set: {
                    controller.volume = $0
                    if $0 > 0 { controller.isMuted = false }
                }
            ), in: 0...1)
            .controlSize(.small)
            .frame(width: 60)
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
