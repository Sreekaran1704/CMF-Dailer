import SwiftUI

struct ActivityView: View {
    @ObservedObject var c: Coordinator
    @ObservedObject var insights: InsightsModel
    @ObservedObject var ui = AppUI.shared

    private var today: [DialRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        return insights.events.filter { $0.ts >= start }
    }

    private var shown: [DialRecord] {
        let evs = ui.activityMode == "all" ? insights.events : insights.events.filter { $0.mode == ui.activityMode }
        return Array(evs.suffix(500).reversed())
    }

    var body: some View {
        let t = today
        VStack(alignment: .leading, spacing: 30) {
            ChapterHeader(number: 3, name: "The Log", title: "The Log",
                          subtitle: "Every turn and press, as it happened. Test sessions left out.", color: CK.green)

            StatRow(stats: [
                BigStat(value: t.filter { Fidget.rotations.contains($0.event) }.count.formatted(), label: "turns today", color: CK.blue),
                BigStat(value: t.filter { Fidget.presses.contains($0.event) }.count.formatted(), label: "presses today", color: CK.red),
                BigStat(value: insights.events.count.formatted(), label: "events on record", color: CK.green),
                BigStat(value: insights.sessions.count.formatted(), label: "focus sessions", color: CK.purple),
            ])

            HStack(spacing: 16) {
                ComicSegmented(options: [("all", "All")] + ModeID.allCases.map { ($0.rawValue, $0.title) },
                               selection: $ui.activityMode, color: CK.green)
                Spacer()
                Button("Log file ↗") { NSWorkspace.shared.activateFileViewerSelecting([insights.eventsURL]) }.buttonStyle(.comicLink)
                Button("Refresh") { insights.refresh() }.buttonStyle(.comicSecondary)
            }

            ComicTable(columns: [("Time", 170), ("Sound", 120), ("Power", 120), ("Input", 120), ("Action", nil)],
                       rows: shown, empty: "No dial events on record yet.") { e in
                let mode = ModeID(rawValue: e.mode)
                Cell(width: 170) { Text(e.ts, format: .dateTime.month(.abbreviated).day().hour().minute().second()).font(CK.body(12.5)).monospacedDigit().foregroundStyle(CK.muted) }
                Cell(width: 120) { Text(CK.sfx(e.event).uppercased()).font(CK.title(16)).tracking(0.5).foregroundStyle(mode.map(CK.modeColor) ?? CK.muted) }
                Cell(width: 120) { Caps(mode?.title ?? e.mode, size: 10.5, color: CK.inkSoft) }
                Cell(width: 120) { Text(e.event).font(CK.label(11.5)).help("Raw: \(e.raw)") }
                Cell { Text(e.action.replacingOccurrences(of: "_", with: " ")).font(CK.body(14)) }
            }
        }
        .onAppear { insights.refresh() }
    }
}

extension DialRecord: Identifiable {
    var id: String { "\(sessionId)|\(ts.timeIntervalSince1970)|\(event)|\(raw)" }
}
