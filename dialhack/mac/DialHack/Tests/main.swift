import Foundation

// Headless tests for Core (normalizer, mode engine, volume tracker, config).
// Run: ./build.sh test

var failures = 0
var passes = 0

func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("FAIL line \(line): \(msg)") }
}

func gestures(_ r: [Recognized]) -> [Gesture] { r.map(\.gesture) }

// MARK: GestureRecognizer

do {
    let g = GestureRecognizer(pickerWindowMs: 1000)
    check(gestures(g.feed(.volumeUp, at: 0)) == [.event(.rotateCW)], "volume up → CW")
    check(gestures(g.feed(.volumeDown, at: 10)) == [.event(.rotateCCW)], "volume down → CCW")
    check(gestures(g.feed(.playPause("play"), at: 20)) == [.event(.press1)], "play → PRESS_1")
    check(gestures(g.feed(.playPause("pause"), at: 30)) == [.event(.press1)], "pause → PRESS_1")
    check(gestures(g.feed(.previousTrack, at: 40)) == [.event(.press3)], "prev → PRESS_3")
}

do {
    let g = GestureRecognizer(pickerWindowMs: 1000)
    check(g.feed(.nextTrack, at: 0).isEmpty, "next is held")
    check(g.nextDeadline == 1000, "deadline set")
    check(g.tick(at: 999).isEmpty, "not expired yet")
    let r = g.tick(at: 1001)
    check(gestures(r) == [.event(.press2)], "expired hold → PRESS_2")
    check(r.first?.captureMs == 0, "PRESS_2 keeps original capture time")
    check(g.nextDeadline == nil, "nothing pending")
}

do {
    let g = GestureRecognizer(pickerWindowMs: 1000)
    _ = g.feed(.nextTrack, at: 0)
    let pick = g.feed(.volumeDown, at: 600)
    check(gestures(pick) == [.openModePicker(initialStep: -1)], "double press + turn → picker")
    check(pick.first?.consumedTurn == .volumeDown && pick.first?.raw == .nextTrack, "picker keeps the consumed turn for logging")
    check(gestures(g.feed(.volumeUp, at: 900)) == [.event(.rotateCW)], "later turns are plain rotations")
}

do {
    let g = GestureRecognizer(pickerWindowMs: 1000)
    _ = g.feed(.nextTrack, at: 0)
    check(gestures(g.feed(.volumeUp, at: 1500)) == [.event(.press2), .event(.rotateCW)], "turn after window → PRESS_2 then CW")
    _ = g.feed(.nextTrack, at: 2000)
    check(gestures(g.feed(.playPause("play"), at: 2100)) == [.event(.press2), .event(.press1)], "press flushes hold first")
    _ = g.feed(.nextTrack, at: 3000)
    check(gestures(g.feed(.nextTrack, at: 3200)) == [.event(.press2)], "second double ends first hold")
    check(g.nextDeadline == 4200, "second hold pending")
}

do {
    let g = GestureRecognizer(pickerWindowMs: 1000)
    g.immediatePress2 = true
    check(gestures(g.feed(.nextTrack, at: 0)) == [.event(.press2)], "immediate PRESS_2 while picker is open")
}

do {
    let g = GestureRecognizer(pickerWindowMs: 1000)
    g.pickerGesture = .hold
    check(gestures(g.feed(.nextTrack, at: 0)) == [.event(.press2)], "hold mode: double press is instant")
    check(g.nextDeadline == nil, "hold mode: nothing held back")
    check(gestures(g.feed(.previousTrack, at: 10)) == [.openModePicker(initialStep: 0)], "hold mode: hold opens picker")
    check(gestures(g.feed(.volumeUp, at: 20)) == [.event(.rotateCW)], "hold mode: turns stay rotations")
}

do {
    let e = ModeEngine(config: DialConfig())
    _ = e.handle(.openModePicker(initialStep: 0))
    check(e.pickerOpen, "hold opens picker on current mode")
    check(e.handle(.openModePicker(initialStep: 0)).name == "picker_cancel" && !e.pickerOpen, "second hold cancels")
}

do {
    let g = GestureRecognizer(pickerWindowMs: 500)
    g.pickerGesture = .wiggle
    g.wiggleWindowMs = 400
    check(gestures(g.feed(.nextTrack, at: 0)) == [.event(.press2)], "wiggle mode: double press is instant")
    check(gestures(g.feed(.volumeUp, at: 1000)) == [.event(.rotateCW)], "first click is a plain rotation")
    check(gestures(g.feed(.volumeDown, at: 1350)) == [.event(.rotateCCW), .openModePicker(initialStep: 0)], "CW→CCW in 350 ms = wiggle")
    check(gestures(g.feed(.volumeUp, at: 1700)) == [.event(.rotateCW)], "trigger resets: next click starts fresh")
    check(gestures(g.feed(.volumeDown, at: 2200)) == [.event(.rotateCCW)], "reversal after 500 ms isn't a wiggle")
    check(gestures(g.feed(.volumeUp, at: 2500)) == [.event(.rotateCW), .openModePicker(initialStep: 0)], "CCW→CW in 300 ms = wiggle (vice versa)")
    check(gestures(g.feed(.volumeUp, at: 3000)) == [.event(.rotateCW)], "same direction never triggers")
    check(gestures(g.feed(.volumeUp, at: 3100)) == [.event(.rotateCW)], "same direction never triggers (2)")
    g.suppressWiggle = true
    check(gestures(g.feed(.volumeDown, at: 3200)) == [.event(.rotateCCW)], "suppressed while picker open")
    check(gestures(g.feed(.volumeUp, at: 3300)) == [.event(.rotateCW)], "suppressed while picker open (2)")
    g.suppressWiggle = false
    check(gestures(g.feed(.previousTrack, at: 4000)) == [.event(.press3)], "wiggle mode: previous stays PRESS_3")
}

do {
    // Wiggle across a lazy restore: the restore echo is dropped by VolumeTracker, so only real clicks
    // (computed against the restored value) reach the recognizer, with the right direction.
    let t = VolumeTracker()
    let g = GestureRecognizer()
    g.pickerGesture = .wiggle
    func click(_ v: Float, _ at: Double) -> [Gesture] {
        guard case let .steps(dir, count, _, _) = t.feed(v, at: at) else { return [] }
        return (0..<count).flatMap { _ in gestures(g.feed(dir > 0 ? .volumeUp : .volumeDown, at: at)) }
    }
    _ = t.feed(0.8125, at: 0)                       // 13/16
    check(click(0.875, 100) == [.event(.rotateCW)], "click up to 14/16 (edge → restore)")
    t.expectSelf(target: 0.5, at: 110)              // edge restore to 8/16
    check(click(0.5, 160) == [], "restore echo is invisible to the recognizer")
    check(click(0.4375, 400) == [.event(.rotateCCW), .openModePicker(initialStep: 0)], "click down from 8/16 completes the wiggle")
}

do {
    var c = DialConfig()
    check(c.pickerWindowMs == 1200, "default picker window is 1200 ms")
    check(c.wiggleWindowMs == 400, "default wiggle window is 400 ms")
    check(c.autoPassthroughMinutes == 5, "auto-passthrough defaults to 5 min")
    check(c.restoreTiming == .everyClick, "volume goes back after every click by default")
    c.pickerGesture = .wiggle
    let data = try! JSONEncoder().encode(c)
    check((try! JSONDecoder().decode(DialConfig.self, from: data)).pickerGesture == .wiggle, "wiggle round-trips")
}

// MARK: ModeEngine

do {
    let e = ModeEngine(config: DialConfig())
    check(e.mode == .passthrough, "starts in passthrough")
    check(e.handle(.event(.rotateCW)).actions.isEmpty, "passthrough rotation does nothing itself")

    let open = e.handle(.openModePicker(initialStep: 1))
    check(e.pickerOpen, "picker open")
    check(open.actions.contains(.hud(.list(title: "Choose mode · turn, then press", items: ModeID.allCases.map(\.title), selected: 0))), "picker opens on the current mode (the opening turn doesn't move it)")
    _ = e.handle(.event(.rotateCW)); _ = e.handle(.event(.rotateCW)) // passthrough → scroll → scrub
    let sel = e.handle(.event(.press1))
    check(e.mode == .scrub && !e.pickerOpen, "press selects scrub")
    check(sel.actions.first == .setMode(.scrub), "setMode action")
    check(sel.name == "mode:scrub", "log name")

    check(e.handle(.event(.rotateCW)).actions == [.key(.key(KeyStroke.rightArrow))], "scrub CW → right arrow")
    check(e.handle(.event(.press2)).actions == [.key(.key(KeyStroke.keyL))], "scrub PRESS_2 → L")

    _ = e.handle(.openModePicker(initialStep: -1))
    let cancel = e.handle(.event(.press2))
    check(cancel.name == "picker_cancel" && e.mode == .scrub, "PRESS_2 cancels picker")

    _ = e.handle(.openModePicker(initialStep: -1))
    check(e.pickerTimedOut().name == "picker_timeout" && !e.pickerOpen, "picker timeout")

    _ = e.handle(.openModePicker(initialStep: 0))
    _ = e.handle(.event(.rotateCCW)); _ = e.handle(.event(.rotateCCW)) // scrub(2) → passthrough(0)
    _ = e.handle(.event(.rotateCCW)) // wraps → focus timer(5)
    _ = e.handle(.event(.press1))
    check(e.mode == ModeID.allCases.last, "picker wraps around")

    // From Focus Timer (the last mode), double press + turn opens on Focus Timer, not wrapped to the top.
    let fromFocus = e.handle(.openModePicker(initialStep: 1))
    check(fromFocus.actions.contains(.hud(.list(title: "Choose mode · turn, then press", items: ModeID.allCases.map(\.title),
                                                 selected: ModeID.allCases.count - 1))), "picker from Focus Timer opens on Focus Timer")
    _ = e.handle(.event(.rotateCCW))
    _ = e.handle(.event(.press1))
    check(e.mode == .macro, "one turn back from Focus Timer selects Macro")
}

do {
    var cfg = DialConfig()
    cfg.startMode = .scroll
    cfg.scrollLinesPerStep = 3
    let e = ModeEngine(config: cfg)
    check(e.handle(.event(.rotateCW)).actions == [.scroll(lines: 3)], "scroll down")
    check(e.handle(.event(.rotateCCW)).actions == [.scroll(lines: -3)], "scroll up")
    check(e.handle(.event(.press2)).actions == [.key(.key(KeyStroke.upArrow, .command))], "jump to top = cmd+up")
}

do {
    var cfg = DialConfig()
    cfg.startMode = .comboLock
    cfg.comboCode = [2, 9]
    let e = ModeEngine(config: cfg)
    _ = e.handle(.event(.rotateCW)); _ = e.handle(.event(.rotateCW)) // 2
    check(e.handle(.event(.press1)).name == "enter_digit", "first digit entered")
    _ = e.handle(.event(.rotateCCW)) // 1
    _ = e.handle(.event(.rotateCCW)) // 0
    _ = e.handle(.event(.rotateCCW)) // 9 (wrap)
    let r = e.handle(.event(.press1))
    check(r.name == "combo_unlock", "2-9 unlocks (with wrap)")
    _ = e.handle(.event(.press1)); let w = e.handle(.event(.press1))
    check(w.name == "combo_wrong", "0-0 is wrong")
    _ = e.handle(.event(.rotateCW)); _ = e.handle(.event(.press1))
    check(e.handle(.event(.press2)).name == "combo_reset", "reset")
}

do {
    var cfg = DialConfig()
    cfg.startMode = .macro
    let e = ModeEngine(config: cfg)
    _ = e.handle(.event(.rotateCW))
    let run = e.handle(.event(.press1))
    check(run.actions.contains(.runMacro(DialConfig.defaultMacros[1])), "runs second macro")
    check(e.handle(.event(.press2)).name == "macro_cancel", "cancel")
    _ = e.handle(.event(.rotateCCW)); _ = e.handle(.event(.rotateCCW))
    check(e.handle(.event(.press1)).name == "run_macro:\(DialConfig.defaultMacros.last!.name)", "wraps backwards")
}

// MARK: FocusTimer

func labels(_ out: EngineOutput) -> [LabelRecord] {
    out.actions.compactMap { if case let .label(r) = $0 { return r } else { return nil } }
}

do {
    var cfg = DialConfig()
    cfg.startMode = .focusTimer
    cfg.focusMinutes = 25
    let e = ModeEngine(config: cfg)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    _ = e.handle(.event(.rotateCCW), now: t0)
    check(e.focus.minutes == 20, "turn sets length in 5-min steps")
    for _ in 0..<10 { _ = e.handle(.event(.rotateCCW), now: t0) }
    check(e.focus.minutes == 5, "length floors at 5 min")
    _ = e.handle(.event(.rotateCW), now: t0)   // 10 min
    check(e.handle(.event(.press2), now: t0).name == "focus_idle" && !e.focus.isActive, "double press does nothing before start")

    let start = e.handle(.event(.press1), now: t0)
    check(start.name == "focus_start" && e.focus.endsAt == t0.addingTimeInterval(600), "press starts a 10-min session")
    check(e.handle(.event(.rotateCW), now: t0 + 5).name == "focus_fidget", "turns while running are just fidgeting")
    check(e.focus.minutes == 10, "fidgeting doesn't change the length")

    let tag = e.handle(.event(.press2), now: t0 + 60)
    let tl = labels(tag)
    check(tl.count == 1 && tl[0].label == "distracted" && tl[0].source == LabelRecord.tagSource && tl[0].ts == t0 + 60,
          "double press = distracted tag, timestamped")
    check(tl[0].focusSession == e.focus.sessionId && !e.focus.sessionId.isEmpty, "tag carries the focus session id")

    _ = e.handle(.event(.press1), now: t0 + 120)   // pause with 480 s left
    check(e.focus.remaining(at: t0 + 300) == 480, "paused time doesn't run")
    _ = e.handle(.event(.press1), now: t0 + 300)   // resume → ends at t0+780
    check(e.focus.endsAt == t0 + 780, "resume keeps the remaining time")
    check(e.focusExpired(now: t0 + 700).actions.isEmpty, "not expired early")

    let done = e.focusExpired(now: t0 + 781)
    check(done.name == "focus_done", "expiry → rating")
    _ = e.handle(.event(.rotateCW), now: t0 + 790)   // focused → distracted
    _ = e.handle(.event(.rotateCW), now: t0 + 791)   // → stressed
    let rated = labels(e.handle(.event(.press1), now: t0 + 792))
    check(rated.count == 1 && rated[0].label == "stressed" && rated[0].source == LabelRecord.sessionSource, "rating saved as session label")
    check(rated[0].start == t0 && rated[0].end == t0 + 780, "session label spans start → end")
    check(!e.focus.isActive, "back to idle after rating")

    _ = e.handle(.event(.press1), now: t0 + 1000)
    _ = e.focusExpired(now: t0 + 2000)
    let viaApp = labels(e.focusRate("bored", now: t0 + 2001))
    check(viaApp.count == 1 && viaApp[0].label == "bored" && viaApp[0].source == LabelRecord.sessionSource, "one-click rating from the window")
    check(e.focusRate("bored", now: t0 + 2002).actions.isEmpty, "rating only works when a rating is pending")
}

do {
    var cfg = DialConfig()
    cfg.startMode = .focusTimer
    let e = ModeEngine(config: cfg)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    _ = e.handle(.event(.press1), now: t0)
    _ = e.handle(.event(.press1), now: t0 + 10)        // pause
    check(e.handle(.event(.press2), now: t0 + 20).name == "focus_end_early", "double press while paused ends early")
    check(labels(e.handle(.event(.press2), now: t0 + 21)).isEmpty && !e.focus.isActive, "skipping the rating saves nothing")

    _ = e.handle(.event(.press1), now: t0 + 100)
    _ = e.setMode(.scroll)
    check(!e.focus.isActive, "leaving the mode abandons the session")
    _ = e.setMode(.focusTimer)
    check(e.focusExpired(now: t0 + 100_000).actions.isEmpty, "abandoned session never asks for a rating")
}

// MARK: Insights IO

do {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for t in ["2026-10-20T02:08:11.264Z", "2024-02-29T23:59:59.999Z", "1999-12-31T00:00:00.000Z", "2026-01-01T00:00:00.001Z"] {
        check(InsightsIO.parseDate(t) == iso.date(from: t), "fast date parse matches formatter: \(t)")
    }
    check(InsightsIO.parseDate("2026-10-20T02:08:11Z") == ISO8601DateFormatter().date(from: "2026-10-20T02:08:11Z"), "no-millis format")
    check(InsightsIO.parseDate("2026-10-20T02:08:11.264+02:00") != nil, "other formats fall back to the formatter")
    check(InsightsIO.parseDate("garbage") == nil, "garbage → nil")

    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dh-\(UUID().uuidString).jsonl")
    try? "{\"a\":1}\nnot json\n\n{\"a\":2}\n".write(to: url, atomically: true, encoding: .utf8)
    check(InsightsIO.jsonLines(url).count == 2, "malformed lines are skipped, good ones kept")
    try? FileManager.default.removeItem(at: url)
}

// MARK: VolumeTracker

do {
    let t = VolumeTracker()
    check(t.feed(0.5, at: 0) == .ignored("initial"), "first reading")
    check(t.feed(0.5625, at: 10) == .steps(direction: 1, count: 1, from: 0.5, to: 0.5625), "one step up")
    for i in 0..<4 { check(t.feed(0.5625, at: 11 + Double(i)) == .ignored("duplicate"), "duplicate \(i)") }
    t.expectSelf(target: 0.5, at: 100)
    check(t.feed(0.5, at: 120) == .ignored("self"), "own restore is ignored")
    check(t.feed(0.4375, at: 200) == .steps(direction: -1, count: 1, from: 0.5, to: 0.4375), "user step inside window still counts")
    check(t.feed(0.5, at: 300) == .steps(direction: 1, count: 1, from: 0.4375, to: 0.5), "back at target counts after leaving it")
    t.expectSelf(target: 0.5, at: 1000)
    check(t.feed(0.625, at: 2000) == .steps(direction: 1, count: 2, from: 0.5, to: 0.625), "two-step jump, outside window")
    check(VolumeTracker.level(0.5) == 8, "level")
    check(VolumeTracker.parkLevel(for: 0.25) == 0.25, "park at the user's own level (4/16)")
    check(VolumeTracker.parkLevel(for: 0.3) == 0.3125, "park snaps to the 1/16 grid")
    check(VolumeTracker.parkLevel(for: 0.05) == 0.1875 && VolumeTracker.parkLevel(for: 0) == 0.1875, "keep 3 clicks above silent")
    check(VolumeTracker.parkLevel(for: 1.0) == 0.8125, "keep 3 clicks below max")
    check(VolumeTracker.nearEdge(0.125, edgeSteps: 2) && VolumeTracker.nearEdge(0.875, edgeSteps: 2), "edges")
    check(!VolumeTracker.nearEdge(0.5, edgeSteps: 2) && !VolumeTracker.nearEdge(0.8125, edgeSteps: 2), "not edges")
}

// MARK: Config

do {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dialhack-test-\(UUID().uuidString).json")
    var c = DialConfig()
    c.comboCode = [7, 7]
    c.save(to: url)
    check(DialConfig.load(from: url) == c, "config round-trips")
    try? #"{"scrollLinesPerStep": 9}"#.data(using: .utf8)!.write(to: url)
    let partial = DialConfig.load(from: url)
    check(partial.scrollLinesPerStep == 9 && partial.macros == DialConfig.defaultMacros, "partial config keeps defaults")
    try? FileManager.default.removeItem(at: url)
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
