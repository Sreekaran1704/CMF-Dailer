import AppKit
import Combine
import ServiceManagement

/// Wires the layers together: capture → normalizer (GestureRecognizer) → ModeEngine → executor/HUD,
/// with every recognized input logged. Everything here runs on the main queue.
/// Where the dial's presses will go right now (they follow macOS's "Now Playing" app).
enum PressRoute: Equatable {
    /// Passthrough: presses are meant for your music app.
    case passthrough
    /// DialHack holds Now Playing.
    case dialHack
    /// Another app is playing audio, so it most likely gets the presses.
    case otherApps([String])
    /// DialHack's silent audio isn't running (it restarts itself within a few seconds).
    case silenceDown

    var ok: Bool { self == .dialHack || self == .passthrough }

    var text: String {
        switch self {
        case .passthrough: return "Presses control your music (Passthrough)"
        case .dialHack: return "Presses come to DialHack"
        case let .otherApps(names): return "Presses go to \(names.joined(separator: ", ")) while it's playing. Pause it to use presses."
        case .silenceDown: return "Reconnecting audio so presses come to DialHack…"
        }
    }
}

struct RecentInput: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let event: String
    let action: String
    let mode: ModeID
}

enum PressTest: Equatable {
    case idle
    case waiting(since: Date)
    case received
    case missed(PressRoute)
}

final class Coordinator: ObservableObject {
    static let shared = Coordinator()

    @Published private(set) var mode: ModeID {
        didSet { if mode != oldValue { writeStatus() } }
    }
    @Published var config: DialConfig {
        didSet {
            guard config != oldValue else { return }
            config.save(to: Self.configURL)
            applyConfig()
        }
    }
    @Published private(set) var device = VolumeCapture.DeviceInfo() {
        didSet { if device != oldValue { writeStatus() } }
    }
    @Published private(set) var accessibilityTrusted = ActionExecutor.accessibilityTrusted {
        didSet { if accessibilityTrusted != oldValue { writeStatus() } }
    }
    @Published private(set) var lastEvent = "No dial input yet"
    @Published private(set) var loginItemStatus = ""
    /// "mm:ss" while a focus session is running or paused (menu bar), nil otherwise.
    @Published private(set) var focusClock: String?
    @Published private(set) var pressRoute: PressRoute = .passthrough
    @Published private(set) var lastPressAt: Date?
    /// Newest first, for the app window's live view.
    @Published private(set) var recent: [RecentInput] = []
    /// The on-screen dial turns 22.5° (1/16) per click.
    @Published private(set) var dialAngle: Double = 0
    @Published private(set) var pressCount = 0
    @Published private(set) var pressTest: PressTest = .idle
    private var pressTestWork: DispatchWorkItem?

    static let configURL = EventLogger.directory.appendingPathComponent("config.json")

    let logger = EventLogger()
    private let engine: ModeEngine
    private let recognizer: GestureRecognizer
    private let volume = VolumeCapture()
    private let media = MediaKeyCapture()
    private let executor = ActionExecutor()
    private let hud = HUD()
    private var tickWork: DispatchWorkItem?
    private var pickerTimeoutWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?
    private var focusExpiryWork: DispatchWorkItem?
    private var focusTicker: Timer?
    private var lastFocusActive = false
    private var axPoll: Timer?
    private var lastAXWarning: Date = .distantPast
    private var started = false

    private init() {
        let cfg = DialConfig.load(from: Self.configURL)
        config = cfg
        engine = ModeEngine(config: cfg)
        recognizer = GestureRecognizer(pickerWindowMs: cfg.pickerWindowMs)
        recognizer.pickerGesture = cfg.pickerGesture
        recognizer.wiggleWindowMs = cfg.wiggleWindowMs
        mode = engine.mode
        if !FileManager.default.fileExists(atPath: Self.configURL.path) { cfg.save(to: Self.configURL) }
    }

    func start() {
        guard !started else { return }
        started = true
        volume.onSteps = { [weak self] raw, count, t in self?.receive(raw, count: count, at: t) }
        volume.onDevice = { [weak self] info in self?.device = info }
        media.onRaw = { [weak self] raw, t in self?.receive(raw, count: 1, at: t) }
        executor.onNeedsAccessibility = { [weak self] in self?.warnAccessibility() }
        executor.soundsEnabled = config.feedbackSounds

        applyDockPolicy()
        volume.start(config: config)
        media.start()
        applyMode(engine.mode)
        refreshLoginItemStatus()
        writeStatus()
        if CommandLine.arguments.contains("--accept-simulated-input") { acceptSimulatedInput() }
        axPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.accessibilityTrusted = ActionExecutor.accessibilityTrusted
            self?.refreshPressRoute()
        }
        refreshPressRoute()
    }

    /// Diagnostics for scripts and Claude: ~/Library/Application Support/DialHack/status.json.
    private func writeStatus() {
        guard started else { return }
        let obj: [String: Any] = [
            "accessibility": accessibilityTrusted,
            "mode": mode.rawValue,
            "focus_active": engine.focus.isActive,
            "silent_audio_playing": media.silence.isPlaying,
            "silent_audio_restarts": media.silence.restarts,
            "press_route": pressRoute.text,
            "device": device.name,
            "dial_active": device.matches,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: EventLogger.directory.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    /// Integration tests only: raw inputs posted as distributed notifications ("dev.dialhack.simulate",
    /// object = PLAY / PAUSE / NEXT / PREV / VOLUME_UP / VOLUME_DOWN). Off unless launched with
    /// --accept-simulated-input, so other processes can't drive DialHack's Accessibility powers.
    private func acceptSimulatedInput() {
        let map: [String: RawInput] = ["PLAY": .playPause("play"), "PAUSE": .playPause("pause"), "NEXT": .nextTrack,
                                       "PREV": .previousTrack, "VOLUME_UP": .volumeUp, "VOLUME_DOWN": .volumeDown]
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.dialhack.simulate"), object: nil,
                                                            queue: .main) { [weak self] n in
            guard let name = n.object as? String, let raw = map[name] else { return }
            self?.receive(raw, count: 1, at: monoMs())
        }
        lastEvent = "accepting simulated input (test mode)"
    }

    /// Puts the user's own volume back before quitting.
    func shutdown() {
        volume.stopSync()
        media.release()
    }

    // MARK: - input path

    private func receive(_ raw: RawInput, count: Int, at t: Double) {
        armIdleReturn()
        if raw.source == "media_key" {
            lastPressAt = Date()
            pressCount += 1
            if case .waiting = pressTest {
                pressTestWork?.cancel()
                pressTest = .received
            }
        } else {
            dialAngle += (raw == .volumeUp ? 22.5 : -22.5) * Double(max(1, count))
        }
        for _ in 0..<max(1, count) {
            for r in recognizer.feed(raw, at: t) { dispatch(r) }
        }
        updateArmedCue()
        scheduleTick()
    }

    /// Logs every recognized dial input, in every mode, under the mode it happened in.
    private func dispatch(_ r: Recognized) {
        let modeBefore = mode
        let out = engine.handle(r.gesture)
        perform(out)
        let event: String
        switch r.gesture {
        case .event(let e): event = e.rawValue
        case .openModePicker: event = "MODE_PICKER"
        }
        let latency = monoMs() - r.captureMs
        logger.log(raw: r.raw, event: event, mode: modeBefore, action: out.name, latencyMs: latency)
        if let turn = r.consumedTurn {
            logger.log(raw: turn, event: turn == .volumeUp ? "ROTATE_CW" : "ROTATE_CCW", mode: modeBefore,
                       action: "picker_turn", latencyMs: latency)
        }
        lastEvent = "\(event) → \(out.name)"
        recent.insert(RecentInput(time: Date(), event: event, action: out.name, mode: modeBefore), at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
    }

    // MARK: - app window

    var focus: FocusTimer { engine.focus }

    /// Focus Timer buttons in the window. They act like the dial but aren't logged as dial events
    /// (they aren't fidgeting); labels they produce are still logged.
    func focusButton(_ e: DialEvent) {
        if mode != .focusTimer { perform(engine.setMode(.focusTimer)) }
        perform(engine.handle(.event(e)))
        armIdleReturn()
    }

    func focusRate(_ label: String) {
        perform(engine.focusRate(label))
    }

    func setFocusMinutes(_ m: Int) {
        guard !engine.focus.isActive else { return }
        config.focusMinutes = m
    }

    /// "Press the dial once" check: did a press reach DialHack within 10 s?
    func startPressTest() {
        pressTestWork?.cancel()
        refreshPressRoute()
        pressTest = .waiting(since: Date())
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .waiting = self.pressTest else { return }
            self.pressTest = .missed(self.pressRoute)
        }
        pressTestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func resetPressTest() {
        pressTestWork?.cancel()
        pressTest = .idle
    }

    private func scheduleTick() {
        tickWork?.cancel()
        guard let deadline = recognizer.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for r in self.recognizer.tick(at: monoMs()) { self.dispatch(r) }
            self.updateArmedCue()
            self.scheduleTick()
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, deadline - monoMs())) + 5), execute: work)
    }

    /// "Turn now to switch modes": shown the moment a double press is held for the picker window, so the window
    /// is visible instead of guessed. Hidden again if the press resolves without showing anything else.
    private var armedCueShown = false

    private func updateArmedCue() {
        if recognizer.nextDeadline != nil {
            if !armedCueShown {
                hud.show(.armed(since: Date(), windowMs: config.pickerWindowMs))
                armedCueShown = true
            }
        } else if armedCueShown {
            armedCueShown = false
            hud.show(.hide)
        }
    }

    private func perform(_ out: EngineOutput) {
        for a in out.actions {
            switch a {
            case .hud(let c):
                armedCueShown = false   // replaced by whatever the press or picker shows
                hud.show(c)
            case .setMode(let m): applyMode(m)
            case .label(let r): logger.logLabel(r)
            default: executor.perform(a)
            }
        }
        syncFocus()
        recognizer.immediatePress2 = engine.pickerOpen
        recognizer.suppressWiggle = engine.pickerOpen
        pickerTimeoutWork?.cancel()
        if engine.pickerOpen {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.perform(self.engine.pickerTimedOut())
            }
            pickerTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(config.pickerTimeoutMs)), execute: work)
        }
    }

    func refreshPressRoute() {
        let route: PressRoute
        if !mode.hijacks {
            route = .passthrough
        } else {
            let others = AudioActivity.otherPlayers().map(\.name)
            if !others.isEmpty {
                route = .otherApps(others)
            } else if config.keepNowPlaying && !media.silence.isPlaying {
                route = .silenceDown
            } else {
                route = .dialHack
            }
        }
        if route != pressRoute {
            pressRoute = route
            writeStatus()
        }
    }

    // MARK: - modes and settings

    /// From the menu bar.
    func selectMode(_ m: ModeID) {
        perform(engine.setMode(m))
    }

    /// (Re)starts the auto-return-to-Passthrough timer; any dial input pushes it back.
    private func armIdleReturn() {
        idleWork?.cancel()
        guard mode.hijacks, config.autoPassthroughMinutes > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode.hijacks, !self.engine.pickerOpen, !self.engine.focus.isActive else { return }
            self.perform(self.engine.setMode(.passthrough))
            self.hud.show(.banner(title: "Passthrough", subtitle: "Back to normal after \(Int(self.config.autoPassthroughMinutes)) min idle"))
            self.lastEvent = "auto → passthrough (idle)"
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.autoPassthroughMinutes * 60, execute: work)
    }

    /// Keeps the expiry timer and the menu bar countdown in step with the focus state machine.
    private func syncFocus() {
        objectWillChange.send()
        focusExpiryWork?.cancel()
        let f = engine.focus
        if f.isActive != lastFocusActive {
            lastFocusActive = f.isActive
            writeStatus()
        }
        if let ends = f.endsAt {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let out = self.engine.focusExpired(now: Date())
                self.perform(out)
                self.lastEvent = "focus timer → \(out.name)"
            }
            focusExpiryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ends.timeIntervalSinceNow), execute: work)
        }
        let showClock: Bool
        switch f.phase {
        case .running, .paused: showClock = mode == .focusTimer
        default: showClock = false
        }
        if showClock {
            updateFocusClock()
            if focusTicker == nil {
                focusTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateFocusClock() }
            }
        } else {
            focusTicker?.invalidate()
            focusTicker = nil
            focusClock = nil
        }
    }

    private func updateFocusClock() {
        let s = Int(engine.focus.remaining(at: Date()).rounded())
        let paused: Bool = { if case .paused = engine.focus.phase { return true } else { return false } }()
        focusClock = String(format: "%d:%02d", s / 60, s % 60) + (paused ? " ⏸" : "")
    }

    /// Dial modes hold Now Playing so presses come to DialHack; Passthrough lets go of it entirely.
    private func claimPresses() {
        if mode.hijacks { media.claim(keepNowPlaying: config.keepNowPlaying) } else { media.release() }
    }

    private func applyMode(_ m: ModeID) {
        mode = m
        armIdleReturn()
        DispatchQueue.main.async { [weak self] in self?.refreshPressRoute() }
        volume.setHijack(m.hijacks)
        claimPresses()
        if m.hijacks && !ActionExecutor.accessibilityTrusted && m != .comboLock { warnAccessibility() }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
    }

    private func applyConfig() {
        applyDockPolicy()
        engine.config = config
        recognizer.pickerWindowMs = config.pickerWindowMs
        recognizer.pickerGesture = config.pickerGesture
        recognizer.wiggleWindowMs = config.wiggleWindowMs
        executor.soundsEnabled = config.feedbackSounds
        armIdleReturn()
        volume.apply(config: config)
        claimPresses()
        if engine.mode != mode { applyMode(engine.mode) }
    }

    private func warnAccessibility() {
        accessibilityTrusted = ActionExecutor.accessibilityTrusted
        guard !accessibilityTrusted, Date().timeIntervalSince(lastAXWarning) > 5 else { return }
        lastAXWarning = Date()
        hud.show(.message("Allow Accessibility (DialHack menu)", success: false))
    }

    func requestAccessibility() {
        ActionExecutor.requestAccessibility()
    }

    // MARK: - launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemStatus = "Couldn't change: \(error.localizedDescription)"
            objectWillChange.send()
            return
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginItemStatus = "Launches at login"
        case .requiresApproval: loginItemStatus = "Approve in System Settings → General → Login Items"
        case .notRegistered: loginItemStatus = ""
        case .notFound: loginItemStatus = "Move DialHack.app to /Applications to launch at login"
        @unknown default: loginItemStatus = ""
        }
    }
}
