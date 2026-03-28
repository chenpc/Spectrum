import SwiftUI

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
    let item: PhotoItem
    var isSelected: Bool = false
    var folderBookmarkData: Data? = nil

    @State private var thumbnail: NSImage?
    @Environment(\.thumbnailCacheState) private var cacheState

    private var displayThumbnail: NSImage? {
        guard let thumbnail else { return nil }
        let composite = item.compositeEdit
        guard composite.rotation != 0 || composite.flipH || composite.crop != nil else { return thumbnail }
        guard var cg = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return thumbnail }
        if composite.flipH, let flipped = flipCGImage(cg, horizontal: true) { cg = flipped }
        if composite.rotation != 0, let rotated = rotateCGImage(cg, degrees: composite.rotation) { cg = rotated }
        if let crop = composite.crop {
            let pixelRect = crop.pixelRect(imageWidth: cg.width, imageHeight: cg.height)
            if let cropped = cg.cropping(to: pixelRect) { cg = cropped }
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let displayThumbnail {
                HDRThumbnailImageView(image: displayThumbnail)
                    .frame(minWidth: 150, minHeight: 150)
                    .frame(height: 150)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 150)
            }

            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let duration = item.duration {
                    Text(formatDuration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
            } else if item.livePhotoMovPath != nil {
                Image(systemName: "livephoto")
                    .font(.body)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3)
                    .padding(4)
                    .background(.black.opacity(0.4), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
            }

            let ext = URL(fileURLWithPath: item.filePath).pathExtension.uppercased()
            if !ext.isEmpty {
                Text(ext)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    .padding(6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .onDrag {
            NSItemProvider(object: URL(fileURLWithPath: item.filePath) as NSURL)
        }
        .task(id: item.filePath + "\(cacheState.generation)") {
            if let cached = ThumbnailService.shared.cachedThumbnail(for: item.filePath) {
                thumbnail = cached
            } else {
                thumbnail = await ThumbnailService.shared.thumbnail(for: item.filePath, bookmarkData: folderBookmarkData)
            }
        }
    }
}
