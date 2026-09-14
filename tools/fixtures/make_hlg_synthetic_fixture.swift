// 產生 HLGExportTests 用的合成 HLG HEIF fixture：純程式繪製的色塊，
// 沒有著作權或隱私疑慮，可安全放進公開 repo。
//
// 用法（於 repo 根目錄）：
//   swift tools/fixtures/make_hlg_synthetic_fixture.swift SpectrumTests/Fixtures/hlg_synthetic_patches.heic
//
// 版面（每塊 64×64，數值為 HLG 訊號值 0–1）：
//   上排：灰階 0.00 / 0.25 / 0.50 / 0.75 / 1.00
//   下排：紅 / 綠 / 藍 / 黃 / 洋紅（有值的通道皆為 0.75）
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let patch = 64
let columns = 5
let rows: [[(CGFloat, CGFloat, CGFloat)]] = [
    [(0, 0, 0), (0.25, 0.25, 0.25), (0.5, 0.5, 0.5), (0.75, 0.75, 0.75), (1, 1, 1)],
    [(0.75, 0, 0), (0, 0.75, 0), (0, 0, 0.75), (0.75, 0.75, 0), (0.75, 0, 0.75)],
]
let width = patch * columns, height = patch * rows.count

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make_hlg_synthetic_fixture.swift <output.heic>\n".data(using: .utf8)!)
    exit(2)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue

func makeContext() -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
              space: hlg, bitmapInfo: bitmapInfo)!
}

// 直接寫入 16-bit 像素緩衝區：setFillColor(red:green:blue:) 使用 device RGB，
// 會經色彩管理換算成別的 HLG 訊號值，無法得到精確的已知數值。
// bitmap context 的緩衝區第 0 列即影像頂端。
let ctx = makeContext()
let out = ctx.data!.bindMemory(to: UInt16.self, capacity: width * height * 4)
func level(_ v: CGFloat) -> UInt16 { UInt16(v * 65535 + 0.5).littleEndian }
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

// 自我驗證：讀回後在 HLG 空間取每塊中心點，與寫入值比對
let src = CGImageSourceCreateWithURL(outURL as CFURL, nil)!
let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let check = makeContext()
check.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
let px = check.data!.bindMemory(to: UInt16.self, capacity: width * height * 4)
var maxErr: CGFloat = 0
for (r, row) in rows.enumerated() {
    for (c, rgb) in row.enumerated() {
        // data 緩衝區的第 0 列是影像頂端
        let i = ((r * patch + patch / 2) * width + (c * patch + patch / 2)) * 4
        let got = [px[i], px[i + 1], px[i + 2]].map { CGFloat(UInt16(littleEndian: $0)) / 65535 }
        maxErr = max(maxErr, abs(got[0] - rgb.0), abs(got[1] - rgb.1), abs(got[2] - rgb.2))
    }
}
let size = (try? outURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
print("wrote \(outURL.lastPathComponent): \(decoded.width)x\(decoded.height) Depth=\(props[kCGImagePropertyDepth] ?? "?") ProfileName=\(props[kCGImagePropertyProfileName] ?? "nil") itur2100=\(decoded.colorSpace.map(CGColorSpaceUsesITUR_2100TF) ?? false) size=\(size)B")
print(String(format: "patch center max |error| vs written HLG signal = %.4f", maxErr))
