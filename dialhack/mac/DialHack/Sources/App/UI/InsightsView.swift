import Charts
import SwiftUI

struct InsightsView: View {
    @ObservedObject var model: InsightsModel
    @Environment(\.colorScheme) private var scheme

    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let calm = "Turns per minute"
    private static let hot = "⚠ Unusually restless"

    var body: some View {
        let r = model.result
        let active = r.active
        VStack(alignment: .leading, spacing: 26) {
            ChapterHeader(number: 4, name: "Insights", title: "The Plot Thickens",
                          subtitle: "What your dial gives away about how you work: when you fidget, how, and whether a model can tell your moods apart.",
                          color: CK.purple)

            controls

            StatRow(stats: [
                BigStat(value: r.events.formatted(), label: "dial events", color: CK.blue),
                BigStat(value: active.count.formatted(), label: "\(Int(model.minutes))-min windows with activity", color: CK.teal),
                BigStat(value: r.windows.map(\.nRotations).reduce(0, +).formatted(), label: "turns", color: CK.green),
                BigStat(value: r.windows.map(\.nPresses).reduce(0, +).formatted(), label: "presses", color: CK.orange),
                BigStat(value: r.windows.filter(\.restless).count.formatted(), label: "unusually restless", color: CK.red),
            ])

            if !r.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(r.notes, id: \.self) { StatusLine(kind: .info, text: $0) }
                }
            }

            if active.isEmpty {
                Panel(number: "1", kicker: "To be continued…", color: CK.teal) {
                    Text("Use the dial for a few days, in any mode including Passthrough, and these pages fill in. Focus Timer sessions also add labels for the classifier.")
                        .font(CK.body(15)).foregroundStyle(CK.inkSoft)
                }
            } else {
                timeline(active)
                HStack(alignment: .top, spacing: 22) {
                    heatmap(active)
                    clusters(r)
                }
                restless(r)
            }
            labelsAndClassifier(r)
            handLabels(active)
        }
        .onAppear { model.refresh() }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            ComicSegmented(options: [(1.0, "1 min"), (5.0, "5 min"), (15.0, "15 min"), (30.0, "30 min")], selection: $model.minutes, color: CK.teal)
            Toggle(isOn: $model.includeStray) { Text("Include likely-stray windows").font(CK.body(14)) }
                .toggleStyle(ComicToggleStyle())
                .help("Windows with ≤ 2 events: usually in-ear-detection pauses or pocket nudges.")
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            if let u = model.updated { Text("Updated \(u.formatted(.dateTime.hour().minute().second()))").font(CK.bodyItalic(12.5)).foregroundStyle(CK.muted) }
            Button("Refresh") { model.refresh() }.buttonStyle(.comicSecondary)
        }
    }

    // MARK: timeline

    private func timeline(_ ws: [FidgetWindow]) -> some View {
        let span = model.minutes * 60
        let lo = ws.map(\.start).min()!, hi = ws.map(\.start).max()!.addingTimeInterval(span)
        let pad = max(0, 6 * 3600 - hi.timeIntervalSince(lo)) / 2
        let hasHot = ws.contains(where: \.restless)
        return Panel(number: "1", kicker: "Turning intensity", color: CK.blue, title: "How hard you turned, window by window") {
            Chart(ws) { w in
                RectangleMark(xStart: .value("Start", w.start), xEnd: .value("End", w.start.addingTimeInterval(span * 0.85)),
                              yStart: .value("Zero", 0.0), yEnd: .value("Turns per minute", w.rotationsPerMin))
                    .foregroundStyle(by: .value("Kind", w.restless ? Self.hot : Self.calm))
            }
            .chartForegroundStyleScale(domain: [Self.calm, Self.hot], range: [CK.blue, CK.restless])
            .chartLegend(hasHot ? .visible : .hidden)
            .chartLegend(position: .top, alignment: .leading)
            .chartXScale(domain: lo.addingTimeInterval(-pad)...hi.addingTimeInterval(pad))
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(CK.hairline); AxisValueLabel().font(CK.body(10.5)).foregroundStyle(CK.muted) } }
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(CK.hairline); AxisValueLabel().font(CK.body(10.5)).foregroundStyle(CK.muted) } }
            .chartYAxisLabel(position: .trailing) { Caps("turns / min", size: 9.5, color: CK.muted) }
            .frame(height: 230)
        }
    }

    // MARK: heatmap

    private struct HeatCell: Identifiable {
        var id: Int { day * 24 + hour }
        let day: Int
        let hour: Int
        let value: Int
    }

    private func heatmap(_ ws: [FidgetWindow]) -> some View {
        var counts: [Int: Int] = [:]
        for w in ws { counts[w.weekday * 24 + w.hour, default: 0] += w.nEvents }
        let cells = counts.map { HeatCell(day: $0.key / 24, hour: $0.key % 24, value: $0.value) }
        return Panel(number: "2", kicker: "Time of day", color: CK.blue, title: "When you fidget") {
            Chart(cells) { c in
                RectangleMark(xStart: .value("Day", Double(c.day) + 0.04), xEnd: .value("Day end", Double(c.day) + 0.96),
                              yStart: .value("Hour", 24 - Double(c.hour) - 0.08), yEnd: .value("Hour end", 24 - Double(c.hour) - 0.92))
                    .foregroundStyle(by: .value("Dial events", c.value))
            }
            .chartForegroundStyleScale(range: Gradient(colors: scheme == .dark ? CK.heatDark : CK.heatLight))
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXScale(domain: 0...7)
            .chartYScale(domain: 0...24)
            .chartXAxis {
                AxisMarks(position: .top, values: (0..<7).map { Double($0) + 0.5 }) { v in
                    AxisValueLabel { Caps(Self.days[Int(v.as(Double.self) ?? 0)], size: 9.5, color: CK.muted) }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: stride(from: 0.0, through: 24, by: 3).map { 24 - $0 - 0.5 }.filter { $0 > 0 }) { v in
                    AxisValueLabel { Text(String(format: "%02d:00", 24 - Int((v.as(Double.self) ?? 0) + 0.5))).font(CK.body(10)).foregroundStyle(CK.muted) }
                }
            }
            .frame(height: 360)
            Text("Dial events by weekday and hour, local time. Blank means no activity.").font(CK.bodyItalic(12.5)).foregroundStyle(CK.muted)
        }
    }

    // MARK: clusters

    private func describe(_ ws: [FidgetWindow], all: [FidgetWindow]) -> String {
        let s = all.map(\.rotationsPerMin).sorted()
        let m = s.isEmpty ? 0 : s[s.count / 2]
        let rate = ws.map(\.rotationsPerMin).mean, rev = ws.map(\.reversalRate).mean, pr = ws.map(\.pressRatio).mean
        var parts = [rate > m * 1.5 ? "fast" : (rate < m * 0.5 ? "slow" : "moderate"), rev > 0.25 ? "back-and-forth" : "one-way"]
        if pr > 0.3 { parts.append("press-heavy") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func clusters(_ r: InsightsResult) -> some View {
        let cl = r.windows.filter { $0.cluster >= 0 }
        Panel(number: "3", kicker: "Clusters", color: CK.orange, badge: r.k.map { "k = \($0)" }, title: "Kinds of fidgeting") {
            if !cl.isEmpty {
                let order = Dictionary(grouping: cl, by: \.cluster).sorted { $0.value.count > $1.value.count }
                let names: [Int: String] = Dictionary(uniqueKeysWithValues: order.enumerated().map { i, kv in
                    (kv.key, i < 3 ? "\(i + 1) · \(describe(kv.value, all: cl))" : "Other")
                })
                let domain = order.prefix(3).map { names[$0.key]! } + (order.count > 3 ? ["Other"] : [])
                Chart(cl) { w in
                    PointMark(x: .value("PCA 1", w.pca.x), y: .value("PCA 2", w.pca.y))
                        .foregroundStyle(by: .value("Cluster", names[w.cluster] ?? "Other"))
                        .symbolSize(60)
                }
                .chartForegroundStyleScale(domain: domain, range: Array(CK.series.prefix(min(3, order.count))) + (order.count > 3 ? [CK.other] : []))
                .chartLegend(position: .bottom, alignment: .leading)
                .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(CK.hairline) } }
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(CK.hairline) } }
                .frame(height: 300)
                Text("Each dot is one \(Int(model.minutes))-min window, placed by its fidget features. Silhouette \(String(format: "%.2f", r.silhouette ?? 0)).")
                    .font(CK.bodyItalic(12.5)).foregroundStyle(CK.muted)
            } else {
                Text("Clustering needs at least \(Insights.minToCluster) active windows.").font(CK.bodyItalic(14)).foregroundStyle(CK.muted)
            }
        }
    }

    // MARK: restless

    @ViewBuilder private func restless(_ r: InsightsResult) -> some View {
        let hot = r.windows.filter(\.restless).sorted { ($0.anomalyScore ?? 0) > ($1.anomalyScore ?? 0) }
        if !hot.isEmpty {
            Panel(number: "4", kicker: "⚠ Unusually restless", color: CK.red, badge: "\(hot.count) windows", title: "Outliers worth a second look") {
                CaptionBox(text: "Isolation-forest outliers that were also turning faster than your median.", color: CK.red)
                ComicTable(columns: [("When", 200), ("Turns/min", 100), ("Reversals", 100), ("Bursts", 80), ("Score", nil)], rows: hot) { w in
                    Cell(width: 200) { Text(w.start, format: .dateTime.weekday().day().month().hour().minute()).font(CK.body(14)) }
                    Cell(width: 100) { Text(String(format: "%.1f", w.rotationsPerMin)).font(CK.title(17)).foregroundStyle(CK.red) }
                    Cell(width: 100) { Text(w.reversalRate, format: .percent.precision(.fractionLength(0))).font(CK.body(12.5)) }
                    Cell(width: 80) { Text("\(w.nBursts)").font(CK.body(12.5)) }
                    Cell { Text(String(format: "%.2f", w.anomalyScore ?? 0)).font(CK.body(12.5)).foregroundStyle(CK.muted) }
                }
            }
        }
    }

    // MARK: labels & classifier

    @ViewBuilder private func labelsAndClassifier(_ r: InsightsResult) -> some View {
        let lw = r.windows.filter { $0.label != nil }
        let c = r.classifier
        Panel(number: "5", kicker: "Labels & classifier", color: CK.purple, badge: c.ok ? "\(c.folds.count) folds" : "Not enough data",
                  title: c.ok ? (c.beatsBaseline ? "The model beats always guessing" : "No better than guessing, yet") : "Waiting on labels") {
            Text("Labels come from the Focus Timer's “distracted” double-press (in the moment), its end-of-session rating, and your own labels below. When they disagree on a window: your label, then the tag, then the rating.")
                .font(CK.body(14.5)).foregroundStyle(CK.inkSoft).fixedSize(horizontal: false, vertical: true)
            if !lw.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
                    GridRow {
                        Caps("Source", size: 10, color: CK.muted)
                        ForEach(LabelSources.all, id: \.self) { Caps($0, size: 10, color: CK.muted) }
                    }
                    ForEach(LabelSources.priority, id: \.self) { s in
                        GridRow {
                            Text(LabelSources.display(s)).font(CK.body(14))
                            ForEach(LabelSources.all, id: \.self) { l in
                                Text("\(lw.filter { $0.labelSource == s && $0.label == l }.count)").font(CK.title(17)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            if !c.ok {
                CaptionBox(label: "Not enough data", text: (c.reason.isEmpty ? "No labels yet." : c.reason) + " Labeled so far: \(lw.count) windows.", color: CK.orange)
            } else {
                StatRow(stats: [
                    BigStat(value: pct(c.modelBalanced), label: "balanced accuracy", color: CK.purple,
                            note: String(format: "%+.0f pts vs baseline", (c.modelBalanced - c.baselineBalanced) * 100)),
                    BigStat(value: pct(c.baselineBalanced), label: "majority baseline (balanced)", color: CK.muted),
                    BigStat(value: pct(c.modelAccuracy), label: "accuracy", color: CK.purple,
                            note: String(format: "%+.0f pts vs baseline", (c.modelAccuracy - c.baselineAccuracy) * 100)),
                    BigStat(value: pct(c.baselineAccuracy), label: "majority baseline", color: CK.muted),
                ])
                CaptionBox(label: c.beatsBaseline ? "Key finding" : "Caution",
                           text: c.beatsBaseline
                               ? "Over \(c.folds.count) time-ordered folds, k-nearest-neighbours on the 10 window features beats always guessing the most common label."
                               : "It doesn't beat always guessing the most common label. Don't trust its predictions yet.",
                           color: c.beatsBaseline ? CK.purple : CK.red)
                ComicTable(columns: [("Fold", 50), ("Trained until", 170), ("Tested from", 170), ("Model", 90), ("Baseline", nil)], rows: c.folds) { f in
                    Cell(width: 50) { Text("\(f.id)").font(CK.body(12.5)) }
                    Cell(width: 170) { Text(f.trainUntil, format: .dateTime.day().month().hour().minute()).font(CK.body(13.5)) }
                    Cell(width: 170) { Text(f.testFrom, format: .dateTime.day().month().hour().minute()).font(CK.body(13.5)) }
                    Cell(width: 90) { Text(pct(f.modelBalanced)).font(CK.title(16)).foregroundStyle(CK.purple) }
                    Cell { Text(pct(f.baselineBalanced)).font(CK.body(12.5)).foregroundStyle(CK.muted) }
                }
                if !c.reason.isEmpty { Text(c.reason).font(CK.bodyItalic(12.5)).foregroundStyle(CK.muted) }
            }
        }
    }

    private func pct(_ x: Double) -> String { x.isNaN ? "–" : String(format: "%.0f%%", x * 100) }

    // MARK: hand labels

    @ViewBuilder private func handLabels(_ active: [FidgetWindow]) -> some View {
        if !active.isEmpty {
            let rows = Array(active.sorted { $0.start > $1.start }.prefix(150))
            VStack(alignment: .leading, spacing: 12) {
                SubHead(text: "Label windows yourself", color: CK.purple, trailing: "Saved to dashboard_labels.csv, shared with the Python tools")
                ComicTable(columns: [("When", 190), ("Turns/min", 90), ("Current label", 210), ("Predicted", 110), ("Your label", nil)], rows: rows) { w in
                    Cell(width: 190) { Text(w.start, format: .dateTime.weekday().day().month().hour().minute()).font(CK.body(14)) }
                    Cell(width: 90) { Text(String(format: "%.1f", w.rotationsPerMin)).font(CK.body(12.5)).monospacedDigit() }
                    Cell(width: 210) {
                        Text(w.label.map { "\($0) · \(LabelSources.display(w.labelSource ?? ""))" } ?? "–").font(CK.body(13.5)).foregroundStyle(CK.muted)
                    }
                    Cell(width: 110) { Text(w.predicted ?? "–").font(CK.bodyItalic(13.5)).foregroundStyle(CK.muted) }
                    Cell {
                        Picker("", selection: Binding(get: { model.handLabel(for: w) }, set: { model.setHandLabel($0, for: w) })) {
                            Text("–").tag("")
                            ForEach(LabelSources.all, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }
                }
            }
        }
    }
}
