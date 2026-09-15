// AppIcon 用の 1024x1024 PNG をレンダリングする。
//
// デザイン: ペタっとしたダークグレーのベタ背景 + 元写真から切り抜いた
// モズの白シルエット。分割は Vision の前景インスタンスマスク (macOS 14+)。
//
// 使い方: swift Scripts/make-icon.swift <photo> <out.png> [menubar.png]
//   3つ目の引数を与えると、メニューバー用の黒テンプレート画像（余白ゼロの
//   きっちりクロップ）も同じシルエットから書き出す。
//
// macOS のアプリアイコンは「角丸はシステムがmaskする」ので、
// カンバス全面に背景を描く（自分で角丸を描くと二重に丸くなる）。
//
// 注意: CLI の swift 実行ではウィンドウサーバー接続が無いので
// NSImage.lockFocus は黙って空になる（CGImageDestinationFinalize 失敗）。
// NSBitmapImageRep + NSGraphicsContext(bitmapImageRep:) で直接描く。
import AppKit
import CoreImage
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else {
    fatalError("usage: make-icon.swift <photo.jpg|png> <out.png>")
}
let photoPath = args[1]
let outPath = args[2]
let size = 1024.0

func newRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("bitmap rep creation failed")
    }
    return rep
}

// MARK: - 1. 元写真（EXIF orientation は無しを確認済み。CGImageSource で素直に読む）

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: photoPath) as CFURL, nil),
      let photo = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("cannot read photo: \(photoPath)")
}

// MARK: - 2. Vision で前景インスタンスを分割し、いちでかい物体（=鳥）を選ぶ

let handler = VNImageRequestHandler(cgImage: photo, orientation: .up)
let fgRequest = VNGenerateForegroundInstanceMaskRequest()
do {
    try handler.perform([fgRequest])
} catch {
    fatalError("Vision foreground request failed: \(error)")
}
guard let obs = fgRequest.results?.first, obs.allInstances.count > 0 else {
    fatalError("Vision found no foreground")
}

// instanceMask は低解像のラベル画像（0=背景、他はインスタンス番号）。
// ピクセル数を数えて最大の実体＝鳥とみなす。
let labelMask = obs.instanceMask
CVPixelBufferLockBaseAddress(labelMask, .readOnly)
let labelFmt = CVPixelBufferGetPixelFormatType(labelMask)
let labelW = CVPixelBufferGetWidth(labelMask)
let labelH = CVPixelBufferGetHeight(labelMask)
let labelBPR = CVPixelBufferGetBytesPerRow(labelMask)
var counts = [Int: Int]()
if let labelBase = CVPixelBufferGetBaseAddress(labelMask) {
    switch labelFmt {
    case kCVPixelFormatType_OneComponent32Float:
        let p = labelBase.assumingMemoryBound(to: Float32.self)
        let stride = labelBPR / MemoryLayout<Float32>.size
        for y in 0..<labelH {
            for x in 0..<labelW {
                let index = Int(p[y * stride + x].rounded())
                if index > 0 { counts[index, default: 0] += 1 }
            }
        }
    default:
        let p = labelBase.assumingMemoryBound(to: UInt8.self)
        for y in 0..<labelH {
            for x in 0..<labelW {
                let index = Int(p[y * labelBPR + x])
                if index > 0 { counts[index, default: 0] += 1 }
            }
        }
    }
}
CVPixelBufferUnlockBaseAddress(labelMask, .readOnly)

guard let birdIndex = counts.max(by: { $0.value < $1.value })?.key else {
    fatalError("foreground instances found but all empty: \(counts)")
}
print("instances (px): \(counts) — using #\(birdIndex)")

// 鳥インスタンスだけを切り出す（透過黒背景・バウンディングボックス crop 済み）。
guard let cutBuf = try? obs.generateMaskedImage(
    ofInstances: IndexSet(integer: birdIndex),
    from: handler,
    croppedToInstancesExtent: true
) else {
    fatalError("generateMaskedImage failed")
}

// MARK: - 3. 切り出し画像の alpha をそのまま白として使うシルエットにする

let ci = CIContext(options: [.useSoftwareRenderer: true])
let cutCI = CIImage(cvPixelBuffer: cutBuf)
let whiteSource = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
    .cropped(to: cutCI.extent)
let blended = whiteSource.applyingFilter("CIBlendWithAlphaMask", parameters: [
    kCIInputMaskImageKey: cutCI,
    kCIInputBackgroundImageKey: CIImage.empty(),
])
guard let silhouette = ci.createCGImage(blended, from: cutCI.extent) else {
    fatalError("silhouette render failed")
}
print("silhouette: \(silhouette.width)x\(silhouette.height)")

// MARK: - 4. 1024x1024 カンバスに合成（ダークグレーベタ + 白鳥）

let canvas = newRep(Int(size), Int(size))
guard let gctx = NSGraphicsContext(bitmapImageRep: canvas) else {
    fatalError("canvas context failed")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

// 背景: ダークグレーのベタ（グラデーション無し）。
ctx.setFillColor(NSColor(srgbRed: 0.19, green: 0.19, blue: 0.20, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// 鳥は長辺がカンバスの 76% に収まるよう中央配置（上下左右に少し余白を残す。
// ベタ詰めだとメニューバーと同じく張り出しすぎて見える）。
let fit = size * 0.76
let scale = min(fit / CGFloat(silhouette.width), fit / CGFloat(silhouette.height))
let drawW = CGFloat(silhouette.width) * scale
let drawH = CGFloat(silhouette.height) * scale
let drawX = (size - drawW) / 2
let drawY = (size - drawH) / 2
ctx.draw(silhouette, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote: \(outPath)")

// MARK: - 5. メニューバー用テンプレート（黒シルエット・余白無し）
//
// NSImage.isTemplate は alpha だけ見るが、ならわし通り黒で焼く。
// 元が tight crop なのでパディングは足さない＝メニューバー高さ一杯に使える。
if args.count >= 4 {
    let blackSource = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
        .cropped(to: cutCI.extent)
    let blendedBlack = blackSource.applyingFilter("CIBlendWithAlphaMask", parameters: [
        kCIInputMaskImageKey: cutCI,
        kCIInputBackgroundImageKey: CIImage.empty(),
    ])
    guard let blackCG = ci.createCGImage(blendedBlack, from: cutCI.extent) else {
        fatalError("menubar render failed")
    }
    let mbCanvas = newRep(blackCG.width, blackCG.height)
    guard let mbCtx = NSGraphicsContext(bitmapImageRep: mbCanvas) else {
        fatalError("menubar context failed")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = mbCtx
    mbCtx.cgContext.draw(blackCG, in: CGRect(x: 0, y: 0, width: CGFloat(blackCG.width), height: CGFloat(blackCG.height)))
    NSGraphicsContext.restoreGraphicsState()
    guard let mbPNG = mbCanvas.representation(using: .png, properties: [:]) else {
        fatalError("menubar png encode failed")
    }
    try! mbPNG.write(to: URL(fileURLWithPath: args[3]))
    print("wrote: \(args[3]) (\(blackCG.width)x\(blackCG.height))")
}
