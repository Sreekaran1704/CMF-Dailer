import AppKit
import Combine
import ServiceManagement

/// Wires the layers together: capture → normalizer (GestureRecognizer) → ModeEngine → executor/HUD,
/// with every recognized input logged. Everything here runs on the main queue.
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

        volume.start(config: config)
        media.start()
        applyMode(engine.mode)
        refreshLoginItemStatus()
        writeStatus()
        axPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.accessibilityTrusted = ActionExecutor.accessibilityTrusted
        }
    }

    /// Diagnostics for scripts and Claude: ~/Library/Application Support/DialHack/status.json.
    private func writeStatus() {
        let obj: [String: Any] = [
            "accessibility": accessibilityTrusted,
            "mode": mode.rawValue,
            "device": device.name,
            "dial_active": device.matches,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: EventLogger.directory.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    /// Puts the user's own volume back before quitting.
    func shutdown() {
        volume.stopSync()
        media.setClaim(false, keepNowPlaying: false)
    }

    // MARK: - input path

    private func receive(_ raw: RawInput, count: Int, at t: Double) {
        armIdleReturn()
        for _ in 0..<max(1, count) {
            for r in recognizer.feed(raw, at: t) { dispatch(r) }
        }
        scheduleTick()
    }

    private func dispatch(_ r: Recognized) {
        let out = engine.handle(r.gesture)
        perform(out)
        let event: String
        switch r.gesture {
        case .event(let e): event = e.rawValue
        case .openModePicker: event = "MODE_PICKER"
        }
        logger.log(raw: r.raw, event: event, mode: mode, action: out.name, latencyMs: monoMs() - r.captureMs)
        lastEvent = "\(event) → \(out.name)"
    }

    private func scheduleTick() {
        tickWork?.cancel()
        guard let deadline = recognizer.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for r in self.recognizer.tick(at: monoMs()) { self.dispatch(r) }
            self.scheduleTick()
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, deadline - monoMs())) + 5), execute: work)
    }

    private func perform(_ out: EngineOutput) {
        for a in out.actions {
            switch a {
            case .hud(let c): hud.show(c)
            case .setMode(let m): applyMode(m)
            default: executor.perform(a)
            }
        }
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
            guard let self, self.mode.hijacks, !self.engine.pickerOpen else { return }
            self.perform(self.engine.setMode(.passthrough))
            self.hud.show(.banner(title: "Passthrough", subtitle: "Back to normal after \(Int(self.config.autoPassthroughMinutes)) min idle"))
            self.lastEvent = "auto → passthrough (idle)"
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.autoPassthroughMinutes * 60, execute: work)
    }

    private func applyMode(_ m: ModeID) {
        mode = m
        armIdleReturn()
        volume.setHijack(m.hijacks)
        media.setClaim(m.hijacks, keepNowPlaying: config.keepNowPlaying)
        if m.hijacks && !ActionExecutor.accessibilityTrusted && m != .comboLock { warnAccessibility() }
    }

    private func applyConfig() {
        engine.config = config
        recognizer.pickerWindowMs = config.pickerWindowMs
        recognizer.pickerGesture = config.pickerGesture
        recognizer.wiggleWindowMs = config.wiggleWindowMs
        executor.soundsEnabled = config.feedbackSounds
        armIdleReturn()
        volume.apply(config: config)
        media.setClaim(mode.hijacks, keepNowPlaying: config.keepNowPlaying)
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
