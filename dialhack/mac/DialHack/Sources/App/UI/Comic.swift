import AppKit
import CoreText
import SwiftUI

// "Comic": DialHack's design language. A comic book, not a newspaper.
// Cream page, white panels with thick ink borders and hard offset shadows, halftone dots,
// Bangers for titles and sound effects, Comic Neue for speech and captions, yellow narration boxes,
// speech bubbles and starbursts. Light = the "Day issue"; dark = the "Midnight issue" (its own steps,
// not an automatic flip).

enum CK {
    // MARK: fonts (bundled in Resources/Fonts, registered at launch)

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    /// Bangers: titles, sound effects, big numbers, buttons.
    static func title(_ size: CGFloat) -> Font { .custom("Bangers-Regular", size: size) }
    /// Comic Neue: everything people read in sentences.
    static func body(_ size: CGFloat = 15) -> Font { .custom("ComicNeue-Regular", size: size) }
    static func bodyBold(_ size: CGFloat = 15) -> Font { .custom("ComicNeue-Bold", size: size) }
    static func bodyItalic(_ size: CGFloat = 15) -> Font { .custom("ComicNeue-Italic", size: size) }
    /// Caption lettering: Comic Neue Bold, used uppercase.
    static func label(_ size: CGFloat = 11) -> Font { .custom("ComicNeue-Bold", size: size) }

    // MARK: colours

    private static func dyn(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light).withAlphaComponent(alpha)
        })
    }

    private static func fixed(_ hex: UInt32) -> Color { Color(nsColor: NSColor(hex: hex)) }

    // Day: cream comic stock. Night: warm, lamp-lit dark paper (brown-black, not blue), cream lettering,
    // near-black ink lines, so panels read as printed cards rather than glowing outlines.
    static let page = dyn(0xFFF3D6, 0x1C1813)       // the comic's paper
    static let panel = dyn(0xFFFDF5, 0x352D24)      // inside a panel (chart surface: validated against these)
    static let panelDeep = dyn(0xFBE9C0, 0x40362B)
    static let ink = dyn(0x15120F, 0xF0E5CC)        // lettering
    static let line = dyn(0x15120F, 0x0B0806)       // panel borders and outlines
    static let inkSoft = dyn(0x2E2925, 0xDDD0B5)
    static let muted = dyn(0x6A6155, 0xAE9F83)
    static let hairline = dyn(0x15120F, 0xF0E5CC, alpha: 0.16)
    static let shadow = dyn(0x15120F, 0x070504)     // hard offset shadows
    static let dots = dyn(0x15120F, 0xF0E5CC, alpha: 0.06)
    static let bubble = dyn(0xFFFFFF, 0xEFE4CB)     // speech bubbles: white by day, old paper at night

    /// Knocks big colour fills back at night so they sit on the dark paper instead of glowing.
    static let dim = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.black.withAlphaComponent(0.28) : .clear
    })

    // Four-colour-press primaries, with night steps.
    static let yellow = dyn(0xFFD23F, 0xE2B43C)     // narration boxes and highlights (always dark text on it)
    static let onYellow = fixed(0x15120F)
    static let blue = dyn(0x1D5FD1, 0x4F8AE6)
    static let red = dyn(0xE0352B, 0xE8564C)
    static let green = dyn(0x1F9D55, 0x3FBF72)
    static let teal = dyn(0x0E8FA3, 0x2FB3C6)
    static let purple = dyn(0x7A3FC8, 0xA07AE0)
    static let orange = dyn(0xD9611A, 0xD57627)
    static let magenta = dyn(0xC2307A, 0xD9609F)
    static let white = fixed(0xFFFFFF)

    static let primaries = [red, yellow, blue, green, purple, orange, magenta]

    // Chart palettes, validated with the data-viz validator (light on #fffdf5, dark on #221e30):
    // (dark re-checked on the night paper #352d24): clusters blue/orange/magenta pass all-pairs in both;
    // timeline blue/red pass adjacent in both.
    static let series = [blue, orange, magenta]
    static let restless = red
    static let other = dyn(0x8A8378, 0x7A7390)
    static let heatLight: [Color] = [0xE6EEFB, 0xBFD3F4, 0x8FB1EA, 0x5B8AE0, 0x1D5FD1, 0x15489F, 0x0D306B].map(fixed)
    static let heatDark: [Color] = [0x252B45, 0x24406F, 0x2A5596, 0x3B70C4, 0x4F8AE6, 0x8DB3F0, 0xC6D9F8].map(fixed)

    static func modeColor(_ m: ModeID) -> Color {
        switch m {
        case .passthrough: return blue
        case .scroll: return green
        case .scrub: return orange
        case .comboLock: return purple
        case .macro: return teal
        case .focusTimer: return red
        }
    }

    /// The sound a dial event makes, for the SFX strip.
    static func sfx(_ event: String) -> String {
        switch event {
        case "ROTATE_CW": return "Tik!"
        case "ROTATE_CCW": return "Tak!"
        case "PRESS_1": return "Clik!"
        case "PRESS_2": return "Clik-clik!"
        case "PRESS_3": return "Ka-chunk!"
        default: return "Bzzt!"
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// MARK: - shapes

/// Spiky "POW!" burst.
struct Starburst: Shape {
    var spikes = 12
    var inner: CGFloat = 0.72

    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        for i in 0..<(spikes * 2) {
            let a = Double(i) * .pi / Double(spikes) - .pi / 2
            let k = i.isMultiple(of: 2) ? 1 : inner
            let pt = CGPoint(x: c.x + cos(a) * r.width / 2 * k, y: c.y + sin(a) * r.height / 2 * k)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

/// Speech bubble with a tail on the left or bottom.
struct Bubble: InsettableShape {
    enum Tail { case left, bottomLeading, none }
    var tail: Tail = .left
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let tailSize: CGFloat = 14
        var body = r
        switch tail {
        case .left: body.origin.x += tailSize; body.size.width -= tailSize
        case .bottomLeading: body.size.height -= tailSize
        case .none: break
        }
        var p = Path(roundedRect: body, cornerRadius: min(22, body.height / 2), style: .continuous)
        var t = Path()
        switch tail {
        case .left:
            t.move(to: CGPoint(x: body.minX + 2, y: body.midY - 9))
            t.addLine(to: CGPoint(x: r.minX, y: body.midY + 12))
            t.addLine(to: CGPoint(x: body.minX + 2, y: body.midY + 5))
        case .bottomLeading:
            t.move(to: CGPoint(x: body.minX + 26, y: body.maxY - 2))
            t.addLine(to: CGPoint(x: body.minX + 18, y: r.maxY))
            t.addLine(to: CGPoint(x: body.minX + 44, y: body.maxY - 2))
        case .none: break
        }
        p.addPath(t)
        return p
    }

    func inset(by amount: CGFloat) -> Bubble { var b = self; b.inset += amount; return b }
}

/// Halftone dot field: dots grow along a diagonal, like a printed shade.
struct Halftone: View {
    var color: Color = CK.dots
    var spacing: CGFloat = 9
    var minRadius: CGFloat = 0.6
    var maxRadius: CGFloat = 2.6
    var fade = true

    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0, row = 0
            while y < size.height + spacing {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : spacing / 2
                while x < size.width + spacing {
                    let t = fade ? min(1, max(0, (x / max(size.width, 1) + y / max(size.height, 1)) / 2)) : 1
                    let rad = minRadius + (maxRadius - minRadius) * t
                    ctx.fill(Path(ellipseIn: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)), with: .color(color))
                    x += spacing
                }
                y += spacing * 0.87
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - paper texture

/// Printed-paper grain: specks, fibres and faint mottling, generated once (seeded, so it never shimmers)
/// and tiled. Dark specks deepen the paper by day; at night light specks and fibres catch the lamp.
enum PaperTexture {
    static let size = 384
    static let day = make(dark: false)
    static let night = make(dark: true)

    private struct RNG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
    }

    private static func make(dark: Bool) -> NSImage {
        let n = size, S = CGFloat(n)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let g = NSGraphicsContext.current!.cgContext
        var r = RNG(s: 0xD1A1_4AC2)
        let deep = CGColor(srgbRed: 0.24, green: 0.17, blue: 0.09, alpha: 1)    // sepia, not grey
        let light = CGColor(srgbRed: 1, green: 0.95, blue: 0.84, alpha: 1)

        // Mottling: big soft blotches, drawn wrapped so the tile has no seams.
        for _ in 0..<26 {
            let x = r.next() * S, y = r.next() * S, rad = 50 + r.next() * 110
            let useLight = r.next() < 0.5
            let a = (dark ? (useLight ? 0.03 : 0.018) : 0.014) * (0.4 + r.next())
            let c = (useLight ? light : deep).copy(alpha: a)!
            let grad = CGGradient(colorsSpace: nil, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            for dx in [-S, 0, S] { for dy in [-S, 0, S] {
                let p = CGPoint(x: x + dx, y: y + dy)
                g.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: rad, options: [])
            } }
        }
        // Fibres: short, slightly curved strands.
        g.setLineCap(.round)
        for _ in 0..<(dark ? 150 : 110) {
            let x = 12 + r.next() * (S - 24), y = 12 + r.next() * (S - 24)
            let ang = r.next() * .pi * 2, len = 4 + r.next() * 11
            let bend = (r.next() - 0.5) * 6
            let useLight = dark ? r.next() < 0.7 : r.next() < 0.25
            g.setStrokeColor((useLight ? light : deep).copy(alpha: (dark ? 0.10 : 0.07) * (0.5 + r.next()))!)
            g.setLineWidth(0.5 + r.next() * 0.5)
            g.move(to: CGPoint(x: x, y: y))
            g.addQuadCurve(to: CGPoint(x: x + cos(ang) * len, y: y + sin(ang) * len),
                           control: CGPoint(x: x + cos(ang) * len / 2 - sin(ang) * bend, y: y + sin(ang) * len / 2 + cos(ang) * bend))
            g.strokePath()
        }
        // Grain: single specks.
        for _ in 0..<(n * n / 7) {
            let x = (r.next() * S).rounded(.down), y = (r.next() * S).rounded(.down)
            let useLight = dark ? r.next() < 0.55 : r.next() < 0.2
            let a = (useLight ? (dark ? 0.07 : 0.10) : (dark ? 0.10 : 0.06)) * (0.3 + r.next())
            g.setFillColor((useLight ? light : deep).copy(alpha: a)!)
            g.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: n / 2, height: n / 2))   // @2x: one speck per device pixel
        img.addRepresentation(rep)
        return img
    }
}

struct PaperGrain: View {
    var strength: Double = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: scheme == .dark ? PaperTexture.night : PaperTexture.day)
            .resizable(resizingMode: .tile)
            .opacity(min(1, strength))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The page itself: paper colour, grain, and a soft vignette toward the edges like a well-thumbed book.
struct PaperPage: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            CK.page
            PaperGrain(strength: 1)
            RadialGradient(colors: [.clear, Color(nsColor: NSColor(hex: scheme == .dark ? 0x000000 : 0x7A5A2A)).opacity(scheme == .dark ? 0.45 : 0.12)],
                           center: .center, startRadius: 280, endRadius: 980)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - panel modifier (ink border + hard shadow)

extension View {
    func comicPanel(fill: Color = CK.panel, border: CGFloat = 3, shadow: CGFloat = 6, shadowColor: Color = CK.shadow) -> some View {
        background(PaperGrain(strength: 1))
            .background(fill)
            .overlay(Rectangle().strokeBorder(CK.line, lineWidth: border))
            .background(Rectangle().fill(shadowColor).offset(x: shadow, y: shadow))
    }

    func comicPage() -> some View {
        frame(maxWidth: 1080)
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - lettering

/// Uppercase caption lettering ("CHAPTER 2", table headers, small labels).
struct Caps: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = CK.ink

    init(_ text: String, size: CGFloat = 11, color: Color = CK.ink) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(CK.label(size))
            .tracking(size * 0.06)
            .foregroundStyle(color)
    }
}

/// A sound effect: Bangers, coloured fill, ink outline, hard shadow, a little tilt.
struct SFX: View {
    let text: String
    var size: CGFloat = 40
    var fill: Color = CK.yellow
    var outline: Color = CK.shadow
    var tilt: Double = -3

    var body: some View {
        let t = Text(text.uppercased()).font(CK.title(size)).tracking(size * 0.03)
        let w = max(1.2, size / 22)
        ZStack {
            t.foregroundStyle(outline).offset(x: w * 2.4, y: w * 2.4)
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                t.foregroundStyle(outline).offset(x: cos(a) * w, y: sin(a) * w)
            }
            t.foregroundStyle(fill)
        }
        .rotationEffect(.degrees(tilt))
        .fixedSize()
    }
}

struct Hairline: View {
    var color: Color = CK.hairline
    var height: CGFloat = 1
    var body: some View { Rectangle().fill(color).frame(height: height) }
}

// MARK: - chapter header (a splash panel)

struct ChapterHeader: View {
    let number: Int
    let name: String
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(color)
            Halftone(color: Color.black.opacity(0.22), spacing: 10, minRadius: 0.4, maxRadius: 3.4)
            ActionLines().stroke(Color.white.opacity(0.18), lineWidth: 2)
            CK.dim
            PaperGrain(strength: 1.4)
            HStack(alignment: .center, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Narration(text: "Chapter \(number) · \(name)").rotationEffect(.degrees(-2))
                    SFX(text: title, size: 58, fill: CK.white, tilt: -2.5)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 10)
                Text(subtitle)
                    .font(CK.bodyBold(15))
                    .foregroundStyle(CK.onYellow)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30).padding(.trailing, 18).padding(.vertical, 14)
                    .frame(maxWidth: 360, alignment: .leading)
                    .background(Bubble(tail: .left).fill(CK.bubble))
                    .overlay(Bubble(tail: .left).stroke(CK.onYellow, lineWidth: 2.5))
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
        }
        .frame(minHeight: 150)
        .clipped()
        .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 3.5))
        .background(Rectangle().fill(CK.shadow).offset(x: 7, y: 7))
        .padding(.bottom, 8)
    }
}

/// Speed lines radiating from the right edge of a splash panel.
struct ActionLines: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.maxX + r.width * 0.15, y: r.midY)
        for i in 0..<18 {
            let a = Double.pi * (0.62 + Double(i) * 0.042)
            let len = r.width * 1.3
            let inner = r.width * (0.55 + 0.12 * Double(i % 3))
            p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner * 0.55))
            p.addLine(to: CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len * 0.55))
        }
        return p
    }
}

/// Yellow narration box ("CHAPTER 2 · FOCUS", "MEANWHILE…").
struct Narration: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        Text(text.uppercased())
            .font(CK.label(size))
            .tracking(size * 0.08)
            .foregroundStyle(CK.onYellow)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(CK.yellow)
            .overlay(Rectangle().strokeBorder(CK.onYellow, lineWidth: 2))
            .fixedSize()
    }
}

/// In-page heading: a Bangers title on a coloured tab, with an optional aside.
struct SubHead: View {
    let text: String
    var color: Color = CK.blue
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(text.uppercased())
                .font(CK.title(22)).tracking(1)
                .foregroundStyle(CK.white)
                .padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 3)
                .background(color)
                .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2.5))
                .background(Rectangle().fill(CK.shadow).offset(x: 3, y: 3))
                .rotationEffect(.degrees(-1.2))
            Rectangle().fill(CK.ink).frame(height: 2.5)
            if let trailing {
                Text(trailing).font(CK.bodyItalic(13)).foregroundStyle(CK.muted).layoutPriority(1)
            }
        }
    }
}

// MARK: - panels

/// A comic panel: white, thick ink border, hard shadow, a caption in the corner and an optional burst.
struct Panel<Content: View>: View {
    var number: String? = nil
    let kicker: String
    let color: Color
    var badge: String? = nil
    var title: String? = nil
    var emphasized = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                Text(((number.map { "#\($0) · " } ?? "") + kicker).uppercased())
                    .font(CK.label(11)).tracking(0.9)
                    .foregroundStyle(CK.onYellow)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(CK.yellow)
                    .overlay(Rectangle().strokeBorder(CK.onYellow, lineWidth: 2))
                    .offset(x: -18, y: -18)
                    .padding(.bottom, -14)
                Spacer(minLength: 8)
                if let badge { Sticker(text: badge, color: color).offset(x: 12, y: -16).padding(.bottom, -14) }
            }
            if let title {
                Text(title.uppercased()).font(CK.title(28)).tracking(0.6).foregroundStyle(CK.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            Halftone(color: color.opacity(0.16), spacing: 8, minRadius: 0, maxRadius: 2.4).frame(width: 150, height: 90)
        }
        .comicPanel(border: emphasized ? 4 : 3, shadow: emphasized ? 8 : 6, shadowColor: emphasized ? color : CK.shadow)
    }
}

/// A tilted sticker ("ON AIR!", "k = 3", "NOT ENOUGH DATA").
struct Sticker: View {
    let text: String
    var color: Color = CK.red
    var tilt: Double = 3

    var body: some View {
        Text(text.uppercased())
            .font(CK.title(15)).tracking(0.8)
            .foregroundStyle(CK.white)
            .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 2)
            .background(color)
            .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2))
            .background(Rectangle().fill(CK.shadow).offset(x: 2.5, y: 2.5))
            .rotationEffect(.degrees(tilt))
            .fixedSize()
    }
}

/// A starburst with a word in it ("LIVE!", "POW!").
struct Burst: View {
    let text: String
    var color: Color = CK.red
    var size: CGFloat = 64
    var textColor: Color = CK.white

    var body: some View {
        ZStack {
            Starburst(spikes: 12, inner: 0.74).fill(CK.shadow).offset(x: 3, y: 3)
            Starburst(spikes: 12, inner: 0.74).fill(color)
            Starburst(spikes: 12, inner: 0.74).stroke(CK.line, lineWidth: 2.5)
            Text(text.uppercased()).font(CK.title(size * 0.27)).foregroundStyle(textColor).rotationEffect(.degrees(-8))
        }
        .frame(width: size, height: size * 0.8)
    }
}

/// Yellow narration callout (was "Key finding"): Bangers label, bold Comic Neue text.
struct CaptionBox: View {
    var label = "Key finding"
    let text: String
    var color: Color = CK.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(CK.title(17)).tracking(0.8).foregroundStyle(CK.onYellow)
            Text(text).font(CK.bodyBold(14.5)).foregroundStyle(CK.onYellow).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CK.yellow)
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 7) }
        .overlay(Rectangle().strokeBorder(CK.onYellow, lineWidth: 2))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line of speech: a bubble with the text in it.
struct Speech: View {
    let text: String
    var size: CGFloat = 14

    var body: some View {
        Text(text)
            .font(CK.bodyBold(size)).foregroundStyle(CK.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 24)
            .background(Bubble(tail: .bottomLeading).fill(CK.bubble))
            .overlay(Bubble(tail: .bottomLeading).stroke(CK.line, lineWidth: 2.5))
    }
}

/// Status line: icon in an inked circle + text, never colour alone.
struct StatusLine: View {
    enum Kind { case good, warning, bad, info }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(kind == .info ? CK.ink : CK.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(color))
                .overlay(Circle().strokeBorder(CK.line, lineWidth: 2))
            Text(text).font(CK.bodyBold(14.5)).foregroundStyle(CK.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var icon: String {
        switch kind {
        case .good: return "checkmark"
        case .warning: return "exclamationmark"
        case .bad: return "xmark"
        case .info: return "info"
        }
    }

    private var color: Color {
        switch kind {
        case .good: return CK.green
        case .warning: return CK.orange
        case .bad: return CK.red
        case .info: return CK.yellow
        }
    }
}

// MARK: - stats (a strip of small panels)

struct BigStat: Identifiable {
    var id: String { label }
    let value: String
    let label: String
    var color: Color = CK.blue
    var note: String? = nil
}

struct StatRow: View {
    let stats: [BigStat]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.value).font(CK.title(42)).foregroundStyle(s.color).lineLimit(1).minimumScaleFactor(0.5)
                    Caps(s.label, size: 10.5, color: CK.inkSoft).fixedSize(horizontal: false, vertical: true)
                    if let note = s.note { Text(note).font(CK.bodyItalic(12)).foregroundStyle(CK.muted) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(alignment: .topTrailing) {
                    Halftone(color: s.color.opacity(0.22), spacing: 7, minRadius: 2.2, maxRadius: 0, fade: true).frame(width: 60, height: 50)
                }
                .comicPanel(border: 2.5, shadow: 4)
                .rotationEffect(.degrees(i.isMultiple(of: 2) ? -0.6 : 0.6))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 4)
    }
}

// MARK: - controls

struct ComicButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, link }
    var kind: Kind = .primary
    var color: Color = CK.yellow

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        switch kind {
        case .primary, .secondary:
            let fill = kind == .primary ? color : CK.panel
            let text: Color = kind == .secondary ? CK.ink : (color == CK.yellow ? CK.onYellow : CK.white)
            return AnyView(configuration.label
                .font(CK.title(17)).tracking(0.9).textCase(.uppercase)
                .foregroundStyle(text)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
                .background(fill)
                .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2.5))
                .background(Rectangle().fill(CK.shadow).offset(x: pressed ? 0 : 4, y: pressed ? 0 : 4))
                .offset(x: pressed ? 3 : 0, y: pressed ? 3 : 0)
                .contentShape(Rectangle()))
        case .link:
            return AnyView(configuration.label
                .font(CK.bodyBold(13.5))
                .foregroundStyle(CK.blue)
                .underline(true, color: CK.blue)
                .opacity(pressed ? 0.6 : 1)
                .contentShape(Rectangle()))
        }
    }
}

extension ButtonStyle where Self == ComicButtonStyle {
    static var comic: ComicButtonStyle { ComicButtonStyle() }
    static var comicSecondary: ComicButtonStyle { ComicButtonStyle(kind: .secondary) }
    static var comicLink: ComicButtonStyle { ComicButtonStyle(kind: .link) }
}

/// Joined buttons; the chosen one is filled.
struct ComicSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var color: Color = CK.red

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                let on = selection == o.0
                Button { selection = o.0 } label: {
                    Text(o.1.uppercased())
                        .font(CK.title(15)).tracking(0.7)
                        .foregroundStyle(on ? CK.white : CK.ink)
                        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 5)
                        .background(on ? color : CK.panel)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < options.count - 1 { Rectangle().fill(CK.line).frame(width: 2) }
            }
        }
        .fixedSize()
        .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2.5))
        .background(Rectangle().fill(CK.shadow).offset(x: 4, y: 4))
    }
}

/// Chunky inked checkbox.
struct ComicToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack {
                    Rectangle().fill(configuration.isOn ? CK.yellow : CK.panel)
                    Rectangle().strokeBorder(CK.line, lineWidth: 2.5)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .black)).foregroundStyle(CK.onYellow)
                    }
                }
                .frame(width: 22, height: 22)
                .background(Rectangle().fill(CK.shadow).offset(x: 2.5, y: 2.5))
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// − value + stepper.
struct ComicStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            box("−") { set(max(range.lowerBound, value - step)) }
            Rectangle().fill(CK.line).frame(width: 2)
            Text("\(value)\(unit)")
                .font(CK.title(17)).tracking(0.5).monospacedDigit()
                .frame(minWidth: 70)
                .padding(.top, 5).padding(.bottom, 3)
                .background(CK.panel)
            Rectangle().fill(CK.line).frame(width: 2)
            box("+") { set(min(range.upperBound, value + step)) }
        }
        .fixedSize()
        .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2.5))
        .background(Rectangle().fill(CK.shadow).offset(x: 3, y: 3))
    }

    private func box(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: s == "−" ? "minus" : "plus").font(.system(size: 12, weight: .black)).frame(width: 32, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CK.onYellow)
        .background(CK.yellow)
    }
}

/// Field with an inked border.
struct ComicField: View {
    @Binding var text: String
    var width: CGFloat = 160

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(CK.bodyBold(14)).monospacedDigit()
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(width: width)
            .background(CK.panel)
            .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2.5))
            .background(Rectangle().fill(CK.shadow).offset(x: 3, y: 3))
    }
}

/// Table: an ink header band and striped rows inside an inked frame.
struct ComicTable<Row: Identifiable, Cells: View>: View {
    let columns: [(String, CGFloat?)]   // title, fixed width (nil = flexible)
    let rows: [Row]
    var empty = "Nothing here yet."
    @ViewBuilder let cells: (Row) -> Cells

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                    Text(c.0.uppercased()).font(CK.title(14)).tracking(0.8).foregroundStyle(CK.page)
                        .frame(width: c.1, alignment: .leading)
                        .frame(maxWidth: c.1 == nil ? .infinity : nil, alignment: .leading)
                }
            }
            .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 5)
            .background(CK.ink)
            if rows.isEmpty {
                Text(empty).font(CK.bodyItalic(14)).foregroundStyle(CK.muted).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 12) { cells(r) }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(i.isMultiple(of: 2) ? CK.panel : CK.panelDeep.opacity(0.55))
                }
            }
        }
        .background(CK.panel)
        .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2.5))
    }
}

/// A table cell honouring the column width.
struct Cell<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .lineLimit(1)
    }
}
