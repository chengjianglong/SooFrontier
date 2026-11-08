// Builds the app icon from a square artwork image.
// usage: swift make_icon_from_image.swift <source.png> <out.png> [ios|mac]
// ios: the artwork as-is (iOS rounds the corners). mac: the artwork on a rounded tile with margin and shadow.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let outPath = args[2]
let mode = args.count > 3 ? args[3] : "ios"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

if mode == "mac" {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.4))
    ctx.addPath(shape); ctx.setFillColor(CGColor(red: 0.07, green: 0.2, blue: 0.27, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    ctx.draw(src, in: tile)
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(2); ctx.strokePath()
} else {
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
}

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
