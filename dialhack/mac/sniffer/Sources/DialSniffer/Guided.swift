import AppKit
import CoreGraphics
import Foundation

// Guided mode: walks the operator through the Phase 0 protocol, auto-detects each gesture,
// switches labels and sniffer settings itself, and writes docs/sniffer-report.md at the end.
// Sections run in priority order so a partial run is still useful.

/// Thread-safe buffer of capture events, fed by SnifferLog.observer.
final class EventInbox {
    struct Ev {
        let mono: Double
        let method: String
        let raw: String
        let fields: [String: Any]
        var isRelease: Bool { (fields["state"] as? String) == "up" || (fields["action"] as? String) == "up" }
        var step127: Double? { fields["step_127"] as? Double }
    }

    private let cond = NSCondition()
    private var events: [Ev] = []

    func add(_ r: SnifferLog.Record) {
        guard r.kind == "capture" else { return }
        cond.lock()
        events.append(Ev(mono: r.monoMs, method: r.method, raw: r.raw, fields: r.fields))
        if events.count > 5000 { events.removeFirst(1000) }
        cond.broadcast()
        cond.unlock()
    }

    func since(_ t: Double) -> [Ev] {
        cond.lock(); defer { cond.unlock() }
        return events.filter { $0.mono >= t }
    }

    private func lastMono() -> Double? {
        cond.lock(); defer { cond.unlock() }
        return events.last?.mono
    }

    /// First capture event at or after `t`, or nil on timeout / cancel.
    func waitFirst(since t: Double, timeout: Double, cancel: () -> Bool) -> Ev? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cancel() { return nil }
            cond.lock()
            if let e = events.first(where: { $0.mono >= t }) { cond.unlock(); return e }
            cond.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
            cond.unlock()
        }
        return nil
    }

    /// Waits until no capture event has arrived for `quietMs` (capped at `maxMs`), then returns events since `t`.
    func collectUntilQuiet(since t: Double, quietMs: Double, maxMs: Double) -> [Ev] {
        let start = SnifferLog.monoMs()
        while SnifferLog.monoMs() - start < maxMs {
            let last = lastMono() ?? 0
            if SnifferLog.monoMs() - max(last, start) >= quietMs { break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return since(t)
    }

    /// Blocks until the dial has been still for `quietMs` (so stray events don't leak into the next prompt).
    func settle(quietMs: Double, maxMs: Double = 3000) {
        _ = collectUntilQuiet(since: SnifferLog.monoMs(), quietMs: quietMs, maxMs: maxMs)
    }
}

enum TrialState { case info, waiting, got, miss, done }

protocol GuidedUI: AnyObject {
    func update(section: String, prompt: String, detail: String, progress: Double, state: TrialState)
    func note(_ line: String)
    /// Blocks the calling (runner) thread until a button is clicked, or returns `fallback` after `timeout`.
    func choose(_ prompt: String, detail: String, options: [String], timeout: Double?, fallback: String) -> String
    func setSkippable(_ on: Bool)
    var skipRequested: Bool { get }
    func clearSkip()
}

final class GuidedRunner {
    let ui: GuidedUI
    let fast: Bool
    let useTap: Bool
    let inbox = EventInbox()

    private let abortLock = NSLock()
    private var _aborted = false
    var aborted: Bool {
        get { abortLock.lock(); defer { abortLock.unlock() }; return _aborted }
        set { abortLock.lock(); _aborted = newValue; abortLock.unlock() }
    }

    private var tapRunning = false
    private var startVolume: Float32?
    private var stepSize127: Double?
    private var sectionIndex = 0
    private var sectionTitle = ""
    private var completed: [String] = []
    private var flags: [String] = [] // findings that could block the design

    /// Section ids to run (`--only hold,single`); nil = the full protocol.
    let only: Set<String>?
    /// Only for dry runs (`--report PATH`): the .app can't read or write ~/Documents (TCC), so normal
    /// runs leave report generation to run-guided.sh.
    let reportPath: String?

    init(ui: GuidedUI, fast: Bool, useTap: Bool, reportPath: String?, only: Set<String>? = nil) {
        self.ui = ui
        self.fast = fast
        self.useTap = useTap
        self.reportPath = reportPath
        self.only = only
    }

    /// Normal duration, or a tiny one in --fast dry-run mode.
    private func dur(_ s: Double) -> Double { fast ? min(s, 0.25) : s }
    private func pause(_ s: Double) { Thread.sleep(forTimeInterval: dur(s)) }
    private func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.sync(execute: f) }

    private func sound(_ name: String) {
        guard !fast else { return }
        DispatchQueue.main.async { NSSound(named: NSSound.Name(name))?.play() }
    }

    // MARK: - settings

    private func configure(audio: Bool = true, nowPlaying: Bool = true, restore: Bool = false) {
        onMain {
            silent.set(audio)
            remote.setNowPlaying(nowPlaying)
        }
        coreAudio.setRestore(restore)
        log.write(kind: "control", method: "restore", raw: restore ? "on" : "off")
        log.write(kind: "control", method: "guided.config", raw: "set",
                  fields: ["audio": audio, "now_playing": nowPlaying, "restore": restore])
    }

    private func resetVolume() {
        log.setLabel("guided_pause")
        coreAudio.setVolumeTagged(0.5)
        Thread.sleep(forTimeInterval: fast ? 0.1 : 0.6)
        inbox.settle(quietMs: fast ? 50 : 300)
    }

    // MARK: - sections

    private typealias Section = (id: String, title: String, run: () -> Void)

    /// Ids for `--only`. "hold" isn't part of the full protocol; it's the targeted press-and-hold retest.
    static let sectionIds = ["idle", "single", "rotate", "double", "triple", "long", "fast", "restore",
                             "nowplaying", "latency", "keyboard", "competing", "hold", "wiggle"]
    /// Retests that aren't part of the full protocol; they only run via --only.
    static let retestIds: Set<String> = ["hold", "wiggle"]

    private var sections: [Section] {
        let all: [Section] = [
            ("idle", "Idle drift check", idleDrift),
            ("single", "Single press", { self.presses("press_single", "Press the dial ONCE now", count: 5, missLimit: 3, blocker: true) }),
            ("rotate", "Rotation, one click at a time", rotations),
            ("double", "Double press", { self.presses("press_double", "DOUBLE-press the dial now", count: 5, missLimit: 2) }),
            ("triple", "Triple press", { self.presses("press_triple", "TRIPLE-press the dial now", count: 5, missLimit: 2) }),
            ("long", "Long press", { self.presses("press_long", "Press and HOLD the dial for 2 seconds, then let go", count: 3, missLimit: 2, timeout: 14) }),
            ("fast", "Fast spins", fastSpins),
            ("restore", "Volume restore test", restoreTest),
            ("nowplaying", "Now Playing variants", nowPlayingVariants),
            ("latency", "Latency markers", latencyMarkers),
            ("keyboard", "Keyboard media key control", keyboardControl),
            ("competing", "Competing media app", competingApp),
            ("hold", "Press-and-hold retest", holdRetest),
            ("wiggle", "Wiggle retest", wiggleRetest),
        ]
        guard let only else { return all.filter { !Self.retestIds.contains($0.id) } }
        return all.filter { only.contains($0.id) }
    }

    func run() {
        log.write(kind: "control", method: "guided", raw: "start",
                  fields: ["fast": fast, "use_tap": useTap, "only": only.map { Array($0).sorted() } as Any])
        if preflight() {
            let all = sections
            for (i, s) in all.enumerated() {
                if aborted { break }
                sectionIndex = i
                sectionTitle = "Step \(i + 1) of \(all.count) · \(s.title)"
                log.write(kind: "control", method: "guided.section", raw: "start", fields: ["section": s.title, "index": i + 1])
                s.run()
                log.setLabel("guided_pause")
                if aborted { break }
                completed.append(s.title)
                log.write(kind: "control", method: "guided.section", raw: "done", fields: ["section": s.title, "index": i + 1])
                sound("Glass")
            }
        }
        finish()
    }

    private func show(_ prompt: String, _ detail: String = "", _ state: TrialState = .info) {
        let total = Double(sections.count)
        ui.update(section: sectionTitle, prompt: prompt, detail: detail,
                  progress: total > 0 ? Double(sectionIndex) / total : 0, state: state)
    }

    // MARK: preflight

    private func preflight() -> Bool {
        sectionTitle = "Getting ready"
        // 1. Buds must be the Bluetooth default output.
        var snap = coreAudio.snapshot()
        if snap.transport != "blue" && !fast {
            show("Select CMF Buds Pro 2 as the sound output",
                 "Control Center → Sound → CMF Buds Pro 2. This continues by itself once the buds are the output.\nCurrent output: \(snap.name)")
            while snap.transport != "blue" && !aborted {
                Thread.sleep(forTimeInterval: 1)
                snap = coreAudio.snapshot()
            }
            if aborted { return false }
        }
        startVolume = snap.volume

        // 2. Input Monitoring for the event tap (media keys path B).
        if useTap {
            if CGPreflightListenEventAccess() {
                tapRunning = onMainResult { eventTap.start() }
            } else if !fast {
                CGRequestListenEventAccess()
                let choice = ui.choose(
                    "Allow Input Monitoring for DialSniffer",
                    detail: "macOS just asked. In System Settings → Privacy & Security → Input Monitoring, turn ON DialSniffer (if it's already on, turn it off and on again), then click Relaunch here. If macOS offers \"Quit & Reopen\", that works too.\nThis is for one of the three capture paths; you can also continue without it.",
                    options: ["Relaunch", "Continue without it"], timeout: nil, fallback: "Continue without it")
                if choice == "Relaunch" {
                    log.write(kind: "control", method: "guided", raw: "relaunch_for_permission")
                    relaunch()
                    return false
                }
                log.write(kind: "control", method: "event_tap", raw: "skipped_no_permission")
            }
        } else {
            log.write(kind: "control", method: "event_tap", raw: "disabled_by_flag")
        }

        // 3. Checklist.
        let media = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).compactMap { StartupCheck.mediaApps[$0] }
        var detail = """
        • Buds connected to this Mac only: turn OFF Bluetooth on your phone
        • Nothing X: dial on, rotate = volume, presses = play/pause / next / previous
        • No music or video playing anywhere
        • Hands off the dial until a step asks for it
        Output: \(snap.name) · volume \(snap.volume.map { String(format: "%.0f/127", $0 * 127) } ?? "?") · media-key tap: \(tapRunning ? "on" : "off")
        """
        if !media.isEmpty { detail += "\n⚠︎ Please quit: \(media.sorted().joined(separator: ", "))" }
        detail += "\nAbout 10–15 minutes. Steps are ordered by importance, so you can close the window anytime and the results so far are kept."
        _ = ui.choose("Ready to test the dial?", detail: detail, options: ["Start"], timeout: fast ? 0 : nil, fallback: "Start")
        configure()
        return !aborted
    }

    private func onMainResult<T>(_ f: @escaping () -> T) -> T {
        var r: T!
        DispatchQueue.main.sync { r = f() }
        return r
    }

    private func relaunch() {
        let marker = log.url.deletingLastPathComponent().appendingPathComponent(".relaunch")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        if ProcessInfo.processInfo.environment["DIALSNIFFER_WRAPPED"] == nil {
            // Not under run-guided.sh: relaunch ourselves.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", Bundle.main.bundlePath, "--args"] + argv
            try? p.run()
        }
        DispatchQueue.main.async { exit(0) }
    }

    // MARK: trials

    /// Runs up to `count` trials. Each shows a prompt, waits for any capture event, then waits for quiet.
    @discardableResult
    private func trials(count: Int, timeout: Double = 10, missLimit: Int = 3, quietMs: Double = 700,
                        skippable: Bool = true, extra: [String: Any] = [:],
                        _ trial: (Int) -> (label: String, prompt: String)) -> [[EventInbox.Ev]] {
        var results: [[EventInbox.Ev]] = []
        var misses = 0
        ui.clearSkip()
        ui.setSkippable(skippable)
        defer { ui.setSkippable(false); ui.clearSkip() }

        for i in 0..<count {
            if aborted { break }
            let (label, prompt) = trial(i)
            log.setLabel(label)
            inbox.settle(quietMs: fast ? 50 : 400)
            let since = SnifferLog.monoMs()
            show(prompt, "\(i + 1) of \(count)", .waiting)

            if inbox.waitFirst(since: since, timeout: dur(timeout), cancel: { self.aborted || self.ui.skipRequested }) != nil {
                let burst = inbox.collectUntilQuiet(since: since, quietMs: quietMs, maxMs: 6000)
                misses = 0
                results.append(burst)
                let summary = describe(burst)
                log.write(kind: "control", method: "guided.trial", raw: "detected", fields: extra.merging([
                    "trial": i + 1, "of": count, "events": burst.count,
                    "methods": Array(Set(burst.map(\.method))).sorted(),
                    "raws": burst.filter { !$0.isRelease }.map(\.raw),
                    "step_127_total": primarySteps(burst).reduce(0, +),
                    "reaction_ms": (burst.first?.mono ?? since) - since,
                ]) { a, _ in a })
                show("Got it ✓", summary, .got)
                ui.note("\(label) #\(i + 1): \(summary)")
                sound("Tink")
                pause(0.7)
            } else if ui.skipRequested {
                log.write(kind: "control", method: "guided.trial", raw: "skipped", fields: extra.merging(["trial": i + 1, "of": count]) { a, _ in a })
                ui.note("\(label): skipped")
                break
            } else if aborted {
                break
            } else {
                misses += 1
                log.write(kind: "control", method: "guided.trial", raw: "timeout", fields: extra.merging(["trial": i + 1, "of": count]) { a, _ in a })
                show("Nothing detected", "That's useful data too. \(misses < missLimit ? "Let's try again." : "Moving on.")", .miss)
                ui.note("\(label) #\(i + 1): nothing detected")
                sound("Basso")
                pause(1.5)
                if misses >= missLimit {
                    log.write(kind: "control", method: "guided.step", raw: "gave_up", fields: ["label": label, "misses": misses])
                    break
                }
            }
        }
        return results
    }

    private func primarySteps(_ burst: [EventInbox.Ev]) -> [Double] {
        let primary = burst.contains { $0.method == "coreaudio.virtual_main" } ? "coreaudio.virtual_main" : "coreaudio.scalar_ch1"
        return burst.filter { $0.method == primary }.compactMap(\.step127)
    }

    private func describe(_ burst: [EventInbox.Ev]) -> String {
        var parts: [String] = []
        let steps = primarySteps(burst)
        if !steps.isEmpty {
            let total = steps.reduce(0, +)
            parts.append(String(format: "volume %@%.1f/127 in %d event%@", total >= 0 ? "+" : "", total, steps.count, steps.count == 1 ? "" : "s"))
        }
        let keys = burst.filter { !$0.method.hasPrefix("coreaudio.") && !$0.isRelease }
        let grouped = Dictionary(grouping: keys, by: \.method)
        for (m, evs) in grouped.sorted(by: { $0.key < $1.key }) {
            parts.append("\(m): \(evs.map(\.raw).joined(separator: ", "))")
        }
        return parts.isEmpty ? "\(burst.count) events" : parts.joined(separator: " · ")
    }

    // MARK: protocol sections

    private func idleDrift() {
        resetVolume()
        log.setLabel("idle_drift")
        let seconds = fast ? 1 : 30
        let since = SnifferLog.monoMs()
        for left in stride(from: seconds, to: 0, by: -1) {
            if aborted { return }
            show("Don't touch the dial", "Checking that the volume stays put on its own… \(left)s", .waiting)
            Thread.sleep(forTimeInterval: fast ? 0.2 : 1)
        }
        let drift = inbox.since(since).filter { $0.method.hasPrefix("coreaudio.") }
        let steps = drift.filter { $0.method == "coreaudio.virtual_main" }.compactMap(\.step127)
        let result = drift.isEmpty ? "stable" : "drift"
        log.write(kind: "control", method: "guided.idle_result", raw: result, fields: [
            "events": drift.count, "step_127_total": steps.reduce(0, +), "seconds": seconds,
            "first_after_ms": drift.first.map { $0.mono - since } as Any,
        ])
        if drift.isEmpty {
            show("Volume is stable ✓", "No changes in \(seconds) seconds.", .got)
            ui.note("idle: stable for \(seconds)s")
        } else {
            flags.append("volume changed on its own during the idle check")
            show("Volume changed by itself", String(format: "%d changes, net %+.1f/127. Logged; continuing.", drift.count, steps.reduce(0, +)), .miss)
            ui.note("idle: volume drifted (\(drift.count) events)")
        }
        pause(2)
    }

    private func presses(_ label: String, _ prompt: String, count: Int, missLimit: Int, timeout: Double = 10, blocker: Bool = false) {
        let r = trials(count: count, timeout: timeout, missLimit: missLimit, quietMs: 1000) { _ in (label, prompt) }
        if blocker && r.isEmpty && !aborted && !ui.skipRequested {
            flags.append("no \(label) events reached the Mac")
        }
    }

    private func rotations() {
        resetVolume()
        // Alternate right/left so volume stays near the middle whatever the step size is.
        let bursts = trials(count: 20, timeout: 10, missLimit: 4, quietMs: 600) { i in
            i % 2 == 0 ? ("rotate_cw", "Turn the dial RIGHT one click") : ("rotate_ccw", "Turn the dial LEFT one click")
        }
        let perClick = bursts.map { abs(primarySteps($0).reduce(0, +)) }.filter { $0 > 0 }.sorted()
        if !perClick.isEmpty {
            stepSize127 = perClick[perClick.count / 2]
            log.write(kind: "control", method: "guided.step_size", raw: "measured", fields: ["step_127": stepSize127!])
        }
    }

    /// Clicks per fast spin: 10, fewer if big steps would clamp at 127 from the 64 baseline.
    private var spinClicks: Int {
        guard let s = stepSize127, s > 0 else { return 10 }
        return max(3, min(10, Int(50 / s)))
    }

    private func fastSpins() {
        let n = spinClicks
        log.write(kind: "control", method: "guided.fast_clicks", raw: "\(n)", fields: ["clicks": n])
        for i in 0..<6 {
            if aborted || ui.skipRequested { break }
            resetVolume()
            let right = i % 2 == 0
            trials(count: 1, timeout: 15, missLimit: 1, quietMs: 900, extra: ["instructed_clicks": n]) { _ in
                (right ? "fast_cw" : "fast_ccw",
                 "Spin \(right ? "RIGHT" : "LEFT") FAST: exactly \(n) clicks\n(spin \(i / 2 + 1) of 3)")
            }
        }
    }

    private func restoreTest() {
        resetVolume()
        configure(restore: true)
        trials(count: 10, timeout: 10, missLimit: 3, quietMs: 700) { i in
            i % 2 == 0 ? ("rotate_cw_restore", "Turn RIGHT one click") : ("rotate_ccw_restore", "Turn LEFT one click")
        }
        trials(count: 2, timeout: 15, missLimit: 1, quietMs: 900, extra: ["instructed_clicks": 10]) { i in
            ("fast_cw_restore", "Spin RIGHT FAST: about 10 clicks (\(i + 1) of 2)")
        }
        let blips = ui.choose("Did you hear clicks, pops or dropouts in the buds just now?",
                              detail: "The sniffer was snapping the volume back to 50% after every click.",
                              options: ["Yes, blips", "No, silent", "Not sure"], timeout: fast ? 0 : 90, fallback: "Not sure")
        log.write(kind: "control", method: "guided.blips", raw: blips)
        configure(restore: false)
        resetVolume()
    }

    private func nowPlayingVariants() {
        configure(audio: false, nowPlaying: true)
        trials(count: 5, timeout: 10, missLimit: 2, quietMs: 1000) { _ in ("press_single_noaudio", "Press the dial ONCE now\n(silent audio is off)") }
        configure(audio: true, nowPlaying: false)
        trials(count: 5, timeout: 10, missLimit: 2, quietMs: 1000) { _ in ("press_single_nonp", "Press the dial ONCE now\n(Now Playing is off)") }
        configure()
    }

    private func latencyMarkers() {
        guard tapRunning else {
            log.write(kind: "control", method: "guided.section", raw: "skipped", fields: ["section": "Latency markers", "reason": "event tap not running"])
            show("Skipping latency markers", "They need the Input Monitoring permission.", .info)
            pause(2)
            return
        }
        resetVolume()
        trials(count: 8, timeout: 10, missLimit: 3, quietMs: 700) { i in
            i % 2 == 0
                ? ("rotate_cw_marked", "Tap RIGHT SHIFT and turn the dial RIGHT one click at the same instant")
                : ("rotate_ccw_marked", "Tap RIGHT SHIFT and turn the dial LEFT one click at the same instant")
        }
        trials(count: 6, timeout: 10, missLimit: 3, quietMs: 1000) { _ in
            ("press_single_marked", "Tap RIGHT SHIFT and press the dial ONCE at the same instant")
        }
    }

    private var holdSummary: String?

    /// Targeted retest after mapping press-and-hold to "skip back" in Nothing X: does previousTrack arrive?
    private func holdRetest() {
        let bursts = trials(count: 10, timeout: 15, missLimit: 10, quietMs: 1200) { _ in
            ("press_hold", "Press and HOLD the dial until it reacts (about 2 s), then let go")
        }
        let prev = bursts.filter { b in b.contains { $0.raw == "previousTrack" && !$0.isRelease } }.count
        let other = bursts.count - prev
        holdSummary = "previousTrack arrived in \(prev) of 10 holds" + (other > 0 ? " (\(other) other events)" : "")
        log.write(kind: "control", method: "guided.hold_result", raw: prev >= 8 ? "reliable" : "unreliable",
                  fields: ["previous_track": prev, "detected": bursts.count, "of": 10])
        show(holdSummary!, prev >= 8 ? "Reliable." : "Not reliable enough (need 8 of 10).", prev >= 8 ? .got : .miss)
        pause(3)
    }

    static let wiggleWindowMs: Double = 400

    /// DialHack's wiggle rule (GestureRecognizer): consecutive opposite clicks within the window
    /// trigger once, then detection starts fresh. Returns (triggers, gap of each opposite pair).
    static func wiggles(in evs: [EventInbox.Ev], windowMs: Double) -> (triggers: Int, gaps: [Double]) {
        let clicks = evs.filter { $0.method == "coreaudio.virtual_main" && ($0.raw == "VOLUME_UP" || $0.raw == "VOLUME_DOWN") }
        var last: (dir: Int, t: Double)?
        var triggers = 0
        var gaps: [Double] = []
        for c in clicks {
            let dir = c.raw == "VOLUME_UP" ? 1 : -1
            if let l = last, l.dir != dir {
                gaps.append(c.mono - l.t)
                if c.mono - l.t <= windowMs {
                    triggers += 1
                    last = nil
                    continue
                }
            }
            last = (dir, c.mono)
        }
        return (triggers, gaps)
    }

    private var wiggleSummary: String?

    /// Experimental wiggle gesture: 10 intentional wiggles, then 30 s of normal volume adjusting
    /// (false triggers), under DialHack-style lazy restore.
    private func wiggleRetest() {
        let w = Self.wiggleWindowMs
        resetVolume()
        coreAudio.setLazyRestore(true)
        log.write(kind: "control", method: "lazy_restore", raw: "on")
        defer {
            coreAudio.setLazyRestore(false)
            log.write(kind: "control", method: "lazy_restore", raw: "off")
        }

        var detected = 0
        var attempts = 0
        for i in 0..<10 {
            if aborted || ui.skipRequested { break }
            let rightFirst = i % 2 == 0
            let bursts = trials(count: 1, timeout: 12, missLimit: 1, quietMs: 900, extra: ["wiggle_trial": i + 1]) { _ in
                ("wiggle", rightFirst
                    ? "WIGGLE: one click RIGHT, then straight back one click LEFT\n(\(i + 1) of 10, quick as you can)"
                    : "WIGGLE: one click LEFT, then straight back one click RIGHT\n(\(i + 1) of 10, quick as you can)")
            }
            guard let burst = bursts.first else { continue }
            attempts += 1
            let (n, gaps) = Self.wiggles(in: burst, windowMs: w)
            let ok = n > 0
            if ok { detected += 1 }
            let gapText = gaps.first.map { String(format: "%.0f ms", $0) } ?? "no reversal"
            log.write(kind: "control", method: "guided.wiggle", raw: ok ? "detected" : "missed",
                      fields: ["trial": i + 1, "gaps_ms": gaps, "window_ms": w])
            show(ok ? "Wiggle detected ✓" : "Not a wiggle", ok ? "Gap \(gapText)." : "Gap: \(gapText) (needs ≤ \(Int(w)) ms).", ok ? .got : .miss)
            ui.note("wiggle #\(i + 1): \(ok ? "✓" : "✗") \(gapText)")
            pause(1.2)
        }

        // Normal adjusting: count wiggles that would fire by accident.
        resetVolume()
        log.setLabel("wiggle_free")
        let since = SnifferLog.monoMs()
        let seconds = fast ? 1 : 30
        for left in stride(from: seconds, to: 0, by: -1) {
            if aborted { break }
            show("Now adjust the volume normally for \(left)s",
                 "Turn it up and down a few clicks at a time, like fine-tuning volume while listening. Don't wiggle on purpose.", .waiting)
            Thread.sleep(forTimeInterval: fast ? 0.2 : 1)
        }
        let free = inbox.since(since)
        let (falseTriggers, _) = Self.wiggles(in: free, windowMs: w)
        let freeClicks = free.filter { $0.method == "coreaudio.virtual_main" && $0.raw != "VOLUME_SAME" }.count
        log.setLabel("guided_pause")
        log.write(kind: "control", method: "guided.wiggle_result", raw: detected >= 8 && falseTriggers <= 1 ? "pass" : "fail",
                  fields: ["detected": detected, "attempts": attempts, "of": 10, "false_triggers": falseTriggers,
                           "free_clicks": freeClicks, "free_seconds": seconds, "window_ms": w])
        wiggleSummary = "Wiggles detected: \(detected) of 10 · false triggers: \(falseTriggers) in \(seconds) s (\(freeClicks) clicks)"
        show(wiggleSummary!, detected >= 8 && falseTriggers <= 1 ? "Passes the bar." : "Doesn't pass the bar (8/10 and ≤ 1 false trigger).",
             detected >= 8 && falseTriggers <= 1 ? .got : .miss)
        pause(4)
    }

    private func keyboardControl() {
        trials(count: 3, timeout: 10, missLimit: 2, quietMs: 800) { _ in
            ("keyboard_media_keys", "Press your KEYBOARD's play/pause key (F8)\nNot the dial; this is the comparison")
        }
    }

    private func competingApp() {
        let c = ui.choose("Last one (optional): play music in Spotify or Music",
                          detail: "Start a song, then click Ready. This tests whether another app steals the dial's presses.",
                          options: ["Ready", "Skip"], timeout: fast ? 0 : 120, fallback: "Skip")
        log.write(kind: "control", method: "guided.competing_app", raw: c)
        guard c == "Ready" else { return }
        trials(count: 5, timeout: 10, missLimit: 2, quietMs: 1000) { _ in ("press_single_competing", "Press the dial ONCE now\n(with the other app playing)") }
        _ = ui.choose("Done. You can pause the other app now.", detail: "", options: ["OK"], timeout: fast ? 0 : 30, fallback: "OK")
    }

    // MARK: finish

    private func finish() {
        log.setLabel("guided_end")
        coreAudio.setRestore(false)
        if let v = startVolume { coreAudio.setVolumeTagged(v) }
        log.write(kind: "control", method: "guided", raw: aborted ? "ended_early" : "complete",
                  fields: ["sections_done": completed, "flags": flags])
        sectionTitle = "Finished"
        show("Writing the report…", "", .info)
        Thread.sleep(forTimeInterval: 0.8) // let the log queue flush
        // run-guided.sh reads this to build the report for exactly this session.
        try? log.sessionId.write(to: log.url.deletingLastPathComponent().appendingPathComponent(".last-guided-session"),
                                 atomically: true, encoding: .utf8)
        var detail = "Results saved. Claude takes it from here."
        if reportPath != nil { detail = writeReport() ? "Report: \(reportPath!)" : "Couldn't write the report; raw log: \(log.url.path)" }
        let msg = aborted ? "Stopped early. Results so far are saved." : "All done. Thank you!"
        let summary = [holdSummary, wiggleSummary].compactMap { $0 }.joined(separator: "\n")
        show(msg, summary.isEmpty ? detail : "\(summary)\n\(detail)", .done)
        sound("Glass")
        Thread.sleep(forTimeInterval: fast ? 0 : 4)
        DispatchQueue.main.async { exit(0) }
    }

    static func repoRoot() -> URL {
        if let r = ProcessInfo.processInfo.environment["DIALHACK_ROOT"] { return URL(fileURLWithPath: r) }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() } // Sources/DialSniffer/Guided.swift → dialhack/
        return u
    }

    private func writeReport() -> Bool {
        guard let reportPath else { return false }
        let script = Self.repoRoot().appendingPathComponent("analytics/sniffer_report.py").path
        let pythons = ["/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                       "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let py = pythons.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              FileManager.default.fileExists(atPath: script) else { return false }
        FileManager.default.createFile(atPath: reportPath, contents: nil)
        guard let out = FileHandle(forWritingAtPath: reportPath) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [script, log.url.path, "--session", log.sessionId]
        p.standardOutput = out
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        try? out.close()
        log.write(kind: "control", method: "guided.report", raw: p.terminationStatus == 0 ? "written" : "failed",
                  fields: ["path": reportPath, "status": Int(p.terminationStatus)])
        return p.terminationStatus == 0
    }
}

// MARK: - console UI (headless / dry runs)

final class ConsoleGuidedUI: GuidedUI {
    private let lock = NSLock()
    private var skip = false
    var skipRequested: Bool { lock.lock(); defer { lock.unlock() }; return skip }
    func clearSkip() { lock.lock(); skip = false; lock.unlock() }
    func setSkippable(_ on: Bool) {}

    func update(section: String, prompt: String, detail: String, progress: Double, state: TrialState) {
        print("GUIDED [\(section)] \(prompt.replacingOccurrences(of: "\n", with: " ")) | \(detail.replacingOccurrences(of: "\n", with: " "))")
        fflush(stdout)
    }

    func note(_ line: String) { print("GUIDED   · \(line)"); fflush(stdout) }

    func choose(_ prompt: String, detail: String, options: [String], timeout: Double?, fallback: String) -> String {
        print("GUIDED ? \(prompt) \(options) → \(fallback)")
        fflush(stdout)
        return fallback
    }
}
