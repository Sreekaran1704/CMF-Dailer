import Foundation
import SwiftUI

/// Window-level UI state. (No @State: this toolchain can't build SwiftUI's macros.)
final class AppUI: ObservableObject {
    static let shared = AppUI()

    enum Section: String, CaseIterable, Hashable {
        case dial = "Dial", focus = "Focus", activity = "Activity", insights = "Insights", settings = "Settings"

        var icon: String {
            switch self {
            case .dial: return "dial.medium"
            case .focus: return "timer"
            case .activity: return "list.bullet.rectangle"
            case .insights: return "chart.bar.xaxis"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var section: Section? = .dial
    @Published var activityMode: String = "all"
}

/// Loads logs and runs the native insights engine off the main thread.
final class InsightsModel: ObservableObject {
    static let shared = InsightsModel()

    @Published var minutes: Double = 5 { didSet { if minutes != oldValue { refresh() } } }
    @Published var includeStray = false { didSet { if includeStray != oldValue { refresh() } } }
    @Published private(set) var result = InsightsResult()
    @Published private(set) var events: [DialRecord] = []
    @Published private(set) var sessions: [FocusSessionSummary] = []
    @Published private(set) var loading = false
    @Published private(set) var updated: Date?

    var dir: URL = EventLogger.directory
    var eventsURL: URL { dir.appendingPathComponent("events.jsonl") }
    var labelsURL: URL { dir.appendingPathComponent("labels.jsonl") }
    var handURL: URL { dir.appendingPathComponent("dashboard_labels.csv") }
    var excludeURL: URL { dir.appendingPathComponent("exclude_sessions.txt") }

    private let q = DispatchQueue(label: "dialhack.insights", qos: .userInitiated)
    /// Only the newest refresh may publish (an older, slower one must not overwrite it).
    private var generation = 0

    func refresh() {
        loading = true
        generation += 1
        let gen = generation
        let (minutes, includeStray) = (minutes, includeStray)
        let urls = (eventsURL, labelsURL, handURL, excludeURL)
        q.async {
            let skip = InsightsIO.excludedSessions(urls.3)
            let ev = InsightsIO.events(urls.0, excluding: skip)
            let le = InsightsIO.labelEvents(urls.1, excluding: skip)
            let hand = InsightsIO.handLabels(urls.2)
            let r = Insights.analyze(events: ev, labelEvents: le, hand: hand, minutes: minutes, includeStray: includeStray)
            let s = FocusSessionSummary.from(le)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.result = r
                self.events = ev
                self.sessions = s
                self.loading = false
                self.updated = Date()
            }
        }
    }

    /// Your own label for a window ("" clears it). Written to dashboard_labels.csv, shared with Python.
    func setHandLabel(_ label: String, for w: FidgetWindow) {
        var all = InsightsIO.handLabels(handURL).filter { !($0.windowStart == w.start && $0.windowMinutes == w.minutes) }
        if !label.isEmpty { all.append(HandLabel(windowStart: w.start, label: label, windowMinutes: w.minutes)) }
        InsightsIO.writeHandLabels(all, to: handURL)
        refresh()
    }

    func handLabel(for w: FidgetWindow) -> String {
        w.labelSource == LabelSources.dashboard ? (w.label ?? "") : ""
    }
}

struct FocusSessionSummary: Identifiable {
    let id: String
    let start: Date?
    let end: Date?
    let rating: String?
    let tags: Int
    let lastSeen: Date

    static func from(_ labels: [LabelEventRecord]) -> [FocusSessionSummary] {
        Dictionary(grouping: labels.filter { !$0.focusSession.isEmpty }, by: \.focusSession).map { id, ls in
            let rating = ls.first { $0.source == LabelSources.session }
            return FocusSessionSummary(id: id, start: rating?.start ?? ls.map(\.ts).min(), end: rating?.end,
                                       rating: rating?.label, tags: ls.filter { $0.source == LabelSources.tag }.count,
                                       lastSeen: ls.map(\.ts).max() ?? .distantPast)
        }.sorted { $0.lastSeen > $1.lastSeen }
    }
}
