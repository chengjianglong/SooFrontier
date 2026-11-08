// SooFrontier icon v2: a glowing constellation "S" with an up-right frontier arrow on deep teal.
// usage: swift make_icon_v2.swift <out.png> [ios|mac] [size]
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

let peach = rgb(0xF3C9A8), rose = rgb(0xD9A49A), mint = rgb(0xA8E6CF), teal = rgb(0x7FD6C2), ice = rgb(0xCFEFF0)
let glow = rgb(0xFFD9A0)

func line(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); return p }
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

func drawArt() {
    // Background: deep navy to teal, with a soft light behind the mark.
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x0E1E2E), rgb(0x123544), rgb(0x1B4A4A)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])
    let halo = CGGradient(colorsSpace: cs, colors: [rgb(0x3E8C86, 0.45), rgb(0x3E8C86, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: 500, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 500, y: 520), endRadius: 520, options: [])

    // Faint neural-network threads in the corners.
    let threads: [[CGPoint]] = [
        [CGPoint(x: -20, y: 760), CGPoint(x: 120, y: 700), CGPoint(x: 210, y: 790), CGPoint(x: 330, y: 930), CGPoint(x: 420, y: 1060)],
        [CGPoint(x: 1060, y: 230), CGPoint(x: 900, y: 200), CGPoint(x: 820, y: 110), CGPoint(x: 760, y: -20)],
        [CGPoint(x: 1060, y: 360), CGPoint(x: 930, y: 330), CGPoint(x: 900, y: 200)],
        [CGPoint(x: -20, y: 860), CGPoint(x: 120, y: 700)],
    ]
    for t in threads {
        let p = CGMutablePath(); p.move(to: t[0])
        for i in 1..<t.count { let a = t[i - 1], b = t[i]; p.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2 + 18, y: (a.y + b.y) / 2 - 18)) }
        glowStroke(p, rgb(0x7FD6C2, 0.35), 3, blur: 8)
        for pt in t.dropFirst().dropLast() { glowFill(dot(pt, 7), rgb(0xA8E6CF, 0.75), blur: 14) }
    }
    for (x, y, r, a) in [(160.0, 170.0, 3.0, 0.6), (260, 110, 2.0, 0.5), (880, 860, 3.0, 0.5), (950, 700, 2.0, 0.4),
                         (120, 420, 2.0, 0.4), (700, 900, 2.5, 0.5), (820, 520, 2.0, 0.4)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        glowFill(dot(CGPoint(x: x, y: y), r), rgb(0xFFFFFF, a), blur: 6)
    }

    // The "S": a serif glyph filled with a peach-to-rose gradient and a soft glow.
    let font = CTFontCreateWithName("Georgia-Bold" as CFString, 620, nil)
    var glyph = CGGlyph(0); var ch: UniChar = 0x53
    CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
    var sPath = CTFontCreatePathForGlyph(font, glyph, nil)!
    let gb = sPath.boundingBoxOfPath
    var t = CGAffineTransform(translationX: 385 - gb.midX, y: 535 + gb.midY).scaledBy(x: 1, y: -1)
    sPath = sPath.copy(using: &t)!
    let sBox = sPath.boundingBoxOfPath
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xF3C9A8, 0.55))
    ctx.addPath(sPath); ctx.setFillColor(peach); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(sPath); ctx.clip()
    let sGrad = CGGradient(colorsSpace: cs, colors: [rgb(0xFBE3CC), peach, rose, rgb(0x9FB7B9)] as CFArray, locations: [0, 0.35, 0.7, 1])!
    ctx.drawLinearGradient(sGrad, start: CGPoint(x: sBox.minX, y: sBox.minY), end: CGPoint(x: sBox.maxX, y: sBox.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(sPath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.35)); ctx.setLineWidth(3); ctx.strokePath()

    // Constellation traced along the S: nodes sampled on its outline, joined by thin light.
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
    for pt in outline where stars.allSatisfy({ hypot($0.x - pt.x, $0.y - pt.y) > 70 }) { stars.append(pt) }
    // Keep the outer contour's nodes in order and connect neighbours.
    for i in 1..<stars.count where hypot(stars[i].x - stars[i - 1].x, stars[i].y - stars[i - 1].y) < 190 {
        glowStroke(line([stars[i - 1], stars[i]]), rgb(0xFFE7C4, 0.8), 3, blur: 10)
    }
    for (i, st) in stars.enumerated() { glowFill(dot(st, i % 3 == 0 ? 11 : 8), glow, blur: 22) }

    // The frontier arrow: a bold up-right arrow whose lower bar reads as an "F".
    let arrowGrad = CGGradient(colorsSpace: cs, colors: [teal, ice] as CFArray, locations: [0, 1])!
    func band(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat) -> CGPath {
        let dx = b.x - a.x, dy = b.y - a.y, len = (dx * dx + dy * dy).squareRoot()
        let nx = -dy / len * w / 2, ny = dx / len * w / 2
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny),
                             CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)])
        p.closeSubpath(); return p
    }
    // One continuous shape: shaft rising from the S, arrowhead, and the F's crossbar with its own small head.
    let shaft = band(CGPoint(x: 560, y: 720), CGPoint(x: 790, y: 395), 64)
    let dir = CGPoint(x: 790 - 560, y: 395 - 720); let dl = hypot(dir.x, dir.y)
    let u = CGPoint(x: dir.x / dl, y: dir.y / dl), n = CGPoint(x: -u.y, y: u.x)
    let base = CGPoint(x: 790, y: 395), tip = CGPoint(x: base.x + u.x * 190, y: base.y + u.y * 190)
    let head = CGMutablePath()
    head.addLines(between: [tip, CGPoint(x: base.x + n.x * 95, y: base.y + n.y * 95), CGPoint(x: base.x - n.x * 95, y: base.y - n.y * 95)])
    head.closeSubpath()
    let barY: CGFloat = 610
    let fBar = band(CGPoint(x: 625, y: barY), CGPoint(x: 760, y: barY), 52)
    let fTip = CGMutablePath()
    fTip.addLines(between: [CGPoint(x: 745, y: barY - 58), CGPoint(x: 845, y: barY), CGPoint(x: 745, y: barY + 58)]); fTip.closeSubpath()
    let arrow = CGMutablePath()
    for p in [shaft, head as CGPath, fBar, fTip as CGPath] { arrow.addPath(p) }
    // Fill each piece on its own so overlaps never cancel out.
    let pieces: [CGPath] = [shaft, head, fBar, fTip]
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x7FD6C2, 0.7))
    for p in pieces { ctx.addPath(p); ctx.setFillColor(teal); ctx.fillPath() }
    ctx.restoreGState()
    for p in pieces {
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        ctx.drawLinearGradient(arrowGrad, start: CGPoint(x: 560, y: 720), end: tip, options: [])
        ctx.restoreGState()
    }

    // Gears and a chat bubble: the agents at work.
    func gear(_ c: CGPoint, _ r: CGFloat, teeth: Int, _ color: CGColor) {
        let p = CGMutablePath()
        for i in 0..<(teeth * 2) {
            let a = CGFloat(i) * .pi / CGFloat(teeth)
            let rr = i % 2 == 0 ? r : r * 0.78
            let a1 = a - .pi / CGFloat(teeth) * 0.5, a2 = a + .pi / CGFloat(teeth) * 0.5
            let p1 = CGPoint(x: c.x + cos(a1) * rr, y: c.y + sin(a1) * rr), p2 = CGPoint(x: c.x + cos(a2) * rr, y: c.y + sin(a2) * rr)
            i == 0 ? p.move(to: p1) : p.addLine(to: p1); p.addLine(to: p2)
        }
        p.closeSubpath(); p.addEllipse(in: CGRect(x: c.x - r * 0.38, y: c.y - r * 0.38, width: r * 0.76, height: r * 0.76))
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 10, color: color)
        ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath(using: .evenOdd); ctx.restoreGState()
    }
    gear(CGPoint(x: 820, y: 770), 46, teeth: 9, rgb(0x9FB7B9, 0.85))
    gear(CGPoint(x: 885, y: 712), 28, teeth: 8, rgb(0xC9A08C, 0.8))
    let bubble = CGMutablePath()
    bubble.addRoundedRect(in: CGRect(x: 600, y: 190, width: 92, height: 64), cornerWidth: 24, cornerHeight: 24)
    bubble.move(to: CGPoint(x: 623, y: 250)); bubble.addLine(to: CGPoint(x: 615, y: 283)); bubble.addLine(to: CGPoint(x: 647, y: 253))
    glowStroke(bubble, rgb(0xF3C9A8, 0.9), 5, blur: 10)
    for x in [626.0, 646, 666] as [CGFloat] { glowFill(dot(CGPoint(x: x, y: 222), 5), glow, blur: 6) }

    // Orbit arc around the mark.
    let orbit = CGMutablePath()
    orbit.addArc(center: CGPoint(x: 512, y: 520), radius: 400, startAngle: 2.2, endAngle: 4.5, clockwise: false)
    glowStroke(orbit, rgb(0xF3C9A8, 0.45), 3, blur: 8)
}

if mode == "mac" {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.4))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x123544)); ctx.fillPath(); ctx.restoreGState()
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
