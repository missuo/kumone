// render-app-icon.swift — the Kumone app icon, drawn with CoreGraphics so the
// source of truth is geometry, not a bitmap.
//
// Usage:
//   xcrun --toolchain com.apple.dt.toolchain.XcodeDefault swift Scripts/render-app-icon.swift <outdir>
//
// Writes three 1024x1024 PNGs:
//   Background.png  opaque vermilion gradient      -> AppIcon.icon/Assets/ (back layer)
//   Mark.png        transparent white K            -> AppIcon.icon/Assets/ (front layer, glass)
//   AppIcon.png     opaque composite, no alpha     -> ios/KumoneIOS/Assets.xcassets/AppIcon.appiconset/
//
// The K is three equal 128pt strokes with round caps; its bounding box
// (308..716 x 236..788) is centred on the 1024 grid. The vermilion is the
// app accent (#EC4949 / #C92929) lifted slightly at the top.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    srgb(CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255, a)
}

func context(opaque: Bool) -> CGContext {
    let info: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
    // Flip so the drawing code can use the 1024 grid with y down, as in the design sheet.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

func drawBackground(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Vermilion: the app's accent (#EC4949 / #C92929) lifted slightly at the top.
    let base = CGGradient(colorsSpace: space, colors: [hex(0xF0564A), hex(0xC32B22)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])
    // Top sheen, 10% white fading out by 55%: depth without a visible band.
    let sheen = CGGradient(colorsSpace: space, colors: [hex(0xFFFFFF, 0.10), hex(0xFFFFFF, 0)] as CFArray, locations: [0, 0.55])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])
}

func drawK(_ ctx: CGContext) {
    // Three equal strokes of 128, round caps and joins; bounding box 308..716 x 236..788, centred on (512, 512).
    ctx.setStrokeColor(hex(0xFFFFFF))
    ctx.setLineWidth(128)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 372, y: 300)); ctx.addLine(to: CGPoint(x: 372, y: 724))
    ctx.move(to: CGPoint(x: 372, y: 512)); ctx.addLine(to: CGPoint(x: 652, y: 300))
    ctx.move(to: CGPoint(x: 372, y: 512)); ctx.addLine(to: CGPoint(x: 652, y: 724))
    ctx.strokePath()
}

func write(_ ctx: CGContext, _ name: String) {
    let image = ctx.makeImage()!
    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

let bg = context(opaque: true); drawBackground(bg); write(bg, "Background.png")
let mark = context(opaque: false); drawK(mark); write(mark, "Mark.png")
let composite = context(opaque: true); drawBackground(composite); drawK(composite); write(composite, "AppIcon.png")
