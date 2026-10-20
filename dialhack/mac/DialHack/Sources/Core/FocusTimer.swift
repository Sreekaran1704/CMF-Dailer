import Foundation

/// A self-report label produced on the dial, in the moment. Logged to labels.jsonl and fed to
/// analytics as training labels, with `source` kept separate from dashboard labels.
struct LabelRecord: Equatable {
    static let tagSource = "focus_timer_tag"
    static let sessionSource = "focus_session_end"

    let ts: Date
    let label: String
    let source: String
    let focusSession: String
    /// For session ratings: the span the rating covers.
    var start: Date? = nil
    var end: Date? = nil
}

/// Focus Timer mode (pure state machine; time is injected).
///
///   idle      turn: ±5 min (5–120) · press: start
///   running   turn: nothing (fidgeting is just logged) · press: pause · double: "distracted" tag
///   paused    press: resume · double: end now and rate
///   rating    after the timer ends: turn to pick how it went, press to save, double to skip
struct FocusTimer: Equatable {
    enum Phase: Equatable {
        case idle
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
        case rating(selected: Int)
    }

    static let ratings = ["focused", "distracted", "stressed", "bored"]
    static let stepMinutes = 5
    static let minuteRange = 5...120

    var minutes: Int
    private(set) var phase: Phase = .idle
    private(set) var sessionId = ""
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var tags = 0

    init(minutes: Int) {
        self.minutes = min(max(minutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
    }

    /// Running, paused or waiting for a rating: the coordinator must not auto-leave the mode.
    var isActive: Bool { phase != .idle }

    var endsAt: Date? {
        if case let .running(e) = phase { return e }
        return nil
    }

    func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .idle: return TimeInterval(minutes * 60)
        case let .running(e): return max(0, e.timeIntervalSince(now))
        case let .paused(r): return r
        case .rating: return 0
        }
    }

    private func hud(_ title: String, now: Date) -> Action {
        .hud(.focus(title: title, seconds: Int(remaining(at: now).rounded()), running: endsAt != nil, tags: tags))
    }

    private func ratingHUD(_ selected: Int) -> Action {
        .hud(.list(title: "Focus done · how was it? Turn, then press", items: Self.ratings.map(\.capitalized), selected: selected))
    }

    mutating func input(_ e: DialEvent, now: Date) -> EngineOutput {
        switch phase {
        case .idle:
            switch e {
            case .rotateCW, .rotateCCW:
                minutes = min(max(minutes + e.step * Self.stepMinutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
                return EngineOutput(actions: [hud("Focus · set length", now: now)], name: "focus_set_\(minutes)m")
            case .press1:
                sessionId = UUID().uuidString
                startedAt = now
                endedAt = nil
                tags = 0
                phase = .running(endsAt: now.addingTimeInterval(TimeInterval(minutes * 60)))
                return EngineOutput(actions: [hud("Focus started", now: now), .sound(.select)], name: "focus_start")
            case .press2, .press3:
                return EngineOutput(actions: [hud("Press to start", now: now)], name: "focus_idle")
            }

        case .running:
            switch e {
            case .rotateCW, .rotateCCW:
                return EngineOutput(name: "focus_fidget") // logged as telemetry, otherwise ignored
            case .press1:
                phase = .paused(remaining: remaining(at: now))
                return EngineOutput(actions: [hud("Paused", now: now), .sound(.select)], name: "focus_pause")
            case .press2:
                tags += 1
                let rec = LabelRecord(ts: now, label: "distracted", source: LabelRecord.tagSource, focusSession: sessionId)
                return EngineOutput(actions: [.label(rec), .hud(.message("Noted: distracted (\(tags))", success: true)), .sound(.select)],
                                    name: "focus_tag_distracted")
            case .press3:
                return EngineOutput()
            }

        case let .paused(remaining):
            switch e {
            case .press1:
                phase = .running(endsAt: now.addingTimeInterval(remaining))
                return EngineOutput(actions: [hud("Resumed", now: now), .sound(.select)], name: "focus_resume")
            case .press2:
                return finish(now: now, name: "focus_end_early")
            default:
                return EngineOutput(actions: [hud("Paused · press to resume", now: now)], name: "focus_paused")
            }

        case let .rating(selected):
            switch e {
            case .rotateCW, .rotateCCW:
                let n = Self.ratings.count
                let next = ((selected + e.step) % n + n) % n
                phase = .rating(selected: next)
                return EngineOutput(actions: [ratingHUD(next)], name: "focus_rate_\(Self.ratings[next])")
            case .press1:
                let label = Self.ratings[selected]
                let rec = LabelRecord(ts: now, label: label, source: LabelRecord.sessionSource, focusSession: sessionId,
                                      start: startedAt, end: endedAt)
                phase = .idle
                return EngineOutput(actions: [.label(rec), .hud(.message("Saved: \(label)", success: true)), .sound(.success)],
                                    name: "focus_rated_\(label)")
            case .press2, .press3:
                phase = .idle
                return EngineOutput(actions: [.hud(.hide)], name: "focus_rating_skipped")
            }
        }
    }

    /// The app window's one-click rating (same result as turning to `label` and pressing).
    mutating func rate(_ label: String, now: Date) -> EngineOutput {
        guard case .rating = phase, let i = Self.ratings.firstIndex(of: label) else { return EngineOutput() }
        phase = .rating(selected: i)
        return input(.press1, now: now)
    }

    /// Timer reached zero (the coordinator calls this at `endsAt`).
    mutating func expire(now: Date) -> EngineOutput {
        guard case let .running(e) = phase, now >= e else { return EngineOutput() }
        return finish(now: e, name: "focus_done")
    }

    private mutating func finish(now: Date, name: String) -> EngineOutput {
        endedAt = now
        phase = .rating(selected: 0)
        return EngineOutput(actions: [ratingHUD(0), .sound(.success)], name: name)
    }

    /// Leaving the mode mid-session: drop the session without a rating.
    mutating func abandon() {
        phase = .idle
    }
}
