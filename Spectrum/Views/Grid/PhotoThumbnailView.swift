import SwiftUI

class AspectFillImageView: NSView {
    let imageView: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.preferredImageDynamicRange = .high
        return iv
    }()

    /// HLG 縮圖的顯示路徑：直接把 CGImage 放上 layer（保留 itur_2100_HLG
    /// colorspace）+ EDR — 與 HLGNSView 同一套做法；NSImageView 路徑會被
    /// 系統 tone map 壓暗。toneMapMode 依內容型別在 setImage 決定。
    private let hlgView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.contentsGravity = .resizeAspect
        v.layer?.contentsFormat = .RGBA16Float
        return v
    }()

    private var usingHLG = false
    private var imageSize: NSSize = .zero
    /// false = aspect-fill（裁切填滿，grid 用）；true = aspect-fit（完整顯示，detail 預覽用）
    var fit = false
    /// 影片的 HDR 影格（Dolby Vision / HLG）：播放路徑（CAMetalLayer）走系統
    /// 預設 .automatic tone mapping，預覽縮圖必須一致，否則會比播放亮。
    /// .never 只適用於 scene-referred 的 HLG 照片。
    var isVideoContent = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(imageView)
        addSubview(hlgView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if let cg, let cs = cg.colorSpace, CGColorSpaceUsesITUR_2100TF(cs) {
            usingHLG = true
            hlgView.layer?.contents = cg
            if #available(macOS 15.0, *) {
                hlgView.layer?.toneMapMode = isVideoContent ? .automatic : .never
            }
            imageView.image = nil
            enableEDR()
        } else {
            usingHLG = false
            imageView.image = image
            hlgView.layer?.contents = nil
        }
        imageView.isHidden = usingHLG
        hlgView.isHidden = !usingHLG
        imageSize = image.size
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if usingHLG { enableEDR() }
    }

    private func enableEDR() {
        var current: CALayer? = hlgView.layer
        while let l = current {
            if #available(macOS 26.0, *) {
                l.preferredDynamicRange = .high
            } else {
                l.wantsExtendedDynamicRangeContent = true
            }
            current = l.superlayer
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        let active = usingHLG ? hlgView : imageView
        guard !fit,
              imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else {
            // fit：兩條路徑（NSImageView proportional / layer resizeAspect）
            // 都會自行 letterbox，把 frame 撐滿即可
            active.frame = bounds
            return
        }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        active.frame = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w,
            height: h
        )
    }
}

/// HDR-aware 縮圖顯示（aspect-fill）：HLG 縮圖走 CALayer+EDR+toneMapMode=.never，
/// 其餘走 NSImageView。SwiftUI `Image(nsImage:)` 沒有 EDR 路徑，HLG 會被壓暗。
struct HDRThumbnailImageView: NSViewRepresentable {
    let image: NSImage
    var fit = false
    /// true = 影片影格（tone mapping 需與播放路徑一致）
    var video = false

    func makeNSView(context: Context) -> AspectFillImageView {
        AspectFillImageView()
    }

    func updateNSView(_ nsView: AspectFillImageView, context: Context) {
        nsView.fit = fit
        nsView.isVideoContent = video
        nsView.setImage(image)
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
                HDRThumbnailImageView(image: displayThumbnail, video: item.isVideo)
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
