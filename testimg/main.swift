// testimg — Minimal HDR image display test tool
// Usage: ./testimg <image_path>
//
// Displays a single image with HDR format detection and multiple rendering modes.
// Press 1-9 to switch modes, H to toggle HDR, Q to quit.

import Cocoa
import CoreGraphics
import ImageIO

// MARK: - HDR Format Detection

enum HDRFormat: String {
    case gainMap = "Gain Map"
    case hlg     = "HLG"
    case sdr     = "SDR"
}

func detectHDR(url: URL) -> (format: HDRFormat, cgImage: CGImage?, colorSpace: CGColorSpace?) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return (.sdr, nil, nil)
    }
    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    let cs = cgImage?.colorSpace

    // 1. HLG: ITU-R 2100 transfer function
    if let cs, CGColorSpaceUsesITUR_2100TF(cs) {
        return (.hlg, cgImage, cs)
    }

    // 2. Gain Map: auxiliary HDR gain map data
    let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
    if gainMap != nil {
        return (.gainMap, cgImage, cs)
    }

    // 2b. Gain Map: older iPhone EXIF CustomRendered=3
    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
       let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
       let cr = exif[kCGImagePropertyExifCustomRendered as String] as? Int, cr == 3 {
        return (.gainMap, cgImage, cs)
    }

    return (.sdr, cgImage, cs)
}

// MARK: - Color Space Reinterpretation

/// Reinterpret pixel data with a different color space.
/// Normalizes packed formats (e.g. 10-10-10-2) to standard 16bpc first,
/// then re-labels with the target color space (no color conversion).
func reinterpretColorSpace(_ image: CGImage, as cs: CGColorSpace) -> CGImage? {
    let w = image.width, h = image.height

    // Step 1: Render into standard 16bpc layout using the ORIGINAL color space.
    // This unpacks any packed/compressed pixel format into plain 16-bit components.
    let origCS = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let bpr = w * 8  // 4 components × 16 bits = 8 bytes/pixel
    let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Big.rawValue
                                    | CGImageAlphaInfo.noneSkipLast.rawValue)
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 16, bytesPerRow: bpr,
        space: origCS, bitmapInfo: info.rawValue
    ) else {
        print("  reinterpret: failed to create 16bpc context")
        return nil
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Step 2: Extract normalized pixels and create new CGImage with ICC space.
    guard let normalized = ctx.makeImage(),
          let provider = normalized.dataProvider else { return nil }

    let result = CGImage(
        width: w, height: h,
        bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bpr,
        space: cs,
        bitmapInfo: info,
        provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
    if result != nil {
        print("  reinterpret: \(image.bitsPerComponent)bpc/\(image.bitsPerPixel)bpp → 16bpc/64bpp, CS: \((cs.name as String?) ?? "icc")")
        print("  reinterpret: wide gamut: \(cs.isWideGamutRGB), ITU-R 2100: \(CGColorSpaceUsesITUR_2100TF(cs))")
    }
    return result
}

// MARK: - Rendering Modes

enum RenderMode: Int, CaseIterable {
    case auto        = 1  // HDR format-appropriate rendering
    case calayer     = 2  // Raw CGImage via CALayer (HLG-style)
    case nsImageView = 3  // NSImageView with dynamicRange
    case ciContext   = 4  // CIImage manual render
    case hlgCALayer  = 5  // Reinterpret as HLG → CALayer + EDR
    case hlgNSImage  = 6  // Reinterpret as HLG → NSImageView
    case mpv         = 7  // libmpv rendering
    case ffmpegMetal = 8  // FFmpeg decode + Metal HLG shader
    case placebo     = 9  // libplacebo offscreen tone mapping

    var label: String {
        switch self {
        case .auto:        return "Auto (format-appropriate)"
        case .calayer:     return "CALayer + CGImage"
        case .nsImageView: return "NSImageView + dynamicRange"
        case .ciContext:   return "CIImage manual"
        case .hlgCALayer:  return "→HLG reinterpret + CALayer"
        case .hlgNSImage:  return "→HLG reinterpret + NSImageView"
        case .mpv:         return "libmpv"
        case .ffmpegMetal: return "FFmpeg + Metal HLG"
        case .placebo:     return "libplacebo tone map"
        }
    }
}

// MARK: - CALayer Image View (HLG-style)

class CALayerImageView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(cgImage: CGImage, edr: Bool) {
        layer?.contents = cgImage
        setEDR(edr)
    }

    func setEDR(_ on: Bool) {
        func apply(_ l: CALayer) {
            if #available(macOS 26.0, *) {
                l.preferredDynamicRange = on ? .high : .standard
            } else {
                l.wantsExtendedDynamicRangeContent = on
            }
        }
        if let l = layer { apply(l) }
        var current = layer?.superlayer
        while let l = current { apply(l); current = l.superlayer }
    }
}

// MARK: - CIImage Render View

class CIImageView: NSView {
    private var ciImage: CIImage?
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(cgImage: CGImage, edr: Bool) {
        ciImage = CIImage(cgImage: cgImage)
        if #available(macOS 26.0, *) {
            layer?.preferredDynamicRange = edr ? .high : .standard
        } else {
            layer?.wantsExtendedDynamicRangeContent = edr
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ci = ciImage,
              let cgCtx = NSGraphicsContext.current?.cgContext else { return }
        guard let rendered = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let aspect = ci.extent.width / ci.extent.height
        let viewAspect = bounds.width / bounds.height
        var drawRect: CGRect
        if aspect > viewAspect {
            let h = bounds.width / aspect
            drawRect = CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * aspect
            drawRect = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
        cgCtx.draw(rendered, in: drawRect)
    }
}

// MARK: - Flexible NSImageView (no intrinsic size, lets AutoLayout control bounds)

class FlexibleImageView: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width: -1, height: -1) }
}

// MARK: - Main Window

class ImageWindow: NSWindow {
    let url: URL
    let hdrFormat: HDRFormat
    let cgImage: CGImage?
    let imgColorSpace: CGColorSpace?
    let nsImage: NSImage?

    // HLG reinterpretation (force system kCGColorSpaceITUR_2100_HLG)
    let hlgCGImage: CGImage?
    let hlgNSImage: NSImage?

    var showHDR = true
    var mode: RenderMode = .auto

    let calayerView = CALayerImageView(frame: .zero)
    let imageView = FlexibleImageView(frame: .zero)
    let ciView = CIImageView(frame: .zero)
    let mpvView = MPVImageView(frame: .zero)
    let metalView = MetalHLGView(frame: .zero)
    let placeboView = PlaceboRenderView(frame: .zero)
    let statusLabel = NSTextField(labelWithString: "")

    // Lazy pixel decode (shared between mode 8 and 9)
    private var _ffmpegDecoded: DecodedImageData?
    private var ffmpegDecodeAttempted = false

    // Temp TIFF export for Mode 7 (mpv can't handle HEIF grid directly)
    private var _tempTIFFPath: String?

    // Placebo-filtered CGImage for Mode 1 (auto) HLG enhancement
    private lazy var placeboFilteredImage: CGImage? = {
        guard hdrFormat == .hlg, let cg = cgImage else { return nil }
        print("[placebo-filter] applying to \(cg.width)×\(cg.height)...")
        let result = applyPlaceboFilter(cg)
        if result != nil { print("[placebo-filter] done") }
        else { print("[placebo-filter] failed, using original") }
        return result
    }()



    init(url: URL) {
        self.url = url
        let det = detectHDR(url: url)
        self.hdrFormat = det.format
        self.cgImage = det.cgImage
        self.imgColorSpace = det.colorSpace
        self.nsImage = NSImage(contentsOf: url)

        // Create HLG-reinterpreted images (force system kCGColorSpaceITUR_2100_HLG)
        let hlgCS = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        if let cg = det.cgImage, let reinterpreted = reinterpretColorSpace(cg, as: hlgCS) {
            self.hlgCGImage = reinterpreted
            let size = NSSize(width: cg.width, height: cg.height)
            let img = NSImage(size: size)
            img.addRepresentation(NSBitmapImageRep(cgImage: reinterpreted))
            self.hlgNSImage = img
        } else {
            self.hlgCGImage = nil
            self.hlgNSImage = nil
        }

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let w: CGFloat = min(1200, screen.width * 0.7)
        let h: CGFloat = min(900, screen.height * 0.7)
        let rect = NSRect(x: (screen.width - w) / 2, y: (screen.height - h) / 2, width: w, height: h)

        super.init(contentRect: rect,
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)

        title = "testimg"
        minSize = NSSize(width: 400, height: 300)

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        contentView = container

        // Setup subviews
        for v in [calayerView, imageView, ciView, mpvView, metalView, placeboView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: container.topAnchor, constant: 32),
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .labelColor
        statusLabel.backgroundColor = .windowBackgroundColor
        statusLabel.isBezeled = false
        statusLabel.isEditable = false
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            statusLabel.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Global key monitor — always works regardless of first responder
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleKey(event) { return nil }
            return event
        }

        applyMode()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers else { return false }
        switch chars {
        case "1": mode = .auto;        applyMode(); return true
        case "2": mode = .calayer;     applyMode(); return true
        case "3": mode = .nsImageView; applyMode(); return true
        case "4": mode = .ciContext;    applyMode(); return true
        case "5": mode = .hlgCALayer;  applyMode(); return true
        case "6": mode = .hlgNSImage;  applyMode(); return true
        case "7": mode = .mpv;         applyMode(); return true
        case "8": mode = .ffmpegMetal; applyMode(); return true
        case "9": mode = .placebo;     applyMode(); return true
        case "h", "H": showHDR.toggle(); applyMode(); return true
        case "q", "Q": NSApp.terminate(nil); return true
        // Zoom/pan for Mode 7 (mpv)
        case "+", "=": mpvView.adjustZoom(delta: 0.25); return true
        case "-", "_": mpvView.adjustZoom(delta: -0.25); return true
        case "0":      mpvView.resetZoom(); return true
        default:
            // Arrow keys for panning
            if mode == .mpv {
                switch event.keyCode {
                case 123: mpvView.adjustPan(dx: -0.05, dy: 0); return true  // left
                case 124: mpvView.adjustPan(dx: 0.05, dy: 0); return true   // right
                case 126: mpvView.adjustPan(dx: 0, dy: -0.05); return true  // up
                case 125: mpvView.adjustPan(dx: 0, dy: 0.05); return true   // down
                default: break
                }
            }
            return false
        }
    }

    private func ensureFFmpegDecoded() {
        guard !ffmpegDecodeAttempted else { return }
        ffmpegDecodeAttempted = true

        // Try CGImage extraction first — handles HEIF grid assembly correctly
        if let cg = cgImage {
            print("[decode] extracting from CGImage \(cg.width)×\(cg.height)...")
            _ffmpegDecoded = decodedDataFromCGImage(cg)
            if let d = _ffmpegDecoded {
                print("[decode] extracted: \(d.width)×\(d.height)")
                return
            }
            print("[decode] CGImage extraction failed, falling back to FFmpeg")
        }

        // Fallback: FFmpeg decode (may only get a single tile for HEIF grid files)
        print("[ffmpeg] decoding \(url.path)...")
        _ffmpegDecoded = ffmpegDecodeHEIF(url: url)
        if let d = _ffmpegDecoded {
            print("[ffmpeg] decoded: \(d.width)×\(d.height)")
        }
    }

    /// Export CGImage as temp 16-bit TIFF for Mode 7 (mpv can't handle HEIF grid directly)
    private func ensureTempTIFF() -> String? {
        if let p = _tempTIFFPath { return p }
        guard let cg = cgImage else { return nil }

        let tmpDir = NSTemporaryDirectory()
        let tmpPath = (tmpDir as NSString).appendingPathComponent("testimg_mpv_\(ProcessInfo.processInfo.processIdentifier).tiff")

        let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: tmpPath) as CFURL,
            "public.tiff" as CFString, 1, nil)
        guard let dest else {
            print("[temp] failed to create TIFF destination")
            return nil
        }
        // Preserve original color space and use 16bpc
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            print("[temp] failed to finalize TIFF")
            return nil
        }

        print("[temp] exported \(cg.width)×\(cg.height) TIFF → \(tmpPath)")
        _tempTIFFPath = tmpPath
        return tmpPath
    }

    func applyMode() {
        let effectiveMode: RenderMode
        switch mode {
        case .auto:
            effectiveMode = (hdrFormat == .hlg) ? .calayer : .nsImageView
        default:
            effectiveMode = mode
        }

        let useCALayer = effectiveMode == .calayer || effectiveMode == .hlgCALayer
        let useNSImage = effectiveMode == .nsImageView || effectiveMode == .hlgNSImage
        let useCIView  = effectiveMode == .ciContext
        let useMPV     = effectiveMode == .mpv
        let useMetal   = effectiveMode == .ffmpegMetal
        let usePlacebo = effectiveMode == .placebo

        calayerView.isHidden = !useCALayer
        imageView.isHidden   = !useNSImage
        ciView.isHidden      = !useCIView
        mpvView.isHidden     = !useMPV
        metalView.isHidden   = !useMetal
        placeboView.isHidden = !usePlacebo

        let isHLGReinterpret = effectiveMode == .hlgCALayer || effectiveMode == .hlgNSImage

        if useCALayer {
            let img: CGImage?
            if mode == .auto && hdrFormat == .hlg {
                // Mode 1 + HLG: use placebo-filtered image for best quality
                img = placeboFilteredImage ?? cgImage
            } else {
                img = (isHLGReinterpret ? hlgCGImage : nil) ?? cgImage
            }
            if let img { calayerView.configure(cgImage: img, edr: showHDR) }
        } else if useNSImage {
            let img = (isHLGReinterpret ? hlgNSImage : nil) ?? nsImage
            imageView.image = img
            imageView.preferredImageDynamicRange = showHDR ? .high : .standard
        } else if useCIView {
            if let cg = cgImage { ciView.configure(cgImage: cg, edr: showHDR) }
        } else if useMPV {
            // Use temp TIFF for HEIF grid files (mpv can't assemble grid tiles)
            let mpvPath = ensureTempTIFF() ?? url.path
            mpvView.loadImage(path: mpvPath)
            mpvView.applyHDR(on: showHDR)
        } else if useMetal {
            ensureFFmpegDecoded()
            if let d = _ffmpegDecoded {
                metalView.configure(decoded: d, hdr: showHDR, colorSpace: imgColorSpace)
            }
        } else if usePlacebo {
            ensureFFmpegDecoded()
            if let d = _ffmpegDecoded {
                placeboView.configure(decoded: d, hdr: showHDR, colorSpace: imgColorSpace)
            }
        }

        updateStatus()
    }

    func updateStatus() {
        let activeCS: CGColorSpace?
        switch mode {
        case .hlgCALayer, .hlgNSImage:
            activeCS = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case .mpv:
            activeCS = showHDR ? CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                               : CGColorSpace(name: CGColorSpace.sRGB)
        case .ffmpegMetal:
            activeCS = imgColorSpace
        case .placebo:
            activeCS = imgColorSpace
        default:
            activeCS = imgColorSpace
        }
        let csName = (activeCS?.name as String?) ?? "nil"

        let edr = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let size: String
        let bits: String
        if let d = _ffmpegDecoded, (mode == .ffmpegMetal || mode == .placebo) {
            size = "\(d.width)×\(d.height)"
            bits = "16bpc"
        } else {
            size = cgImage.map { "\($0.width)×\($0.height)" } ?? "?"
            bits = cgImage.map { "\($0.bitsPerComponent)bpc" } ?? "?"
        }

        statusLabel.stringValue = "[\(mode.rawValue)] \(mode.label)  |  \(hdrFormat.rawValue)  |  HDR: \(showHDR ? "ON" : "OFF")  |  \(size) \(bits)  |  CS: \(csName)  |  EDR: \(String(format: "%.1f", edr))x"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    deinit {
        // Clean up temp TIFF
        if let p = _tempTIFFPath {
            try? FileManager.default.removeItem(atPath: p)
        }
        // Free FFmpeg decoded data
        _ffmpegDecoded?.free()
    }
}

// MARK: - App Entry

let args = CommandLine.arguments
guard args.count > 1 else {
    let name = (args.first as NSString?)?.lastPathComponent ?? "testimg"
    print("""
    Usage: \(name) <image_path>

    Keyboard:
      1  Auto (format-appropriate)
      2  CALayer + CGImage (HLG-style EDR)
      3  NSImageView + dynamicRange (Gain Map-style)
      4  CIImage manual render
      5  Reinterpret as HLG → CALayer + EDR
      6  Reinterpret as HLG → NSImageView
      7  libmpv rendering
      8  FFmpeg + Metal HLG shader
      9  libplacebo tone mapping
      H  Toggle HDR on/off
      Q  Quit
    """)
    exit(1)
}

let path = args[1]
let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
guard FileManager.default.fileExists(atPath: url.path) else {
    print("File not found: \(url.path)")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let det = detectHDR(url: url)
print("Detected: \(det.format.rawValue)")
if let cs = det.colorSpace {
    print("ColorSpace: \(cs.name ?? "?" as CFString)")
    print("  model: \(cs.model.rawValue), components: \(cs.numberOfComponents)")
    print("  ITU-R 2100: \(CGColorSpaceUsesITUR_2100TF(cs))")
    print("  wide gamut: \(cs.isWideGamutRGB)")
}
if let cg = det.cgImage {
    print("Image: \(cg.width)×\(cg.height), \(cg.bitsPerComponent)bpc, \(cg.bitsPerPixel)bpp")
}
print("Mode 5/6: reinterpret → kCGColorSpaceITUR_2100_HLG")
print("Mode 7: libmpv (\(LibMPV.shared.ok ? "OK: \(LibMPV.shared.loadedPath ?? "")" : "NOT AVAILABLE"))")

let window = ImageWindow(url: url)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
