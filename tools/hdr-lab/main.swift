// hdr-lab — Sony HDR (HLG) 照片顯示實驗工具
//
// 用法: ./hdrlab <image path>
// 在同一張照片上即時切換多種渲染管線，A/B 比較亮度／色彩是否正確。
//
// 按鍵:
//   1-9, a-c   直接切換模式（9/a/b/c 為固定 .automatic、只換 colorspace 的對照組）
//   ← / →      循環切換模式
//   + / -      調整 EV（僅 Core Image 模式）
//   0          EV 歸零
//   h          顯示/隱藏 HUD
//   q / Esc    離開

import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Image loading variants

struct LoadedImages {
    let url: URL
    /// 原始解碼（保留檔案內的 colorspace，Spectrum 現況用的路徑）
    let original: CGImage
    /// ImageIO kCGImageSourceDecodeToHDR 解碼（ISO HDR 表示）
    let decodeToHDR: CGImage?
    /// NSImage（給 NSImageView 模式）
    let nsImage: NSImage
    /// CIImage expandToHDR
    let ciHDR: CIImage?
}

func describe(_ cg: CGImage?) -> String {
    guard let cg else { return "nil" }
    let csName = (cg.colorSpace?.name as String?) ?? "unknown"
    var s = "\(cg.width)x\(cg.height) \(cg.bitsPerComponent)bpc \(csName)"
    if #available(macOS 15.0, *) {
        s += String(format: " headroom=%.2f", cg.contentHeadroom)
    }
    return s
}

func loadImages(url: URL) -> LoadedImages? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        fputs("無法開啟 \(url.path)\n", stderr)
        return nil
    }
    guard let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fputs("無法解碼 \(url.path)\n", stderr)
        return nil
    }
    let hdrOpts: [CFString: Any] = [kCGImageSourceDecodeToHDR: true]
    let decoded = CGImageSourceCreateImageAtIndex(source, 0, hdrOpts as CFDictionary)

    let nsImage = NSImage(contentsOf: url) ?? NSImage(cgImage: original, size: .zero)
    let ciHDR = CIImage(contentsOf: url, options: [.expandToHDR: true])

    // 印出檔案資訊
    print("=== \(url.lastPathComponent) ===")
    print("original:    \(describe(original))")
    print("decodeToHDR: \(describe(decoded))")
    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        if let profile = props[kCGImagePropertyProfileName] { print("profile:     \(profile)") }
        if let depth = props[kCGImagePropertyDepth] { print("depth:       \(depth)") }
    }
    if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
        print("aux:         has HDR gain map")
    }
    if let cs = original.colorSpace {
        print("ITU-R 2100 TF: \(CGColorSpaceUsesITUR_2100TF(cs))")
    }
    return LoadedImages(url: url, original: original, decodeToHDR: decoded,
                        nsImage: nsImage, ciHDR: ciHDR)
}

// MARK: - Render modes

enum RenderMode: Int, CaseIterable {
    case layerOriginal = 1        // Spectrum 現況
    case layerToneMapNever        // toneMapMode = .never
    case layerToneMapIfSupported  // toneMapMode = .ifSupported
    case layerDecodeToHDR         // ImageIO ISO HDR 解碼
    case imageViewHigh            // NSImageView .high
    case imageViewConstrained     // NSImageView .constrainedHigh
    case ciExpand                 // CIImage expandToHDR + EV 可調
    case sdrBaseline              // 無 EDR（對照組）
    // —— 以下固定 toneMapMode=.automatic，只改變 colorspace／中繼資料 ——
    case autoPQ                   // 像素真轉換 → itur_2100_PQ
    case autoLinear               // 像素真轉換 → extendedLinearDisplayP3 float16
    case autoRealHeadroom         // 原始 HLG，contentHeadroom 改為實際內容峰值
    case autoReassignP3HLG        // 不轉像素，colorspace 重解讀為 displayP3_HLG

    var key: String {
        switch rawValue {
        case 1...9: return String(rawValue)
        case 10:    return "a"
        case 11:    return "b"
        default:    return "c"
        }
    }

    var title: String {
        switch self {
        case .layerOriginal:      return "1 CALayer+EDR 原始 CGImage（Spectrum 現況）"
        case .layerToneMapNever:  return "2 CALayer+EDR toneMapMode=.never"
        case .layerToneMapIfSupported: return "3 CALayer+EDR toneMapMode=.ifSupported"
        case .layerDecodeToHDR:   return "4 CALayer+EDR ImageIO decodeToHDR"
        case .imageViewHigh:      return "5 NSImageView dynamicRange=.high"
        case .imageViewConstrained: return "6 NSImageView dynamicRange=.constrainedHigh"
        case .ciExpand:           return "7 CIImage expandToHDR → linear P3（+/- 調 EV）"
        case .sdrBaseline:        return "8 SDR baseline（無 EDR）"
        case .autoPQ:             return "9 .automatic + 像素轉換 → PQ (itur_2100_PQ)"
        case .autoLinear:         return "a .automatic + 像素轉換 → extendedLinearDisplayP3"
        case .autoRealHeadroom:   return "b .automatic + HLG 原圖 contentHeadroom=實際峰值"
        case .autoReassignP3HLG:  return "c .automatic + colorspace 重解讀 displayP3_HLG"
        }
    }
}

// MARK: - Layer-backed image view

final class LayerImageView: NSView {
    private let enableEDR: Bool
    init(cgImage: CGImage, edr: Bool, toneMap: String?) {
        self.enableEDR = edr
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.contentsFormat = .RGBA16Float
        layer?.contents = cgImage
        if edr { setEDR(layer!) }
        if #available(macOS 15.0, *), let toneMap {
            switch toneMap {
            case "never":       layer?.toneMapMode = .never
            case "ifSupported": layer?.toneMapMode = .ifSupported
            default:            layer?.toneMapMode = .automatic
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard enableEDR else { return }
        var current = layer
        while let l = current { setEDR(l); current = l.superlayer }
    }
    private func setEDR(_ l: CALayer) {
        if #available(macOS 26.0, *) {
            l.preferredDynamicRange = .high
        } else {
            l.wantsExtendedDynamicRangeContent = true
        }
    }
}

// MARK: - Main view controller

final class HDRLabController: NSObject {
    let images: LoadedImages
    let window: NSWindow
    let container = NSView()
    let hud = NSTextField(labelWithString: "")
    var mode: RenderMode = .layerOriginal
    var ev: Double = 0
    var currentContent: NSView?
    let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(images: LoadedImages) {
        self.images = images
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "hdr-lab — \(images.url.lastPathComponent)"
        window.contentView = container
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        hud.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        hud.textColor = .white
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        hud.drawsBackground = true
        hud.translatesAutoresizingMaskIntoConstraints = false

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        apply()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers {
        case "q": NSApp.terminate(nil); return true
        case "h": hud.isHidden.toggle(); return true
        case "a": mode = .autoLinear; apply(); return true
        case "b": mode = .autoRealHeadroom; apply(); return true
        case "c": mode = .autoReassignP3HLG; apply(); return true
        case "+", "=": ev += 0.25; apply(); return true
        case "-": ev -= 0.25; apply(); return true
        case "0": ev = 0; apply(); return true
        case let c? where c.count == 1 && ("1"..."9").contains(c):
            if let m = RenderMode(rawValue: Int(c)!) { mode = m; apply() }
            return true
        default: break
        }
        switch event.keyCode {
        case 53: NSApp.terminate(nil); return true               // Esc
        case 123: cycle(-1); return true                          // ←
        case 124: cycle(1); return true                           // →
        default: return false
        }
    }

    func cycle(_ dir: Int) {
        let all = RenderMode.allCases
        let idx = all.firstIndex(of: mode)!
        mode = all[(idx + dir + all.count) % all.count]
        apply()
    }

    func makeContentView() -> NSView {
        switch mode {
        case .layerOriginal:
            return LayerImageView(cgImage: images.original, edr: true, toneMap: nil)
        case .layerToneMapNever:
            return LayerImageView(cgImage: images.original, edr: true, toneMap: "never")
        case .layerToneMapIfSupported:
            return LayerImageView(cgImage: images.original, edr: true, toneMap: "ifSupported")
        case .layerDecodeToHDR:
            let img = images.decodeToHDR ?? images.original
            return LayerImageView(cgImage: img, edr: true, toneMap: nil)
        case .imageViewHigh, .imageViewConstrained:
            let v = NSImageView()
            v.image = images.nsImage
            v.imageScaling = .scaleProportionallyUpOrDown
            v.preferredImageDynamicRange = (mode == .imageViewHigh) ? .high : .constrainedHigh
            return v
        case .ciExpand:
            guard var ci = images.ciHDR else {
                return LayerImageView(cgImage: images.original, edr: true, toneMap: nil)
            }
            if ev != 0 {
                let f = CIFilter(name: "CIExposureAdjust")!
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(ev, forKey: kCIInputEVKey)
                ci = f.outputImage ?? ci
            }
            let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            if let cg = ciContext.createCGImage(ci, from: ci.extent,
                                                format: .RGBAh, colorSpace: cs) {
                return LayerImageView(cgImage: cg, edr: true, toneMap: nil)
            }
            return LayerImageView(cgImage: images.original, edr: true, toneMap: nil)
        case .sdrBaseline:
            return LayerImageView(cgImage: images.original, edr: false, toneMap: nil)
        case .autoPQ:
            guard let cg = pqImage else { return fallbackView() }
            return LayerImageView(cgImage: cg, edr: true, toneMap: nil)
        case .autoLinear:
            guard let cg = linearImage else { return fallbackView() }
            return LayerImageView(cgImage: cg, edr: true, toneMap: nil)
        case .autoRealHeadroom:
            guard let cg = realHeadroomImage else { return fallbackView() }
            return LayerImageView(cgImage: cg, edr: true, toneMap: nil)
        case .autoReassignP3HLG:
            guard let cg = p3hlgImage else { return fallbackView() }
            return LayerImageView(cgImage: cg, edr: true, toneMap: nil)
        }
    }

    func fallbackView() -> NSView {
        print("[warn] 該模式的影像轉換失敗，退回原始 CGImage")
        return LayerImageView(cgImage: images.original, edr: true, toneMap: nil)
    }

    // MARK: - Colorspace 變體（固定 .automatic tone mapping 用）

    /// 像素真轉換 → PQ。PQ 是 display-referred（絕對亮度），.automatic 對它的
    /// tone mapping 語意和 HLG 不同 — 分辨「automatic 對 HLG 的解讀」是否為問題所在。
    lazy var pqImage: CGImage? = {
        guard let ci = images.ciHDR,
              let cs = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else { return nil }
        let cg = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA16, colorSpace: cs)
        print("[convert] PQ: \(describe(cg))")
        return cg
    }()

    /// 像素真轉換 → extended linear float16（無傳輸函數，值直接是相對 SDR 白的倍數）
    lazy var linearImage: CGImage? = {
        guard let ci = images.ciHDR,
              let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        let cg = ciContext.createCGImage(ci, from: ci.extent, format: .RGBAh, colorSpace: cs)
        print("[convert] linear: \(describe(cg))")
        return cg
    }()

    /// 原始 HLG 像素不動，只把 contentHeadroom 從名義值 4.93 改成實際內容峰值 —
    /// 檢驗 .automatic 壓暗是否因為「以名義 headroom 對映、但內容根本沒那麼亮」。
    lazy var realHeadroomImage: CGImage? = {
        guard #available(macOS 15.0, *), let peak = actualHeadroom else { return nil }
        // API 要求 headroom == 0（未知）或 >= 1.0
        let cg = CGImageCreateCopyWithContentHeadroom(max(1.0, peak), images.original)
        print("[convert] realHeadroom=\(String(format: "%.2f", peak)): \(describe(cg))")
        return cg
    }()

    /// 不轉像素，colorspace 重新解讀為 displayP3_HLG（不同 primaries、同 HLG TF）
    lazy var p3hlgImage: CGImage? = {
        guard let cs = CGColorSpace(name: CGColorSpace.displayP3_HLG) else { return nil }
        let cg = images.original.copy(colorSpace: cs)
        print("[convert] reassign P3-HLG: \(describe(cg))")
        return cg
    }()

    /// 實際內容峰值（linear、相對 SDR 白）— CIAreaMaximum 掃全圖
    lazy var actualHeadroom: Float? = {
        guard let ci = images.ciHDR,
              let f = CIFilter(name: "CIAreaMaximum", parameters: [
                  kCIInputImageKey: ci,
                  kCIInputExtentKey: CIVector(cgRect: ci.extent)
              ]),
              let out = f.outputImage,
              let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        var pix = [Float](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &pix, rowBytes: 16,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBAf, colorSpace: cs)
        let peak = max(pix[0], max(pix[1], pix[2]))
        print(String(format: "[measure] 實際內容峰值 = %.3f × SDR 白（名義 HLG headroom = 4.93）", peak))
        return peak
    }()

    func apply() {
        currentContent?.removeFromSuperview()
        hud.removeFromSuperview()

        let content = makeContentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        container.addSubview(hud)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hud.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            hud.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        currentContent = content

        let screen = window.screen ?? NSScreen.main
        let edrNow = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        let edrPot = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        var text = mode.title
        text += String(format: "\nEDR now=%.2f potential=%.2f", edrNow, edrPot)
        if mode == .ciExpand { text += String(format: "  EV=%+.2f", ev) }
        hud.stringValue = text
        print("[mode] \(mode.title)  EDR now=\(String(format: "%.2f", edrNow))"
              + (mode == .ciExpand ? String(format: "  EV=%+.2f", ev) : ""))
    }
}

// MARK: - App bootstrap

setvbuf(stdout, nil, _IONBF, 0)   // pipe 下也即時輸出診斷行

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("用法: hdrlab <image path>\n", stderr)
    exit(1)
}
let url = URL(fileURLWithPath: args[1])
guard let images = loadImages(url: url) else { exit(1) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = HDRLabController(images: images)
app.activate(ignoringOtherApps: true)
app.run()
