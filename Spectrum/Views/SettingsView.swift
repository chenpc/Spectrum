import SwiftUI

struct SettingsView: View {
    @AppStorage("thumbnailCacheLimitMB") private var cacheLimitMB: Int = 500
    @State private var currentCacheSize: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
        }
        .padding(20)
        .frame(width: 400)
        .task {
            currentCacheSize = await ThumbnailService.shared.diskCacheSize()
        }
    }
}
