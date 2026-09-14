import SwiftUI

/// Dolby Vision 影片的預覽影格。DV 播放時切到 AVPlayerLayer（系統套用 RPU
/// tone mapping），但 iPhone DV（P8.4）的 base layer 也是 HLG，影格 colorspace
/// 無法與 Sony HLG 區分——由 ThumbnailService 讀格式描述後以此子類別標記。
final class DolbyVisionFrameImage: NSImage {}

/// HDR 縮圖的 tone mapping 決策：預覽亮度必須與該內容實際的渲染路徑一致。
enum ThumbnailToneMapping {
    enum Mode: Equatable { case automatic, never }

    static func mode(colorSpaceName: String?, isVideo: Bool, isDolbyVision: Bool) -> Mode {
        if isVideo {
            // DV → AVPlayerLayer，系統依 RPU tone map；其他 HDR 影片（HLG / HDR10）
            // → AVFMetalView 的 CAMetalLayer 直出，未設 edrMetadata，系統不做 tone mapping
            return isDolbyVision ? .automatic : .never
        }
        // 照片：HLG 是 scene-referred，.automatic 會壓暗；PQ（display-referred）
        // 依 contentHeadroom 對映
        let isHLG = colorSpaceName?.contains("HLG") ?? false
        return isHLG ? .never : .automatic
    }
}

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
    /// 影片影格：tone mapping 依播放渲染器決定（見 ThumbnailToneMapping）——
    /// Dolby Vision 走 AVPlayerLayer（.automatic），其他 HDR 影片走 CAMetalLayer
    /// 直出（.never）。
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
                // 預覽匹配實際渲染路徑（規則見 ThumbnailToneMapping）
                let mode = ThumbnailToneMapping.mode(
                    colorSpaceName: cs.name as String?,
                    isVideo: isVideoContent,
                    isDolbyVision: image is DolbyVisionFrameImage
                )
                hlgView.layer?.toneMapMode = mode == .automatic ? .automatic : .never
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

/// HDR-aware 縮圖顯示（aspect-fill）：HDR 縮圖走 CALayer+EDR（toneMapMode 見
/// ThumbnailToneMapping），其餘走 NSImageView。SwiftUI `Image(nsImage:)` 沒有
/// EDR 路徑，HLG 會被壓暗。
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
    @State private var isHDR = false
    /// grid 的 PhotoItem 不含 duration，改由 ThumbnailService 生成影片縮圖時記錄
    @State private var videoDuration: Double?
    @Environment(\.thumbnailCacheState) private var cacheState

    private var displayThumbnail: NSImage? {
        guard let thumbnail else { return nil }
        let composite = item.compositeEdit
        guard composite.crop != nil else { return thumbnail }
        guard let cg = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return thumbnail }
        if let crop = composite.crop {
            let pixelRect = crop.pixelRect(imageWidth: cg.width, imageHeight: cg.height)
            if let cropped = cg.cropping(to: pixelRect) { return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)) }
        }
        return thumbnail
    }

    private var thumbnailRotation: Double {
        Double(item.compositeEdit.rotation)
    }

    private var thumbnailFlipH: Bool {
        item.compositeEdit.flipH
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let displayThumbnail {
                HDRThumbnailImageView(image: displayThumbnail, video: item.isVideo)
                    .frame(minWidth: 150, minHeight: 150)
                    .frame(height: 150)
                    .scaleEffect(x: thumbnailFlipH ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(thumbnailRotation))
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

                if let duration = item.duration ?? videoDuration {
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

            HStack(spacing: 4) {
                if isHDR {
                    Text("HDR")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(.white.opacity(0.8), lineWidth: 1)
                        )
                }
                if !item.isVideo, item.livePhotoMovPath != nil {
                    Image(systemName: "livephoto")
                        .font(.body)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .padding(4)
                        .background(.black.opacity(0.4), in: Circle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(6)

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
            isHDR = ThumbnailService.shared.isHDR(for: item.filePath)
            if item.isVideo {
                videoDuration = ThumbnailService.shared.duration(for: item.filePath)
            }
        }
    }
}
