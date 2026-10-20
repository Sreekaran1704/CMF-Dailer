import AppKit
import CoreText

// Draws AppIcon.icns in the app's comic style: a yellow sunburst cover with halftone dots,
// the dial as an inked, hard-shadowed knob, and a red "CLIK!" starburst.
//   swift Tools/make_icon.swift Resources/AppIcon.icns Resources/Fonts/Bangers-Regular.ttf [preview.png]
let out = CommandLine.arguments[1]
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, .process, nil)
let preview = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let ink = rgb(0x15120F), yellow = rgb(0xFFD23F), ray = rgb(0xFFB62E), dot = rgb(0xE8701F, 0.55)
let red = rgb(0xE0352B), cream = rgb(0xFFFDF5)

func starburst(_ c: CGPoint, _ r: CGFloat, spikes: Int, inner: CGFloat, rotation: CGFloat = 0) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<(spikes * 2) {
        let a = CGFloat(i) * .pi / CGFloat(spikes) + rotation
        let k = i.isMultiple(of: 2) ? 1 : inner
        let pt = CGPoint(x: c.x + cos(a) * r * k, y: c.y + sin(a) * r * k)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsctx
    let g = nsctx.cgContext
    let s = CGFloat(px)
    let small = px < 64

    // The macOS icon tile.
    let tile = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.2237, cornerHeight: tile.width * 0.2237, transform: nil)
    g.saveGState()
    g.addPath(tilePath); g.clip()
    g.setFillColor(yellow); g.fill(tile)

    // Sunburst rays from behind the dial.
    let centre = CGPoint(x: s * 0.46, y: s * 0.45)
    let rays = 24
    g.setFillColor(ray)
    for i in stride(from: 0, to: rays, by: 2) {
        let a0 = CGFloat(i) / CGFloat(rays) * 2 * .pi, a1 = CGFloat(i + 1) / CGFloat(rays) * 2 * .pi
        g.move(to: centre)
        g.addLine(to: CGPoint(x: centre.x + cos(a0) * s, y: centre.y + sin(a0) * s))
        g.addLine(to: CGPoint(x: centre.x + cos(a1) * s, y: centre.y + sin(a1) * s))
        g.closePath()
    }
    g.fillPath()

    // Halftone: dots grow toward the corners.
    if !small {
        let step = s * 0.035
        g.setFillColor(dot)
        var y = tile.minY, row = 0
        while y < tile.maxY + step {
            var x = tile.minX + (row.isMultiple(of: 2) ? 0 : step / 2)
            while x < tile.maxX + step {
                let d = hypot(x - centre.x, y - centre.y) / (s * 0.55)
                let r = step * 0.42 * min(1, max(0, d - 0.35) * 1.6)
                if r > 0.3 { g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
                x += step
            }
            y += step * 0.87
            row += 1
        }
    }
    g.restoreGState()

    // The dial: hard shadow, cream face, thick ink rim, ticks, a red pointer.
    let R = s * 0.25
    let lw = max(1.5, s * 0.03)
    g.setFillColor(ink)
    g.fillEllipse(in: CGRect(x: centre.x - R + s * 0.035, y: centre.y - R - s * 0.035, width: 2 * R, height: 2 * R))
    g.setFillColor(cream)
    g.fillEllipse(in: CGRect(x: centre.x - R, y: centre.y - R, width: 2 * R, height: 2 * R))
    if !small {
        g.saveGState()
        g.addEllipse(in: CGRect(x: centre.x - R, y: centre.y - R, width: 2 * R, height: 2 * R)); g.clip()
        g.setFillColor(rgb(0x1D5FD1, 0.22))
        let step = s * 0.026
        var y = centre.y - R
        while y < centre.y + R {
            var x = centre.x - R
            while x < centre.x + R {
                let t = (centre.y - y) / (2 * R) + 0.5
                let r = step * 0.45 * t
                if r > 0.3 { g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
                x += step
            }
            y += step
        }
        g.restoreGState()
    }
    g.setStrokeColor(ink); g.setLineWidth(lw)
    g.strokeEllipse(in: CGRect(x: centre.x - R + lw / 2, y: centre.y - R + lw / 2, width: 2 * R - lw, height: 2 * R - lw))
    if !small {
        g.setLineCap(.round)
        for i in 0..<12 {
            let a = CGFloat(i) / 12 * 2 * .pi
            let major = i.isMultiple(of: 3)
            g.setLineWidth(major ? lw * 0.75 : lw * 0.45)
            let r0 = R * (major ? 0.68 : 0.74), r1 = R * 0.84
            g.move(to: CGPoint(x: centre.x + cos(a) * r0, y: centre.y + sin(a) * r0))
            g.addLine(to: CGPoint(x: centre.x + cos(a) * r1, y: centre.y + sin(a) * r1))
            g.strokePath()
        }
    }
    // Pointer, turned toward the burst.
    g.saveGState()
    g.translateBy(x: centre.x, y: centre.y)
    g.rotate(by: -.pi / 4.5)
    let pw = R * 0.24, ph = R * 0.62
    let pointer = CGPath(roundedRect: CGRect(x: -pw / 2, y: R * 0.02, width: pw, height: ph), cornerWidth: pw / 2, cornerHeight: pw / 2, transform: nil)
    g.addPath(pointer); g.setFillColor(red); g.fillPath()
    g.addPath(pointer); g.setStrokeColor(ink); g.setLineWidth(lw * 0.7); g.strokePath()
    g.restoreGState()
    let hub = R * 0.2
    g.setFillColor(ink); g.fillEllipse(in: CGRect(x: centre.x - hub, y: centre.y - hub, width: 2 * hub, height: 2 * hub))
    g.setFillColor(yellow); g.fillEllipse(in: CGRect(x: centre.x - hub * 0.45, y: centre.y - hub * 0.45, width: hub * 0.9, height: hub * 0.9))

    // "CLIK!" burst, top right.
    let bc = CGPoint(x: s * 0.695, y: s * 0.7), br = s * (small ? 0.15 : 0.165)
    let burst = starburst(bc, br, spikes: 11, inner: 0.7, rotation: 0.2)
    g.saveGState(); g.translateBy(x: s * 0.022, y: -s * 0.022)
    g.addPath(burst); g.setFillColor(ink); g.fillPath()
    g.restoreGState()
    g.addPath(burst); g.setFillColor(red); g.fillPath()
    g.addPath(burst); g.setStrokeColor(ink); g.setLineWidth(max(1, s * 0.016)); g.setLineJoin(.round); g.strokePath()
    if px >= 128 {
        let font = NSFont(name: "Bangers-Regular", size: s * 0.085) ?? .boldSystemFont(ofSize: s * 0.08)
        let str = NSAttributedString(string: "CLIK!", attributes: [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor(cgColor: ink)!, .strokeWidth: -4.5,
        ])
        let sz = str.size()
        g.saveGState()
        g.translateBy(x: bc.x, y: bc.y)
        g.rotate(by: 0.2)
        str.draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2 + s * 0.004))
        g.restoreGState()
    }

    // Ink outline round the tile.
    g.addPath(tilePath)
    g.setStrokeColor(ink); g.setLineWidth(max(1, s * 0.022)); g.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview { try! png(512).write(to: URL(fileURLWithPath: preview)) }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
print("wrote \(out)")
