import SwiftUI

// MARK: - HDR NSImageView wrapper

private class FlexibleImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override var acceptsFirstResponder: Bool { false }
}

struct HDRImageView: NSViewRepresentable {
    let image: NSImage
    let dynamicRange: NSImage.DynamicRange

    func makeNSView(context: Context) -> NSImageView {
        let view = FlexibleImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = false
        view.isEditable = false
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = image
        nsView.preferredImageDynamicRange = dynamicRange
    }
}

// MARK: - HLG CALayer image view (mpv-style: explicit itur_2100_HLG colorspace + EDR hierarchy)

class HLGNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.contentsFormat = .RGBA16Float
        // 預設的 .automatic tone mapping 會把 HLG 內容壓暗（依 contentHeadroom
        // 重新對映亮度）；HLG 本身就是相容 EDR 的 scene-referred 編碼，
        // 直接交給顯示器呈現才是正確亮度 — 經 tools/hdr-lab A/B 比較確認。
        if #available(macOS 15.0, *) {
            layer?.toneMapMode = .never
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(cgImage: CGImage) {
        layer?.contents = cgImage
        enableEDR()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enableEDR()
    }

    private func enableEDR() {
        setEDRDown(layer)
        var current = layer?.superlayer
        while let l = current { setEDR(l); current = l.superlayer }
    }

    private func setEDR(_ l: CALayer) {
        if #available(macOS 26.0, *) {
            l.preferredDynamicRange = .high
        } else {
            l.wantsExtendedDynamicRangeContent = true
        }
    }

    private func setEDRDown(_ l: CALayer?) {
        guard let l else { return }
        setEDR(l)
        l.sublayers?.forEach { setEDRDown($0) }
    }
}

struct HLGImageView: NSViewRepresentable {
    let cgImage: CGImage

    func makeNSView(context: Context) -> HLGNSView { HLGNSView() }

    func updateNSView(_ nsView: HLGNSView, context: Context) { nsView.configure(cgImage: cgImage) }

}

