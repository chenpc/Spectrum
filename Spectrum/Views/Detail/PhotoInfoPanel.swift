import SwiftUI
import SwiftData

struct PhotoInfoPanel: View {
    @Bindable var photo: Photo
    var isHDR: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var newTagName = ""

    var body: some View {
        Form {
            Section("File") {
                LabeledContent("Name", value: photo.fileName)
                LabeledContent("Path", value: photo.filePath)
                LabeledContent("Size", value: formatFileSize(photo.fileSize))
                LabeledContent("Dimensions", value: "\(photo.pixelWidth) x \(photo.pixelHeight)")
                LabeledContent("Date Taken", value: photo.dateTaken.shortDate)
                if isHDR {
                    LabeledContent("Dynamic Range") {
                        Text("HDR")
                            .foregroundStyle(.orange)
                            .fontWeight(.semibold)
                    }
                }
            }

            if photo.isVideo {
                Section("Video") {
                    if let duration = photo.duration {
                        LabeledContent("Duration", value: formatDuration(duration))
                    }
                    if let codec = photo.videoCodec {
                        LabeledContent("Video Codec", value: codec)
                    }
                    if let codec = photo.audioCodec {
                        LabeledContent("Audio Codec", value: codec)
                    }
                }
            } else {
                Section("Camera") {
                    if let make = photo.cameraMake {
                        LabeledContent("Make", value: make)
                    }
                    if let model = photo.cameraModel {
                        LabeledContent("Model", value: model)
                    }
                    if let lens = photo.lensModel {
                        LabeledContent("Lens", value: lens)
                    }
                }

                Section("Exposure") {
                    if let aperture = photo.aperture {
                        LabeledContent("Aperture", value: String(format: "f/%.1f", aperture))
                    }
                    if let shutter = photo.shutterSpeed {
                        LabeledContent("Shutter", value: shutter)
                    }
                    if let iso = photo.iso {
                        LabeledContent("ISO", value: "\(iso)")
                    }
                    if let focal = photo.focalLength {
                        LabeledContent("Focal Length", value: String(format: "%.0fmm", focal))
                    }
                }
            }

            if photo.latitude != nil || photo.longitude != nil {
                Section("Location") {
                    if let lat = photo.latitude, let lon = photo.longitude {
                        LabeledContent("Coordinates", value: String(format: "%.4f, %.4f", lat, lon))
                    }
                }
            }

            Section("Tags") {
                FlowLayout(spacing: 4) {
                    ForEach(photo.tags) { tag in
                        TagChip(name: tag.name) {
                            photo.tags.removeAll { $0.persistentModelID == tag.persistentModelID }
                        }
                    }
                }

                HStack {
                    TextField("Add tag...", text: $newTagName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTag() }
                    Button("Add") { addTag() }
                        .disabled(newTagName.isEmpty)
                }
            }

        }
        .formStyle(.grouped)
        .frame(minWidth: 250)
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let existing = allTags.first { $0.name.lowercased() == name.lowercased() }
        let tag = existing ?? Tag(name: name)

        if existing == nil {
            modelContext.insert(tag)
        }

        if !photo.tags.contains(where: { $0.persistentModelID == tag.persistentModelID }) {
            photo.tags.append(tag)
        }

        newTagName = ""
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct TagChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(name)
                .font(.caption)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
