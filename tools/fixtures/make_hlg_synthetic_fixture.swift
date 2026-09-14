// 產生測試用的合成 HEIF fixture：純程式繪製的色塊，沒有著作權或隱私疑慮，
// 可安全放進公開 repo。直接寫入 16-bit 像素緩衝區——setFillColor(red:green:blue:)
// 使用 device RGB，會經色彩管理換算，無法得到精確的已知訊號值。
//
// 用法（於 repo 根目錄）：
//   swift tools/fixtures/make_hlg_synthetic_fixture.swift <mode> <output.heic>
//
// mode：
//   hlg-patches            HLG 訊號值，標記為 BT.2100 HLG
//                          → SpectrumTests/Fixtures/hlg_synthetic_patches.heic
//   hlg-mislabeled-srgb    同一組 HLG 訊號值，但標記為 sRGB——重現部分 Sony 相機
//                          把 HLG 內容寫成 sRGB NCLX 的情況
//                          → SpectrumTests/Fixtures/hlg_mislabeled_srgb.heic
//   slog3-mislabeled-srgb  S-Log3 編碼的色塊，標記為 sRGB
//                          → SpectrumTests/Fixtures/slog3_mislabeled_srgb.heic
//
// 版面（每塊 64×64）：上排灰階；下排紅 / 綠 / 藍 / 黃 / 洋紅
//   HLG：灰階訊號 0 / 0.25 / 0.5 / 0.75 / 1.0，原色通道 0.75
//   S-Log3：灰階反射率 0 / 2% / 18% / 90% / 400%，原色通道反射率 90%
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

typealias RGB = (Double, Double, Double)

/// Sony S-Log3 OETF：場景反射率 → 訊號值（0–1）
func slog3(_ x: Double) -> Double {
    x >= 0.01125
        ? (420.0 + log10((x + 0.01) / (0.18 + 0.01)) * 261.5) / 1023.0
        : (x * (171.2102946929 - 95.0) / 0.01125 + 95.0) / 1023.0
}

func layout(grays: [Double], on: Double, off: Double) -> [[RGB]] {
    [grays.map { ($0, $0, $0) },
     [(on, off, off), (off, on, off), (off, off, on), (on, on, off), (on, off, on)]]
}

let hlgRows = layout(grays: [0, 0.25, 0.5, 0.75, 1], on: 0.75, off: 0)
let modes: [String: (space: CFString, rows: [[RGB]])] = [
    "hlg-patches": (CGColorSpace.itur_2100_HLG, hlgRows),
    "hlg-mislabeled-srgb": (CGColorSpace.sRGB, hlgRows),
    "slog3-mislabeled-srgb": (CGColorSpace.sRGB,
                              layout(grays: [0, 0.02, 0.18, 0.9, 4].map(slog3), on: slog3(0.9), off: slog3(0))),
]

guard CommandLine.arguments.count == 3, let mode = modes[CommandLine.arguments[1]] else {
    FileHandle.standardError.write("usage: make_hlg_synthetic_fixture.swift <\(modes.keys.sorted().joined(separator: "|"))> <output.heic>\n".data(using: .utf8)!)
    exit(2)
}
let rows = mode.rows
let patch = 64, columns = 5
let width = patch * columns, height = patch * rows.count
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])
let space = CGColorSpace(name: mode.space)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue

func makeContext() -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
              space: space, bitmapInfo: bitmapInfo)!
}

// bitmap context 的緩衝區第 0 列即影像頂端
let ctx = makeContext()
let out = ctx.data!.bindMemory(to: UInt16.self, capacity: width * height * 4)
func level(_ v: Double) -> UInt16 { UInt16(v * 65535 + 0.5).littleEndian }
for (r, row) in rows.enumerated() {
    for (c, rgb) in row.enumerated() {
        for y in r * patch ..< (r + 1) * patch {
            for x in c * patch ..< (c + 1) * patch {
                let i = (y * width + x) * 4
                out[i] = level(rgb.0); out[i + 1] = level(rgb.1); out[i + 2] = level(rgb.2); out[i + 3] = level(1)
            }
        }
    }
}

let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.heic.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
guard CGImageDestinationFinalize(dest) else { print("write failed"); exit(1) }

// 自我驗證：以寫入時的色彩空間讀回，比對每塊中心點
let src = CGImageSourceCreateWithURL(outURL as CFURL, nil)!
let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let check = makeContext()
check.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
let px = check.data!.bindMemory(to: UInt16.self, capacity: width * height * 4)
var maxErr = 0.0
for (r, row) in rows.enumerated() {
    for (c, rgb) in row.enumerated() {
        let i = ((r * patch + patch / 2) * width + (c * patch + patch / 2)) * 4
        let got = [px[i], px[i + 1], px[i + 2]].map { Double(UInt16(littleEndian: $0)) / 65535 }
        maxErr = max(maxErr, abs(got[0] - rgb.0), abs(got[1] - rgb.1), abs(got[2] - rgb.2))
    }
}
let size = (try? outURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
print("[\(CommandLine.arguments[1])] \(outURL.lastPathComponent): \(decoded.width)x\(decoded.height) Depth=\(props[kCGImagePropertyDepth] ?? "?") ProfileName=\(props[kCGImagePropertyProfileName] ?? "nil") size=\(size)B")
print(String(format: "  patch center max |error| vs written signal = %.4f", maxErr))
