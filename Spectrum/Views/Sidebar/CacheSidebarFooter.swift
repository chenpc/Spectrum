import SwiftUI

struct CacheSidebarFooter: View {
    @AppStorage("thumbnailCacheLimitMB") private var thumbnailCacheLimitMB: Int = 500

    @State private var thumbSize: Int64 = 0
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
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
        thumbSize = await ThumbnailService.shared.diskCacheSize()
    }
}
