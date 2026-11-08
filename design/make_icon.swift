// Renders the SooFrontier app icon with CoreGraphics.
// usage: swift make_icon.swift <out.png> [ios|mac] [size]
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon.png"
let mode = args.count > 2 ? args[2] : "ios"
let size = args.count > 3 ? Int(args[3])! : 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let ink = rgb(0x1E1E2A)
let orange = rgb(0xF7AA35)
let teal = rgb(0x1E9FB9)
let purple = rgb(0x6B2D91)
let maroon = rgb(0x9C4A4F)
let cream = rgb(0xFFF6DC)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in a 1024 top-left coordinate space.
ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

func star(_ c: CGPoint, points: Int, outer: CGFloat, inner: CGFloat, rotation: CGFloat = -.pi / 2) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<(points * 2) {
        let r = i % 2 == 0 ? outer : inner
        let a = rotation + CGFloat(i) * .pi / CGFloat(points)
        let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func fill(_ path: CGPath, _ color: CGColor) { ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath() }

func stroke(_ path: CGPath, _ color: CGColor, _ w: CGFloat) {
    ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(w)
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
}

func line(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); return p }

func drawArt() {
    // Background: soft frontier-blue radial glow.
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xF4F9FD), rgb(0xCFE1F0), rgb(0xB7D0E6)] as CFArray,
                        locations: [0, 0.6, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 760, options: [.drawsAfterEndLocation])

    // Cream starbursts behind the data sources.
    fill(star(CGPoint(x: 210, y: 250), points: 8, outer: 250, inner: 70, rotation: -0.2), cream)
    fill(star(CGPoint(x: 830, y: 270), points: 8, outer: 260, inner: 72, rotation: 0.15), cream)

    // Confetti.
    fill(star(CGPoint(x: 110, y: 560), points: 8, outer: 52, inner: 22), orange)
    fill(star(CGPoint(x: 918, y: 585), points: 6, outer: 50, inner: 24), teal)
    fill(star(CGPoint(x: 512, y: 112), points: 5, outer: 44, inner: 19), maroon)
    fill(star(CGPoint(x: 130, y: 880), points: 8, outer: 62, inner: 14), teal)
    fill(star(CGPoint(x: 895, y: 875), points: 5, outer: 50, inner: 22, rotation: -.pi / 2 + 0.3), maroon)
    for (x, y, r, c) in [(345.0, 175.0, 24.0, purple), (690, 170, 22, ink), (955, 420, 18, ink),
                         (150, 690, 16, ink), (880, 720, 22, purple), (512, 960, 14, ink)] as [(CGFloat, CGFloat, CGFloat, CGColor)] {
        fill(CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil), c)
    }

    // Data cylinders.
    func cylinder(_ cx: CGFloat, _ top: CGFloat, _ color: CGColor) {
        let w: CGFloat = 170, eh: CGFloat = 52, h: CGFloat = 175
        let body = CGMutablePath()
        body.addRect(CGRect(x: cx - w / 2, y: top, width: w, height: h))
        body.addEllipse(in: CGRect(x: cx - w / 2, y: top + h - eh / 2, width: w, height: eh))
        fill(body, rgb(0xFFFFFF, 0.92))
        let lw: CGFloat = 15
        stroke(CGPath(ellipseIn: CGRect(x: cx - w / 2, y: top - eh / 2, width: w, height: eh), transform: nil), color, lw)
        for k in 1...3 {
            let y = top + CGFloat(k) * h / 3
            let arc = CGMutablePath()
            arc.addArc(center: .zero, radius: 1, startAngle: 0, endAngle: .pi, clockwise: false,
                       transform: CGAffineTransform(translationX: cx, y: y - eh / 2 + eh / 2).scaledBy(x: w / 2, y: eh / 2))
            stroke(arc, color, lw)
        }
        stroke(line([CGPoint(x: cx - w / 2, y: top), CGPoint(x: cx - w / 2, y: top + h)]), color, lw)
        stroke(line([CGPoint(x: cx + w / 2, y: top), CGPoint(x: cx + w / 2, y: top + h)]), color, lw)
    }
    cylinder(205, 175, teal)
    cylinder(819, 175, purple)

    // Radiating "idea" sparks.
    for (a, b) in [((512.0, 190.0), (512.0, 250.0)), ((400, 215), (440, 262)), ((624, 215), (584, 262))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
        stroke(line([CGPoint(x: a.0, y: a.1), CGPoint(x: b.0, y: b.1)]), orange, 20)
    }

    // Brain: union of lobes, outlined by stroking then filling the same circles.
    let c = CGPoint(x: 512, y: 632), s: CGFloat = 0.82
    let lobes: [(CGFloat, CGFloat, CGFloat)] = [(-92, -200, 92), (92, -200, 92), (-200, -120, 92), (200, -120, 92),
                                                (-232, 10, 92), (232, 10, 92), (-195, 130, 92), (195, 130, 92),
                                                (-85, 190, 88), (85, 190, 88), (0, -20, 235)]
    let brain = CGMutablePath()
    for (x, y, r) in lobes {
        brain.addEllipse(in: CGRect(x: c.x + (x - r) * s, y: c.y + (y - r) * s, width: 2 * r * s, height: 2 * r * s))
    }
    for (x, y, r) in lobes {
        let p = CGPath(ellipseIn: CGRect(x: c.x + (x - r) * s, y: c.y + (y - r) * s, width: 2 * r * s, height: 2 * r * s), transform: nil)
        stroke(p, ink, 30)
    }
    for (x, y, r) in lobes {
        fill(CGPath(ellipseIn: CGRect(x: c.x + (x - r) * s, y: c.y + (y - r) * s, width: 2 * r * s, height: 2 * r * s), transform: nil), rgb(0xFFFFFF))
    }

    // Circuit traces ending in nodes.
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    let traces: [[CGPoint]] = [
        [P(-305, 10), P(-205, 10)], [P(305, 10), P(205, 10)],
        [P(-150, -150), P(-110, -150)], [P(150, -150), P(110, -150)],
        [P(-45, -270), P(-45, -205)], [P(45, -270), P(45, -205)],
        [P(-150, 175), P(-110, 175)], [P(150, 175), P(110, 175)],
        [P(-45, 275), P(-45, 205)], [P(45, 275), P(45, 205)],
    ]
    for t in traces { stroke(line(t), ink, 13) }
    for t in traces {
        let e = t[1], r: CGFloat = 13
        let node = CGPath(ellipseIn: CGRect(x: e.x - r, y: e.y - r, width: 2 * r, height: 2 * r), transform: nil)
        fill(node, rgb(0xFFFFFF)); stroke(node, ink, 9)
    }

    // Orange data-flow arrows into the brain.
    func arrow(from a: CGPoint, ctrl: CGPoint, to b: CGPoint) {
        let p = CGMutablePath(); p.move(to: a); p.addQuadCurve(to: b, control: ctrl)
        stroke(p, orange, 22)
        let ang = atan2(b.y - ctrl.y, b.x - ctrl.x)
        let head = CGMutablePath()
        for s in [-1.0, 1.0] as [CGFloat] {
            let a2 = ang + .pi - s * 0.55
            head.move(to: b); head.addLine(to: CGPoint(x: b.x + cos(a2) * 62, y: b.y + sin(a2) * 62))
        }
        stroke(head, orange, 22)
    }
    arrow(from: CGPoint(x: 200, y: 410), ctrl: CGPoint(x: 165, y: 540), to: CGPoint(x: 232, y: 585))
    arrow(from: CGPoint(x: 824, y: 410), ctrl: CGPoint(x: 859, y: 540), to: CGPoint(x: 792, y: 585))

    // AI chip.
    let chipSide: CGFloat = 250 * s
    let chip = CGRect(x: c.x - chipSide / 2, y: c.y - chipSide / 2 + 5, width: chipSide, height: chipSide)
    for k in [-1.0, 0.0, 1.0] as [CGFloat] {
        let o = k * chipSide * 0.27
        stroke(line([CGPoint(x: chip.midX + o, y: chip.minY), CGPoint(x: chip.midX + o, y: chip.minY - 34)]), orange, 13)
        stroke(line([CGPoint(x: chip.midX + o, y: chip.maxY), CGPoint(x: chip.midX + o, y: chip.maxY + 34)]), orange, 13)
        stroke(line([CGPoint(x: chip.minX, y: chip.midY + o), CGPoint(x: chip.minX - 34, y: chip.midY + o)]), orange, 13)
        stroke(line([CGPoint(x: chip.maxX, y: chip.midY + o), CGPoint(x: chip.maxX + 34, y: chip.midY + o)]), orange, 13)
    }
    let body = CGPath(roundedRect: chip, cornerWidth: 34, cornerHeight: 34, transform: nil)
    fill(body, rgb(0xFFFFFF)); stroke(body, orange, 18)

    // "AI" label.
    ctx.saveGState()
    let font = NSFont(name: "Menlo-Bold", size: 96) ?? NSFont.monospacedSystemFont(ofSize: 96, weight: .bold)
    let str = NSAttributedString(string: "AI", attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink)!])
    let lineRef = CTLineCreateWithAttributedString(str)
    let bounds = CTLineGetImageBounds(lineRef, ctx)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: chip.midX - bounds.width / 2 - bounds.minX, y: chip.midY + bounds.height / 2 + bounds.minY)
    CTLineDraw(lineRef, ctx)
    ctx.restoreGState()
}

if mode == "mac" {
    // macOS icons aren't masked by the system: draw a rounded tile with margin and shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    fill(shape, rgb(0xCFE1F0))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.translateBy(x: 100, y: 100); ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
    drawArt()
    ctx.restoreGState()
} else {
    drawArt()
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
