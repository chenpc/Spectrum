import SwiftUI
import SwiftData

private class AspectFillImageView: NSView {
    let imageView: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.preferredImageDynamicRange = .high
        return iv
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0
        else {
            imageView.frame = bounds
            return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        imageView.frame = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w,
            height: h
        )
    }
}

private struct HDRThumbnailImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> AspectFillImageView {
        AspectFillImageView()
    }

    func updateNSView(_ nsView: AspectFillImageView, context: Context) {
        nsView.imageView.image = image
        nsView.needsLayout = true
    }
}

struct PhotoThumbnailView: View {
    let photo: Photo
    var isSelected: Bool = false
    var folderBookmarkData: Data? = nil

    @State private var thumbnail: NSImage?
    @Environment(\.thumbnailCacheState) private var cacheState
    @Query private var folders: [ScannedFolder]

    private var bookmarkData: Data? {
        if let folderBookmarkData { return folderBookmarkData }
        return photo.resolveBookmarkData(from: folders)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail {
                HDRThumbnailImageView(image: thumbnail)
                    .frame(minWidth: 150, minHeight: 150)
                    .frame(height: 150)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 150)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
            }

            if photo.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let duration = photo.duration {
                    Text(formatDuration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
            }

        }
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .task(id: photo.filePath + "\(cacheState.generation)") {
            thumbnail = nil
            if let image = await ThumbnailService.shared.thumbnail(for: photo.filePath, bookmarkData: bookmarkData) {
                thumbnail = image
            }
        }
    }
}
