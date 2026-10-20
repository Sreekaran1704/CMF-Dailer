import Foundation

// Native port of analytics/dialhack_analytics (features.py, labels.py, ingest.py).
// Same feature definitions as the Python pipeline; checked by Tests/parity.sh.

struct DialRecord: Equatable {
    let ts: Date
    let event: String
    let raw: String
    let mode: String
    let action: String
    let steps: Int
    let sessionId: String
    let platform: String
}

struct LabelEventRecord: Equatable {
    let ts: Date
    let label: String
    let source: String
    let focusSession: String
    let start: Date?
    let end: Date?
    let sessionId: String
}

struct HandLabel: Equatable {
    let windowStart: Date
    let label: String
    let windowMinutes: Double
}

enum InsightsIO {
    static let eventTypes: Set<String> = ["ROTATE_CW", "ROTATE_CCW", "PRESS_1", "PRESS_2", "PRESS_3", "MODE_PICKER"]

    // Creating a formatter per line made a 50k-event refresh take ~12 s. ISO8601DateFormatter is
    // thread-safe, so one shared instance per format is fine.
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fast path for the logs' own format, "2026-10-20T02:08:11.264Z" (or without milliseconds);
    /// anything else falls back to ISO8601DateFormatter.
    static func parseDate(_ s: String) -> Date? {
        let u = Array(s.utf8)
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in a..<(a + n) {
                guard i < u.count, u[i] >= 48, u[i] <= 57 else { return nil }
                v = v * 10 + Int(u[i] - 48)
            }
            return v
        }
        if (u.count == 24 || u.count == 20), u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u.last == 90,
           let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) {
            var ms = 0
            if u.count == 24 {
                guard u[19] == 46, let m = num(20, 3) else { return fractional.date(from: s) ?? whole.date(from: s) }
                ms = m
            }
            // days from civil (Howard Hinnant), UTC
            let yy = mo <= 2 ? y - 1 : y
            let era = (yy >= 0 ? yy : yy - 399) / 400
            let yoe = yy - era * 400
            let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            let secs = Double(days * 86400 + h * 3600 + mi * 60 + se) + Double(ms) / 1000
            return Date(timeIntervalSince1970: secs)
        }
        return fractional.date(from: s) ?? whole.date(from: s)
    }

    /// Parses the whole file as one JSON array (much faster than line by line); if any line is
    /// malformed, falls back to line-by-line and skips the bad ones.
    static func jsonLines(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
        let joined = "[" + lines.joined(separator: ",") + "]"
        if let all = (try? JSONSerialization.jsonObject(with: Data(joined.utf8))) as? [Any] {
            return all.compactMap { $0 as? [String: Any] }
        }
        return lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    static func excludedSessions(_ url: URL) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line -> String? in
            let s = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        })
    }

    static func events(_ url: URL, excluding skip: Set<String> = []) -> [DialRecord] {
        var seen = Set<String>()
        return jsonLines(url).compactMap { o -> DialRecord? in
            guard let ev = o["event"] as? String, eventTypes.contains(ev), let tsS = o["ts"] as? String,
                  let ts = parseDate(tsS) else { return nil }
            let sid = o["session_id"] as? String ?? ""
            guard !skip.contains(sid) else { return nil }
            let raw = o["raw"] as? String ?? ""
            guard seen.insert("\(sid)|\(tsS)|\(ev)|\(raw)").inserted else { return nil }
            return DialRecord(ts: ts, event: ev, raw: raw, mode: o["mode"] as? String ?? "", action: o["action"] as? String ?? "",
                              steps: (o["steps"] as? Int) ?? 1, sessionId: sid, platform: o["platform"] as? String ?? "")
        }.sorted { $0.ts < $1.ts }
    }

    static func labelEvents(_ url: URL, excluding skip: Set<String> = []) -> [LabelEventRecord] {
        jsonLines(url).compactMap { o -> LabelEventRecord? in
            guard o["event"] == nil, let label = o["label"] as? String, let source = o["source"] as? String,
                  let ts = (o["ts"] as? String).flatMap(parseDate) else { return nil }
            let sid = o["session_id"] as? String ?? ""
            guard !skip.contains(sid) else { return nil }
            return LabelEventRecord(ts: ts, label: label.lowercased(), source: source, focusSession: o["focus_session_id"] as? String ?? "",
                                    start: (o["start"] as? String).flatMap(parseDate), end: (o["end"] as? String).flatMap(parseDate),
                                    sessionId: sid)
        }
    }

    /// dashboard_labels.csv: window_start,label[,window_minutes]
    static func handLabels(_ url: URL) -> [HandLabel] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let iw = header.firstIndex(of: "window_start"), let il = header.firstIndex(of: "label") else { return [] }
        let im = header.firstIndex(of: "window_minutes")
        return lines.compactMap { line in
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard c.count > max(iw, il), let d = parseDate(c[iw]), !c[il].isEmpty else { return nil }
            let m = im.flatMap { $0 < c.count ? Double(c[$0]) : nil } ?? 5
            return HandLabel(windowStart: d, label: c[il].lowercased(), windowMinutes: m)
        }
    }

    static func writeHandLabels(_ labels: [HandLabel], to url: URL) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var out = "window_start,label,window_minutes\n"
        for l in labels.sorted(by: { $0.windowStart < $1.windowStart }) {
            out += "\(f.string(from: l.windowStart)),\(l.label),\(l.windowMinutes)\n"
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - windows

struct FidgetWindow: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let minutes: Double
    var nEvents = 0, nRotations = 0, nCW = 0, nCCW = 0, nPresses = 0, nPress1 = 0, nPress2 = 0
    var rotationsPerMin = 0.0, reversals = 0, reversalRate = 0.0
    var nBursts = 0, meanBurstSize = 0.0, maxBurstSize = 0
    var ietMedian: Double? = nil, ietP90: Double? = nil, ietCV: Double? = nil
    var maxIdle = 0.0, pressRatio = 0.0
    var dominantMode = ""
    var hour = 0, weekday = 0          // weekday: 0 = Monday (pandas convention)
    var likelyStray: Bool { nEvents <= 2 }

    // Filled by labels / models.
    var label: String? = nil
    var labelSource: String? = nil
    var labelSources: String? = nil
    var cluster = -1
    var pca = (x: 0.0, y: 0.0)
    var anomalyScore: Double? = nil
    var restless = false
    var predicted: String? = nil

    static func == (a: FidgetWindow, b: FidgetWindow) -> Bool { a.start == b.start && a.minutes == b.minutes && a.label == b.label }

    /// Model features, in the same order and with the same NaN fills as features.MODEL_FEATURES/model_matrix.
    var featureVector: [Double] {
        [rotationsPerMin, reversalRate, Double(nBursts), meanBurstSize, Double(maxBurstSize),
         ietMedian ?? minutes * 60, ietP90 ?? minutes * 60, ietCV ?? 0, maxIdle, pressRatio]
    }

    static let featureNames = ["turns/min", "reversal rate", "bursts", "mean burst", "max burst",
                               "median gap s", "p90 gap s", "gap CV", "max idle s", "press ratio"]
}

enum Fidget {
    static let rotations: Set<String> = ["ROTATE_CW", "ROTATE_CCW"]
    static let presses: Set<String> = ["PRESS_1", "PRESS_2", "PRESS_3"]

    /// Same rule as features.is_control: mode picking and Focus Timer buttons aren't fidgeting.
    static func isControl(_ action: String) -> Bool {
        if action == "focus_fidget" { return false }
        return ["focus_", "open_mode_picker", "picker_", "mode:"].contains { action.hasPrefix($0) }
    }

    static func floor(_ d: Date, minutes: Double) -> Date {
        let s = minutes * 60
        return Date(timeIntervalSince1970: (d.timeIntervalSince1970 / s).rounded(.down) * s)
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        let k = Double(s.count - 1) * p / 100
        let lo = Int(k), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (k - Double(lo))
    }

    static func windows(_ events: [DialRecord], minutes: Double = 5, burstGap: Double = 2, include: [Date] = [],
                        calendar: Calendar = .current, now: Date = Date()) -> [FidgetWindow] {
        let fidget = events.filter { !isControl($0.action) }
        var groups: [Date: [DialRecord]] = [:]
        for e in fidget { groups[floor(e.ts, minutes: minutes), default: []].append(e) }
        for d in include where groups[d] == nil { groups[d] = [] }

        return groups.keys.sorted().map { ws in
            let g = groups[ws]!.sorted { $0.ts < $1.ts }
            var w = FidgetWindow(start: ws, minutes: minutes)
            var cal = calendar
            cal.firstWeekday = 2
            w.hour = cal.component(.hour, from: ws)
            w.weekday = (cal.component(.weekday, from: ws) + 5) % 7
            w.maxIdle = minutes * 60
            guard let first = g.first else { return w }

            let secs = g.map { $0.ts.timeIntervalSince(first.ts) }
            let gaps = zip(secs.dropFirst(), secs).map { $0 - $1 }
            var dirs: [Int] = []
            for e in g where rotations.contains(e.event) {
                dirs += Array(repeating: e.event == "ROTATE_CW" ? 1 : -1, count: max(e.steps, 1))
            }
            w.nEvents = g.count
            w.nRotations = dirs.count
            w.nCW = dirs.filter { $0 > 0 }.count
            w.nCCW = dirs.count - w.nCW
            w.nPresses = g.filter { presses.contains($0.event) }.count
            w.nPress1 = g.filter { $0.event == "PRESS_1" }.count
            w.nPress2 = g.filter { $0.event == "PRESS_2" }.count
            w.rotationsPerMin = Double(dirs.count) / minutes
            w.reversals = zip(dirs.dropFirst(), dirs).filter { $0 != $1 }.count
            w.reversalRate = dirs.count > 1 ? Double(w.reversals) / Double(dirs.count - 1) : 0

            var sizes = [1]
            for gap in gaps { if gap > burstGap { sizes.append(1) } else { sizes[sizes.count - 1] += 1 } }
            w.nBursts = sizes.count
            w.meanBurstSize = Double(sizes.reduce(0, +)) / Double(sizes.count)
            w.maxBurstSize = sizes.max() ?? 0
            if !gaps.isEmpty {
                w.ietMedian = percentile(gaps, 50)
                w.ietP90 = percentile(gaps, 90)
                w.maxIdle = gaps.max()!
                let mean = gaps.reduce(0, +) / Double(gaps.count)
                if gaps.count > 1 && mean > 0 {
                    let sd = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
                    w.ietCV = sd / mean
                }
            }
            w.pressRatio = Double(w.nPresses) / Double(g.count)
            let modes = Dictionary(grouping: g.map(\.mode), by: { $0 }).mapValues(\.count)
            w.dominantMode = modes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? ""
            return w
        }
    }
}

// MARK: - labels (labels.py)

enum LabelSources {
    static let dashboard = "dashboard", tag = "focus_timer_tag", session = "focus_session_end"
    static let priority = [dashboard, tag, session]
    static let all = ["focused", "distracted", "stressed", "bored"]

    static func display(_ s: String) -> String {
        switch s {
        case dashboard: return "You (hand label)"
        case tag: return "Focus Timer tag"
        case session: return "Focus session rating"
        default: return s
        }
    }

    struct Vote: Hashable { let window: Date; let source: String; let label: String }

    static func votes(_ events: [LabelEventRecord], _ hand: [HandLabel], minutes: Double) -> [Vote] {
        var out = Set<Vote>()
        let step = minutes * 60
        for e in events {
            if e.source == tag {
                out.insert(Vote(window: Fidget.floor(e.ts, minutes: minutes), source: tag, label: e.label))
            } else if e.source == session, let s = e.start, let end = e.end {
                var ws = Fidget.floor(s, minutes: minutes)
                while ws < end {
                    out.insert(Vote(window: ws, source: session, label: e.label))
                    ws = ws.addingTimeInterval(step)
                }
            }
        }
        for h in hand {
            let end = h.windowStart.addingTimeInterval(h.windowMinutes * 60)
            var ws = Fidget.floor(h.windowStart, minutes: minutes)
            while ws < end {
                out.insert(Vote(window: ws, source: dashboard, label: h.label))
                ws = ws.addingTimeInterval(step)
            }
        }
        return Array(out)
    }

    static func assign(_ windows: inout [FidgetWindow], _ votes: [Vote]) {
        let byWindow = Dictionary(grouping: votes, by: \.window)
        for i in windows.indices {
            guard let vs = byWindow[windows[i].start] else { continue }
            let ranked = vs.sorted { (priority.firstIndex(of: $0.source) ?? 9, $0.label) < (priority.firstIndex(of: $1.source) ?? 9, $1.label) }
            windows[i].label = ranked[0].label
            windows[i].labelSource = ranked[0].source
            windows[i].labelSources = ranked.map { "\($0.source):\($0.label)" }.joined(separator: "; ")
        }
    }
}
