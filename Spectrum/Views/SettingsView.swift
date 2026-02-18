import SwiftUI

struct SettingsView: View {
    @AppStorage("thumbnailCacheLimitMB") private var cacheLimitMB: Int = 500
    @AppStorage("prefetchCount") private var prefetchCount: Int = 2
    @AppStorage("cacheHistoryCount") private var cacheHistoryCount: Int = 10
    @AppStorage("cacheHistoryMemoryMB") private var cacheHistoryMemoryMB: Int = 1000
    @AppStorage("developerMode") private var developerMode: Bool = false
    @State private var currentCacheSize: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // MARK: - Prefetch
            Text("Detail View")
                .font(.headline)

            HStack {
                Text("Prefetch Count")
                Spacer()
                Picker("", selection: $prefetchCount) {
                    Text("Off").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("5").tag(5)
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Text("Number of photos to preload in each direction when browsing. Higher values use more memory.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("History Cache Count")
                Spacer()
                Picker("", selection: $cacheHistoryCount) {
                    Text("Off").tag(0)
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("20").tag(20)
                    Text("50").tag(50)
                }
                .labelsHidden()
                .frame(width: 150)
            }

            HStack {
                Text("History Memory Limit")
                Spacer()
                Picker("", selection: $cacheHistoryMemoryMB) {
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                    Text("Unlimited").tag(0)
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Text("Previously viewed photos are kept in memory for faster back-navigation. Limited by both count and memory.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // MARK: - Thumbnail Cache
            Text("Thumbnail Cache")
                .font(.headline)

            HStack {
                Text("Max Cache Size")
                Spacer()
                Picker("", selection: $cacheLimitMB) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                    Text("Unlimited").tag(0)
                }
                .labelsHidden()
                .frame(width: 150)
            }

            HStack {
                Text("Current Usage")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: currentCacheSize, countStyle: .file))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Clear Cache Now") {
                    Task {
                        await ThumbnailService.shared.clearCache()
                        ThumbnailCacheState.shared.invalidate()
                        currentCacheSize = await ThumbnailService.shared.diskCacheSize()
                    }
                }
            }
            Divider()

            // MARK: - Developer
            Text("Developer")
                .font(.headline)

            Toggle("Developer Mode", isOn: $developerMode)

            Text("Show color space conversion and HLG tone mapping controls in the toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 400)
        .task {
            currentCacheSize = await ThumbnailService.shared.diskCacheSize()
        }
    }
}
