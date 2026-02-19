import SwiftUI

struct CacheSidebarFooter: View {
    @AppStorage("prefetchCount") private var prefetchCount: Int = 2
    @AppStorage("cacheHistoryCount") private var cacheHistoryCount: Int = 10
    @AppStorage("cacheHistoryMemoryMB") private var cacheHistoryMemoryMB: Int = 1000
    @AppStorage("renderedCacheLimitMB") private var renderedCacheLimitMB: Int = 5000
    @AppStorage("thumbnailCacheLimitMB") private var thumbnailCacheLimitMB: Int = 500

    private var preloadCache: ImagePreloadCache { ImagePreloadCache.shared }
    @State private var renderedSize: Int64 = 0
    @State private var thumbSize: Int64 = 0
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    // MARK: In-Memory
                    groupHeader("In-Memory")
                    row("Usage", value: fmt(.memory, preloadCache.totalMemoryUsage))
                    pickerRow("Prefetch") {
                        Picker("", selection: $prefetchCount) {
                            Text("Off").tag(0)
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("3").tag(3)
                            Text("5").tag(5)
                        }
                    }
                    pickerRow("History") {
                        Picker("", selection: $cacheHistoryCount) {
                            Text("Off").tag(0)
                            Text("5").tag(5)
                            Text("10").tag(10)
                            Text("20").tag(20)
                            Text("50").tag(50)
                        }
                    }
                    pickerRow("Mem Limit") {
                        Picker("", selection: $cacheHistoryMemoryMB) {
                            Text("200 MB").tag(200)
                            Text("500 MB").tag(500)
                            Text("1 GB").tag(1000)
                            Text("2 GB").tag(2000)
                            Text("∞").tag(0)
                        }
                    }

                    // MARK: Rendered Cache
                    groupHeader("Rendered Cache")
                    usageRow(fmt(.file, renderedSize)) {
                        RenderedImageCache.shared.clearAll()
                    }
                    pickerRow("Limit") {
                        Picker("", selection: $renderedCacheLimitMB) {
                            Text("1 GB").tag(1000)
                            Text("2 GB").tag(2000)
                            Text("5 GB").tag(5000)
                            Text("10 GB").tag(10000)
                            Text("∞").tag(0)
                        }
                    }

                    // MARK: Thumbnails
                    groupHeader("Thumbnails")
                    usageRow(fmt(.file, thumbSize)) {
                        await ThumbnailService.shared.clearCache()
                        ThumbnailCacheState.shared.invalidate()
                    }
                    pickerRow("Limit") {
                        Picker("", selection: $thumbnailCacheLimitMB) {
                            Text("100 MB").tag(100)
                            Text("250 MB").tag(250)
                            Text("500 MB").tag(500)
                            Text("1 GB").tag(1000)
                            Text("2 GB").tag(2000)
                            Text("∞").tag(0)
                        }
                    }
                }
                .padding(.bottom, 8)
            } label: {
                Text("Cache")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            .padding(.horizontal, 10)
        .font(.caption)
        .task { await refreshSizes() }
        .onReceive(NotificationCenter.default.publisher(for: .renderedCacheSizeDidChange)) { _ in
            Task { await refreshSizes() }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func pickerRow<P: View>(_ label: String, @ViewBuilder picker: () -> P) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            picker()
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func usageRow(_ value: String, clearAction: @escaping () async -> Void) -> some View {
        HStack {
            Text("Usage").foregroundStyle(.secondary)
            Spacer()
            Text(value)
            Button("Clear") {
                Task {
                    await clearAction()
                    await refreshSizes()
                }
            }
            .controlSize(.mini)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private func fmt(_ style: ByteCountFormatter.CountStyle, _ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: style)
    }

    private func refreshSizes() async {
        renderedSize = await Task.detached { RenderedImageCache.shared.diskCacheSize() }.value
        thumbSize = await ThumbnailService.shared.diskCacheSize()
    }
}
