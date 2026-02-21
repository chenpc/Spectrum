import SwiftUI

struct SettingsView: View {
    @AppStorage("thumbnailCacheLimitMB") private var thumbnailCacheLimitMB: Int = 500
    @AppStorage("showMPVDiagBadge") private var showMPVDiagBadge: Bool = true
    @AppStorage("videoPlayer") private var videoPlayer: String = "libmpv"

    @State private var thumbSize: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // MARK: Cache
            Text("Cache")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Thumbnails")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Disk Usage")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: thumbSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        Task {
                            await ThumbnailService.shared.clearCache()
                            ThumbnailCacheState.shared.invalidate()
                            thumbSize = await ThumbnailService.shared.diskCacheSize()
                        }
                    }
                }

                HStack {
                    Text("Size Limit")
                    Spacer()
                    Picker("", selection: $thumbnailCacheLimitMB) {
                        Text("100 MB").tag(100)
                        Text("250 MB").tag(250)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1000)
                        Text("2 GB").tag(2000)
                        Text("∞").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            Divider()

            // MARK: Playback
            Text("Playback")
                .font(.headline)

            if LibMPV.shared.ok {
                Picker("Video decoder", selection: $videoPlayer) {
                    Text("libmpv").tag("libmpv")
                    Text("AVPlayer").tag("avplayer")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

            }

            Toggle("Show diagnostics badge", isOn: $showMPVDiagBadge)

        }
        .padding(20)
        .frame(width: 400)
        .task {
            thumbSize = await ThumbnailService.shared.diskCacheSize()
        }
    }
}
