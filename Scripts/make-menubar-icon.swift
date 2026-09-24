// メニューバー用テンプレート（黒シルエット＋alpha）をアイコン原画から切り出す。
//
// 原画は「ダークグレー背景＋白い鳥」のペタ絵。ここから
//   輝度 > threshold の画素 → 不透明な黒 / それ以外 → 透明
// を変換し、シルエットのバウンディングボックスへトリムして書き出す。
// tight crop なので、使う側（StatusItemController）はメニューバー高さに
// 引き伸ばすだけで余白なく表示できる。
//
// 使い方: swift Scripts/make-menubar-icon.swift <art.png> <out.png>
//
// 注意: CLI の swift 実行ではウィンドウサーバー接続が無いので
// NSImage.lockFocus は黙って空になる。NSBitmapImageRep へ直接描く。
import AppKit
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    fatalError("usage: make-menubar-icon.swift <art.png> <out.png>")
}
let (artPath, outPath) = (args[1], args[2])

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: artPath) as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("cannot read art: \(artPath)")
}

// CGImage の pixel format は読んだ画像によってブレるので、
// 既知フォーマット（RGBA8）の bitmap rep に一度描いてから素で舐める。
let w = art.width, h = art.height
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else {
    fatalError("bitmap rep creation failed")
}
guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("context failed")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
gctx.cgContext.draw(art, in: CGRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.bitmapData else { fatalError("no bitmap data") }
let bpr = rep.bytesPerRow
// deviceRGB の RGBA8 は alpha が最後（0..=3 のうち 3）。違う環境があっても
// 壊れないように alphaInfo から実際の位置を数える。
let alphaInfo = rep.bitmapFormat.rawValue & 0xF
let alphaFirst = (alphaInfo == 2 || alphaInfo == 4) // premultipliedFirst / first
let aOff = alphaFirst ? 0 : 3

// 白い鳥＝高輝度。背景のダークグレーは ~0.12、鳥は ~0.97 だが、ChatGPT 生成の
// PNG は背景に細かいノイズ（中間輝度）とアンチエイリアスリングが乗るので、
// 高めの 220 で切って鳥本体だけ拾う。細部は 36px への縮小で平滑化される。
let threshold: UInt32 = 220
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        let i = y * bpr + x * 4
        let lum = (UInt32(data[i]) * 299 + UInt32(data[i + 1]) * 587 + UInt32(data[i + 2]) * 114) / 1000
        if lum > threshold {
            // 黒シルエット（不透明）
            data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 255
            if alphaFirst { data[i] = 255 } // 必要なら alpha 側も不透明に
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        } else {
            // 背景は透明
            data[i + (alphaFirst ? 0 : 3)] = 0
        }
    }
}
guard maxX >= 0 else { fatalError("no silhouette pixels found in \(artPath)") }
print("silhouette bbox: \(maxX - minX + 1)x\(maxY - minY + 1) at (\(minX),\(minY))")

// tight crop 用の rep を素のバイトコピーで組み立てる。
let cropW = maxX - minX + 1
let cropH = maxY - minY + 1
guard let crop = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: cropW, pixelsHigh: cropH,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else {
    fatalError("crop rep creation failed")
}
guard let cropData = crop.bitmapData else { fatalError("no crop bitmap data") }
let cropBPR = crop.bytesPerRow
for y in 0..<cropH {
    let from = data.advanced(by: (minY + y) * bpr + minX * 4)
    let to = cropData.advanced(by: y * cropBPR)
    memcpy(to, from, cropW * 4)
}

guard let png = crop.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote: \(outPath) (\(cropW)x\(cropH))")
