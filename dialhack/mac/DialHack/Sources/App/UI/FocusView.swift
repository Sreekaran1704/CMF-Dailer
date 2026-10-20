import SwiftUI

struct FocusView: View {
    @ObservedObject var c: Coordinator
    @ObservedObject var insights: InsightsModel

    var body: some View {
        let f = c.focus
        VStack(alignment: .leading, spacing: 30) {
            ChapterHeader(number: 2, name: "Focus", title: "Focus Timer",
                          subtitle: "Set a length, start the clock, and own up to every distraction with a double press.",
                          color: CK.red)

            Panel(number: "1", kicker: stateText(f), color: CK.red, badge: f.tags > 0 ? "\(f.tags) distracted" : nil) {
                HStack(alignment: .center, spacing: 40) {
                    ZStack {
                        Starburst(spikes: 18, inner: 0.86).fill(CK.shadow).offset(x: 6, y: 6)
                        Starburst(spikes: 18, inner: 0.86).fill(f.endsAt != nil ? CK.red : CK.yellow)
                        Halftone(color: Color.black.opacity(0.18), spacing: 8, minRadius: 0.3, maxRadius: 2.8)
                            .clipShape(Starburst(spikes: 18, inner: 0.86))
                        Starburst(spikes: 18, inner: 0.86).stroke(CK.line, lineWidth: 3.5)
                        SFX(text: clockText(f), size: 76, fill: CK.white, outline: CK.onYellow, tilt: -3)
                            .monospacedDigit()
                    }
                    .frame(width: 300, height: 210)
                    VStack(alignment: .leading, spacing: 16) {
                        controls(f)
                        if c.mode != .focusTimer {
                            Text("Starting here switches the dial to Focus Timer mode.").font(CK.bodyItalic(13.5)).foregroundStyle(CK.muted)
                        }
                    }
                }
                CaptionBox(label: "On the dial", text: "Turn to set minutes · press to start or pause · double-press when you get distracted.", color: CK.red)
            }

            if case .rating = f.phase, c.mode == .focusTimer {
                Panel(number: "2", kicker: "The end?", color: CK.green, title: "How was it?") {
                    HStack(spacing: 14) {
                        ForEach(FocusTimer.ratings, id: \.self) { r in
                            Button(r) { c.focusRate(r) }.buttonStyle(ComicButtonStyle(kind: .primary, color: ratingColor(r)))
                        }
                        Button("Skip") { c.focusButton(.press2) }.buttonStyle(.comicLink)
                    }
                    Text("Your rating labels every window of this session for Insights.").font(CK.bodyItalic(13.5)).foregroundStyle(CK.muted)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                SubHead(text: "Previously…", color: CK.red, trailing: "\(insights.sessions.count) sessions on record")
                ComicTable(columns: [("When", 220), ("Length", 90), ("Rating", 130), ("Distractions", nil)],
                           rows: Array(insights.sessions.prefix(20)), empty: "No focus sessions yet.") { s in
                    Cell(width: 220) { Text(s.start ?? s.lastSeen, format: .dateTime.weekday().day().month().hour().minute()).font(CK.body(14)) }
                    Cell(width: 90) { Text(length(s)).font(CK.bodyBold(13)).monospacedDigit() }
                    Cell(width: 130) {
                        if let r = s.rating { Sticker(text: r, color: ratingColor(r), tilt: -2) } else { Text("–").foregroundStyle(CK.muted) }
                    }
                    Cell { Text(s.tags == 0 ? "–" : "\(s.tags)").font(CK.title(20)).foregroundStyle(s.tags > 0 ? CK.red : CK.muted) }
                }
            }
        }
        .onAppear { insights.refresh() }
    }

    @ViewBuilder private func controls(_ f: FocusTimer) -> some View {
        switch f.phase {
        case .idle:
            HStack(spacing: 16) {
                ComicStepper(value: c.config.focusMinutes, range: FocusTimer.minuteRange, step: FocusTimer.stepMinutes, unit: " min") { c.setFocusMinutes($0) }
                Button("Start!") { c.focusButton(.press1) }.buttonStyle(.comic)
            }
        case .running:
            HStack(spacing: 16) {
                Button("I got distracted!") { c.focusButton(.press2) }.buttonStyle(ComicButtonStyle(kind: .primary, color: CK.red))
                Button("Pause") { c.focusButton(.press1) }.buttonStyle(.comicSecondary)
            }
        case .paused:
            HStack(spacing: 16) {
                Button("Resume!") { c.focusButton(.press1) }.buttonStyle(.comic)
                Button("End now and rate") { c.focusButton(.press2) }.buttonStyle(.comicSecondary)
            }
        case .rating:
            EmptyView()
        }
    }

    private func ratingColor(_ r: String) -> Color {
        switch r {
        case "focused": return CK.green
        case "distracted": return CK.red
        case "stressed": return CK.orange
        default: return CK.purple
        }
    }

    private func clockText(_ f: FocusTimer) -> String {
        let s = Int(f.remaining(at: Date()).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func stateText(_ f: FocusTimer) -> String {
        switch f.phase {
        case .idle: return "Ready…"
        case .running: return "Focusing!"
        case .paused: return "Paused"
        case .rating: return "Done!"
        }
    }

    private func length(_ s: FocusSessionSummary) -> String {
        guard let a = s.start, let b = s.end else { return "–" }
        return "\(Int((b.timeIntervalSince(a) / 60).rounded())) min"
    }
}
