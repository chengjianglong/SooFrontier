// SooFrontier icon v3: a glass constellation "S" orbiting a glowing AI core, on deep navy-teal.
// usage: swift make_icon_v3.swift <out.png> [ios|mac] [size]
import AppKit
import CoreGraphics
import CoreText

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon.png"
let mode = args.count > 2 ? args[2] : "ios"
let size = args.count > 3 ? Int(args[3])! : 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

let gold = rgb(0xF6C987), teal = rgb(0x8FE3CF)
let center = CGPoint(x: 512, y: 512)

func dot(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
func glowFill(_ path: CGPath, _ color: CGColor, blur: CGFloat) {
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: blur, color: color)
    ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath(); ctx.restoreGState()
}
func glowStroke(_ path: CGPath, _ color: CGColor, _ w: CGFloat, blur: CGFloat) {
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: blur, color: color)
    ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath(); ctx.restoreGState()
}
/// Gold at the top-left of the mark blending to teal at the bottom-right.
func tone(_ p: CGPoint, _ a: CGFloat = 1) -> CGColor {
    let t = max(0, min(1, ((p.x - 300) + (p.y - 250)) / 650))
    func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
    return CGColor(red: mix(0.965, 0.56), green: mix(0.79, 0.89), blue: mix(0.53, 0.81), alpha: a)
}

func drawArt() {
    // Backdrop.
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x0B1630), rgb(0x10304A), rgb(0x184A4E)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])
    let halo = CGGradient(colorsSpace: cs, colors: [rgb(0x4FA3A0, 0.40), rgb(0x4FA3A0, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: center, startRadius: 0, endCenter: center, endRadius: 560, options: [])

    // Neural threads at the edges.
    let threads: [[CGPoint]] = [
        [CGPoint(x: -20, y: 640), CGPoint(x: 90, y: 600), CGPoint(x: 140, y: 690), CGPoint(x: 60, y: 800), CGPoint(x: -20, y: 860)],
        [CGPoint(x: 1044, y: 300), CGPoint(x: 950, y: 270), CGPoint(x: 905, y: 170), CGPoint(x: 960, y: 60), CGPoint(x: 1044, y: 30)],
        [CGPoint(x: 950, y: 270), CGPoint(x: 1044, y: 380)],
    ]
    for t in threads {
        let p = CGMutablePath(); p.move(to: t[0])
        for i in 1..<t.count { let a = t[i - 1], b = t[i]; p.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2 + 14, y: (a.y + b.y) / 2 - 14)) }
        glowStroke(p, rgb(0x8FE3CF, 0.30), 2.5, blur: 8)
        for pt in t.dropFirst().dropLast() { glowFill(dot(pt, 7), rgb(0xA8F0DD, 0.7), blur: 16) }
    }
    for (x, y, r) in [(170.0, 160.0, 2.5), (250, 300, 1.8), (860, 860, 2.5), (780, 140, 2.0), (140, 470, 1.8),
                      (900, 620, 2.0), (330, 900, 2.0), (640, 110, 1.6)] as [(CGFloat, CGFloat, CGFloat)] {
        glowFill(dot(CGPoint(x: x, y: y), r), rgb(0xFFFFFF, 0.7), blur: 6)
    }

    // Thin inner frame.
    let frame = CGPath(roundedRect: CGRect(x: 150, y: 150, width: 724, height: 724), cornerWidth: 90, cornerHeight: 90, transform: nil)
    glowStroke(frame, rgb(0xBFE9E0, 0.28), 2.5, blur: 6)

    // The glass S.
    let font = CTFontCreateWithName("AvenirNext-DemiBold" as CFString, 860, nil)
    var glyph = CGGlyph(0); var ch: UniChar = 0x53
    CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
    var sPath = CTFontCreatePathForGlyph(font, glyph, nil)!
    let gb = sPath.boundingBoxOfPath
    var t = CGAffineTransform(translationX: 512 - gb.midX, y: 512 + gb.midY).scaledBy(x: 1, y: -1)
    sPath = sPath.copy(using: &t)!
    let sBox = sPath.boundingBoxOfPath

    // Orbit ring, back half (drawn before the S so the S sits in front of it).
    func orbit(_ from: CGFloat, _ to: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let tr = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -0.42).scaledBy(x: 1, y: 0.36)
        p.addArc(center: .zero, radius: 360, startAngle: from, endAngle: to, clockwise: false, transform: tr)
        return p
    }
    glowStroke(orbit(.pi, 2 * .pi), rgb(0xF6C987, 0.40), 3, blur: 10)

    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 50, color: rgb(0x8FE3CF, 0.35))
    ctx.addPath(sPath); ctx.setFillColor(rgb(0x9FD8D0, 0.10)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(sPath); ctx.clip()
    let glass = CGGradient(colorsSpace: cs, colors: [rgb(0xF6C987, 0.38), rgb(0xBFE9E0, 0.18), rgb(0x8FE3CF, 0.38)] as CFArray,
                           locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(glass, start: CGPoint(x: sBox.minX, y: sBox.minY), end: CGPoint(x: sBox.maxX, y: sBox.maxY), options: [])
    ctx.restoreGState()
    // Bright rim: gradient stroke of the outline.
    ctx.saveGState()
    ctx.addPath(sPath); ctx.setLineWidth(10); ctx.setLineJoin(.round); ctx.replacePathWithStrokedPath(); ctx.clip()
    let rim = CGGradient(colorsSpace: cs, colors: [gold, rgb(0xE8E6C8), teal] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: sBox.minX, y: sBox.minY), end: CGPoint(x: sBox.maxX, y: sBox.maxY), options: [])
    ctx.restoreGState()

    // Constellation along the S outline.
    var outline: [CGPoint] = []
    sPath.applyWithBlock { e in
        let el = e.pointee
        switch el.type {
        case .moveToPoint, .addLineToPoint: outline.append(el.points[0])
        case .addQuadCurveToPoint: outline.append(el.points[1])
        case .addCurveToPoint: outline.append(el.points[2])
        default: break
        }
    }
    var stars: [CGPoint] = []
    for pt in outline where stars.allSatisfy({ hypot($0.x - pt.x, $0.y - pt.y) > 95 }) { stars.append(pt) }
    for i in 1..<stars.count where hypot(stars[i].x - stars[i - 1].x, stars[i].y - stars[i - 1].y) < 200 {
        let mid = CGPoint(x: (stars[i].x + stars[i - 1].x) / 2, y: (stars[i].y + stars[i - 1].y) / 2)
        let l = CGMutablePath(); l.move(to: stars[i - 1]); l.addLine(to: stars[i])
        glowStroke(l, tone(mid, 0.75), 2.5, blur: 8)
    }
    for (i, s) in stars.enumerated() {
        glowFill(dot(s, i % 3 == 0 ? 13 : 9), tone(s), blur: 26)
        glowFill(dot(s, i % 3 == 0 ? 5 : 3.5), rgb(0xFFFFFF, 0.9), blur: 4)
    }

    // Orbit ring, front half.
    glowStroke(orbit(0, .pi), rgb(0xF6C987, 0.65), 3.5, blur: 12)

    // AI core: a glowing orb with faint brain folds and the letters "AI".
    let r: CGFloat = 70
    let core = CGGradient(colorsSpace: cs, colors: [rgb(0xFFF3DC, 0.95), rgb(0x9FE6D6, 0.55), rgb(0x2C6F74, 0.15)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xF6E3B8, 0.9))
    ctx.addPath(dot(center, r)); ctx.setFillColor(rgb(0x2C6F74, 0.6)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(dot(center, r)); ctx.clip()
    ctx.drawRadialGradient(core, startCenter: CGPoint(x: center.x - 20, y: center.y - 25), startRadius: 0,
                           endCenter: center, endRadius: r, options: [])
    // Brain folds.
    for (dx, dy, rr, a0, a1) in [(-23.0, -14.0, 26.0, 3.4, 5.6), (23, -14, 26, 3.8, 6.0), (-26, 17, 23, 0.6, 2.8),
                                  (26, 17, 23, 0.3, 2.5), (0, 0, 46, 3.9, 5.5)] as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
        let p = CGMutablePath()
        p.addArc(center: CGPoint(x: center.x + dx, y: center.y + dy), radius: rr, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.addPath(p); ctx.setStrokeColor(rgb(0x1E4E54, 0.35)); ctx.setLineWidth(3); ctx.strokePath()
    }
    ctx.restoreGState()
    ctx.addPath(dot(center, r)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.55)); ctx.setLineWidth(2.5); ctx.strokePath()

    ctx.saveGState()
    let aiFont = CTFontCreateWithName("AvenirNext-DemiBold" as CFString, 58, nil)
    let str = NSAttributedString(string: "AI", attributes: [.font: aiFont, .foregroundColor: NSColor(cgColor: rgb(0x123C44))!])
    let lineRef = CTLineCreateWithAttributedString(str)
    let bounds = CTLineGetImageBounds(lineRef, ctx)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: center.x - bounds.width / 2 - bounds.minX, y: center.y + bounds.height / 2 + bounds.minY)
    CTLineDraw(lineRef, ctx)
    ctx.restoreGState()

    // Sparkles.
    for (x, y, s) in [(395.0, 205.0, 14.0), (690, 360, 10.0), (330, 640, 9.0)] as [(CGFloat, CGFloat, CGFloat)] {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: y - s)); p.addLine(to: CGPoint(x: x + s * 0.25, y: y - s * 0.25))
        p.addLine(to: CGPoint(x: x + s, y: y)); p.addLine(to: CGPoint(x: x + s * 0.25, y: y + s * 0.25))
        p.addLine(to: CGPoint(x: x, y: y + s)); p.addLine(to: CGPoint(x: x - s * 0.25, y: y + s * 0.25))
        p.addLine(to: CGPoint(x: x - s, y: y)); p.addLine(to: CGPoint(x: x - s * 0.25, y: y - s * 0.25)); p.closeSubpath()
        glowFill(p, rgb(0xFFF1D6, 0.9), blur: 10)
    }
}

if mode == "mac" {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.4))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x10304A)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    ctx.translateBy(x: 100, y: 100); ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
    drawArt(); ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(2); ctx.strokePath()
} else {
    drawArt()
}

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
