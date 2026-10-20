import SwiftUI

extension AppUI.Section {
    var color: Color {
        switch self {
        case .dial: return CK.blue
        case .focus: return CK.red
        case .activity: return CK.green
        case .insights: return CK.purple
        case .settings: return CK.orange
        }
    }

    var navTitle: String {
        switch self {
        case .dial: return "The Dial"
        case .focus: return "Focus"
        case .activity: return "The Log"
        case .insights: return "Insights"
        case .settings: return "Settings"
        }
    }

    var chapter: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

struct MainWindow: View {
    @ObservedObject var c: Coordinator
    @ObservedObject var ui = AppUI.shared
    @ObservedObject var insights = InsightsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Cover(c: c, ui: ui)
            ScrollView {
                Group {
                    switch ui.section ?? .dial {
                    case .dial: DialView(c: c)
                    case .focus: FocusView(c: c, insights: insights)
                    case .activity: ActivityView(c: c, insights: insights)
                    case .insights: InsightsView(model: insights)
                    case .settings: SettingsPane(c: c)
                    }
                }
                .comicPage()
            }
        }
        .background(PaperPage())
        .foregroundStyle(CK.ink)
        .tint(CK.blue)
        .frame(minWidth: 940, minHeight: 640)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { insights.refresh() }
    }
}

// MARK: - cover: logo, issue box, chapter tabs, SFX strip

struct Cover: View {
    @ObservedObject var c: Coordinator
    @ObservedObject var ui: AppUI

    private var issue: Int { Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(CK.yellow)
                Halftone(color: Color(nsColor: NSColor(hex: 0xF08A24)).opacity(0.55), spacing: 9, minRadius: 0.3, maxRadius: 3.6)
                SunRays().fill(Color.white.opacity(0.22))
                CK.dim.opacity(0.6)
                PaperGrain(strength: 1)
                HStack(alignment: .center) {
                    issueBox.frame(width: 190, alignment: .leading)
                    Spacer()
                    VStack(spacing: 2) {
                        SFX(text: "DialHack", size: 56, fill: CK.red, outline: CK.onYellow, tilt: -3)
                        Text("THE ADVENTURES OF A VERY SMALL DIAL")
                            .font(CK.label(11)).tracking(1.6).foregroundStyle(CK.onYellow)
                            .padding(.top, 2)
                    }
                    Spacer()
                    modeBurst.frame(width: 190, alignment: .trailing)
                }
                .padding(.horizontal, 32)
                .padding(.top, 30)      // room for the traffic lights (hidden title bar)
                .padding(.bottom, 14)
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottom) { Rectangle().fill(CK.onYellow).frame(height: 3.5) }
            .clipped()

            tabs
            SFXStrip(c: c)
        }
    }

    private var issueBox: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("ISSUE #\(issue)").font(CK.title(20)).tracking(0.8).foregroundStyle(CK.onYellow)
            Text(Date(), format: .dateTime.weekday(.wide).month().day())
                .font(CK.bodyBold(11.5)).foregroundStyle(CK.onYellow)
            Text("FREE · LOCAL ONLY").font(CK.label(9.5)).tracking(1).foregroundStyle(CK.white)
                .padding(.horizontal, 5).padding(.vertical, 2).background(CK.red).padding(.top, 3)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(CK.bubble)
        .overlay(Rectangle().strokeBorder(CK.onYellow, lineWidth: 2.5))
        .background(Rectangle().fill(CK.onYellow).offset(x: 4, y: 4))
        .rotationEffect(.degrees(-2))
    }

    private var modeBurst: some View {
        ZStack {
            Starburst(spikes: 14, inner: 0.78).fill(CK.onYellow).offset(x: 4, y: 4)
            Starburst(spikes: 14, inner: 0.78).fill(CK.modeColor(c.mode))
            Starburst(spikes: 14, inner: 0.78).stroke(CK.onYellow, lineWidth: 2.5)
            VStack(spacing: 0) {
                Text(c.focusClock != nil ? "FOCUS" : "NOW").font(CK.label(10)).tracking(1.2).foregroundStyle(CK.white)
                Text((c.focusClock ?? c.mode.title).uppercased())
                    .font(CK.title(c.focusClock != nil ? 24 : 19)).foregroundStyle(CK.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: 104)
            }
            .rotationEffect(.degrees(6))
        }
        .frame(width: 150, height: 104)
    }

    private var tabs: some View {
        HStack(spacing: 14) {
            ForEach(AppUI.Section.allCases, id: \.self) { s in
                let on = (ui.section ?? .dial) == s
                Button { ui.section = s } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("CH.\(s.chapter)").font(CK.label(10)).tracking(0.8)
                            .foregroundStyle(on ? CK.white.opacity(0.85) : CK.muted)
                        Text(s.navTitle.uppercased()).font(CK.title(19)).tracking(0.9)
                            .foregroundStyle(on ? CK.white : CK.ink)
                    }
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
                    .background(on ? AnyView(ZStack { s.color; CK.dim }) : AnyView(CK.panel))
                    .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2.5))
                    .background(Rectangle().fill(CK.shadow).offset(x: on ? 5 : 3, y: on ? 5 : 3))
                    .rotationEffect(.degrees(on ? -2 : 0))
                    .offset(y: on ? -2 : 0)
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

/// Rays from the centre of the cover.
struct SunRays: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY + 10)
        let n = 28
        let rad = max(r.width, r.height)
        for i in 0..<n where i.isMultiple(of: 2) {
            let a0 = Double(i) / Double(n) * 2 * .pi
            let a1 = Double(i + 1) / Double(n) * 2 * .pi
            p.move(to: c)
            p.addLine(to: CGPoint(x: c.x + cos(a0) * rad, y: c.y + sin(a0) * rad))
            p.addLine(to: CGPoint(x: c.x + cos(a1) * rad, y: c.y + sin(a1) * rad))
            p.closeSubpath()
        }
        return p
    }
}

/// The live strip: every dial input as a sound effect.
struct SFXStrip: View {
    @ObservedObject var c: Coordinator
    private let colors = [CK.red, CK.blue, CK.green, CK.purple, CK.orange, CK.magenta]

    var body: some View {
        HStack(spacing: 14) {
            Burst(text: "Live!", color: CK.red, size: 58)
            if c.recent.isEmpty {
                Text("Turn or press the dial… it'll go TIK! and CLIK! right here.")
                    .font(CK.bodyBold(13.5)).foregroundStyle(CK.inkSoft)
            } else {
                HStack(spacing: 12) {
                    ForEach(Array(c.recent.prefix(7).enumerated()), id: \.element.id) { i, r in
                        Text(CK.sfx(r.event).uppercased())
                            .font(CK.title(i == 0 ? 22 : 17)).tracking(0.6)
                            .foregroundStyle(colors[abs(r.id.hashValue) % colors.count])
                            .rotationEffect(.degrees(i.isMultiple(of: 2) ? -5 : 4))
                            .opacity(1 - Double(i) * 0.1)
                            .help("\(r.event) → \(r.action.replacingOccurrences(of: "_", with: " "))")
                    }
                }
                .lineLimit(1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: c.recent.first?.id)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if !c.pressRoute.ok { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(CK.orange) }
                Caps(c.pressRoute.ok ? "Presses go to \(c.mode.hijacks ? "DialHack" : "your music")" : "Presses going elsewhere",
                     size: 10.5, color: c.pressRoute.ok ? CK.muted : CK.orange)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 4)
        .frame(height: 58)
        .background(PaperGrain(strength: 1))
        .background(CK.panel)
        .overlay(alignment: .top) { Rectangle().fill(CK.line).frame(height: 2.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(CK.line).frame(height: 2.5) }
    }
}

// MARK: - Chapter 1: the dial

struct DialFace: View {
    let angle: Double
    let mode: ModeID
    let pressCount: Int
    let last: RecentInput?

    var body: some View {
        ZStack {
            Circle().fill(CK.shadow).offset(x: 7, y: 7)
            Circle().fill(CK.panel)
            Halftone(color: CK.modeColor(mode).opacity(0.28), spacing: 8, minRadius: 0.2, maxRadius: 3)
                .clipShape(Circle())
            Circle().strokeBorder(CK.line, lineWidth: 4.5)
            Circle().strokeBorder(CK.line.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 5])).padding(16)
            ForEach(0..<16, id: \.self) { i in
                Capsule()
                    .fill(CK.ink)
                    .frame(width: i % 4 == 0 ? 5 : 3, height: i % 4 == 0 ? 16 : 9)
                    .offset(y: -86)
                    .rotationEffect(.degrees(Double(i) * 22.5))
            }
            Capsule()
                .fill(CK.modeColor(mode))
                .overlay(Capsule().strokeBorder(CK.line, lineWidth: 2.5))
                .frame(width: 13, height: 50)
                .offset(y: -50)
                .rotationEffect(.degrees(angle))
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: angle)
            VStack(spacing: 0) {
                Text(mode.title.uppercased()).font(CK.title(22)).tracking(0.6)
                Caps("\(pressCount) presses", size: 10, color: CK.inkSoft)
            }
            .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 3)
            .background(CK.panel)
            .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2))
            .offset(y: 26)
        }
        .frame(width: 210, height: 210)
        .overlay(alignment: .topTrailing) {
            if let last {
                Burst(text: CK.sfx(last.event), color: CK.yellow, size: 92, textColor: CK.onYellow)
                    .id(last.id)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .offset(x: 40, y: -26)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.5), value: last?.id)
    }
}

struct DialView: View {
    @ObservedObject var c: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            ChapterHeader(number: 1, name: "The Dial", title: "The Dial!",
                          subtitle: "Our hero: one tiny dial on a charging case. Here's what it's up to and where every turn and press lands.",
                          color: CK.blue)

            HStack(alignment: .top, spacing: 26) {
                Panel(number: "1", kicker: "Now on the dial", color: CK.modeColor(c.mode), badge: "On air!") {
                    HStack(alignment: .center, spacing: 34) {
                        DialFace(angle: c.dialAngle, mode: c.mode, pressCount: c.pressCount, last: c.recent.first)
                            .padding(.vertical, 12).padding(.leading, 6)
                        VStack(alignment: .leading, spacing: 10) {
                            SFX(text: c.mode.title, size: 46, fill: CK.modeColor(c.mode), tilt: -2)
                            Text(c.mode.hint).font(CK.body(15.5)).foregroundStyle(CK.inkSoft).fixedSize(horizontal: false, vertical: true)
                            if let clock = c.focusClock {
                                CaptionBox(label: "Focus running", text: "\(clock) left on the clock.", color: CK.red)
                            }
                            Text(c.mode == .passthrough && c.config.pickerGesture != .wiggle
                                 ? "In Passthrough your presses control your music, so switch powers with the cards below or the menu bar."
                                 : "Switch powers on the dial: \(c.config.pickerGesture.title.lowercased()).")
                                .font(CK.bodyItalic(13.5)).foregroundStyle(CK.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Panel(number: "2", kicker: "Status report", color: CK.green) {
                    VStack(alignment: .leading, spacing: 11) {
                        StatusLine(kind: c.device.matches ? .good : .bad,
                                   text: c.device.matches ? "Dial active on \(c.device.name)" : "Dial inactive: output is \(c.device.name)")
                        StatusLine(kind: c.pressRoute.ok ? .good : .warning, text: c.pressRoute.text)
                        StatusLine(kind: c.accessibilityTrusted ? .good : .bad,
                                   text: c.accessibilityTrusted ? "Accessibility allowed, so actions work" : "Accessibility needed for actions")
                        if !c.accessibilityTrusted {
                            Button("Allow Accessibility!") { c.requestAccessibility() }.buttonStyle(.comic)
                        }
                        Hairline().padding(.vertical, 2)
                        PressTestRow(c: c)
                    }
                }
                .frame(width: 340)
            }

            VStack(alignment: .leading, spacing: 20) {
                SubHead(text: "Pick a power", color: CK.blue, trailing: "Click one, or use the dial")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: 3), spacing: 26) {
                    ForEach(ModeID.allCases, id: \.self) { m in
                        Button { c.selectMode(m) } label: {
                            Panel(kicker: m.hijacks ? "Dial power" : "Normal", color: CK.modeColor(m),
                                  badge: m == c.mode ? "On air!" : nil, title: m.title, emphasized: m == c.mode) {
                                Text(m.hint).font(CK.body(14)).foregroundStyle(CK.inkSoft)
                                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Panel(kicker: "Meanwhile, on the wire…", color: CK.red, badge: "Live") {
                if c.recent.isEmpty {
                    Text("Nothing yet. Turn or press the dial and it shows up here.").font(CK.bodyItalic(14)).foregroundStyle(CK.muted)
                } else {
                    ComicTable(columns: [("Time", 90), ("Sound", 120), ("Power", 110), ("Input", 120), ("Action", nil)], rows: Array(c.recent.prefix(10))) { r in
                        Cell(width: 90) { Text(r.time, format: .dateTime.hour().minute().second()).font(CK.body(12.5)).monospacedDigit().foregroundStyle(CK.muted) }
                        Cell(width: 120) { Text(CK.sfx(r.event).uppercased()).font(CK.title(16)).tracking(0.5).foregroundStyle(CK.modeColor(r.mode)) }
                        Cell(width: 110) { Caps(r.mode.title, size: 10.5, color: CK.inkSoft) }
                        Cell(width: 120) { Text(r.event).font(CK.label(11.5)) }
                        Cell { Text(r.action.replacingOccurrences(of: "_", with: " ")).font(CK.body(14)) }
                    }
                }
            }
        }
    }
}

struct PressTestRow: View {
    @ObservedObject var c: Coordinator

    var body: some View {
        switch c.pressTest {
        case .idle:
            Button("Check my presses") { c.startPressTest() }.buttonStyle(.comicSecondary)
        case .waiting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Press the dial once now…").font(CK.bodyBold(14))
                Button("Cancel") { c.resetPressTest() }.buttonStyle(.comicLink)
            }
        case .received:
            VStack(alignment: .leading, spacing: 8) {
                CaptionBox(label: "Clik! Got it", text: "Press received. Presses reach DialHack.", color: CK.green)
                Button("OK") { c.resetPressTest() }.buttonStyle(.comicLink)
            }
        case let .missed(route):
            VStack(alignment: .leading, spacing: 8) {
                CaptionBox(label: "No press in 10 s", text: missedHint(route), color: CK.red)
                HStack(spacing: 14) {
                    Button("Try again") { c.startPressTest() }.buttonStyle(.comicSecondary)
                    Button("OK") { c.resetPressTest() }.buttonStyle(.comicLink)
                }
            }
        }
    }

    private func missedHint(_ route: PressRoute) -> String {
        switch route {
        case let .otherApps(names):
            return "\(names.joined(separator: ", ")) is playing audio and probably took the press. Pause it, then try again."
        case .passthrough:
            return "In Passthrough, presses go to your music app. Switch to a dial mode first."
        case .silenceDown:
            return "DialHack's audio was reconnecting. Try again in a few seconds."
        case .dialHack:
            return "A browser tab or app may still own Now Playing while paused. Quit the app that last played media, then try again."
        }
    }
}
