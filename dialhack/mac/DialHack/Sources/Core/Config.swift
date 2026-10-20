import Foundation

enum ModeID: String, Codable, CaseIterable, Equatable {
    case passthrough, scroll, scrub, comboLock, macro

    var title: String {
        switch self {
        case .passthrough: return "Passthrough"
        case .scroll: return "Scroll"
        case .scrub: return "Scrub"
        case .comboLock: return "Combo Lock"
        case .macro: return "Macro"
        }
    }

    var hint: String {
        switch self {
        case .passthrough: return "Turn: volume · Press: play/pause"
        case .scroll: return "Turn: scroll · Press: page down · Double: top"
        case .scrub: return "Turn: ←/→ seek · Press: play/pause · Double: +10 s"
        case .comboLock: return "Turn: digit · Press: enter · Double: reset"
        case .macro: return "Turn: choose · Press: run · Double: cancel"
        }
    }

    /// Whether this mode takes over the volume (infinite encoder) and the media keys.
    var hijacks: Bool { self != .passthrough }
}

/// Which dial gesture opens the mode picker.
enum PickerGesture: String, Codable, CaseIterable, Equatable {
    /// Double press, then turn within `pickerWindowMs`. A plain double press fires that much later.
    case doublePressTurn
    /// Press-and-hold mapped to "skip back" in Nothing X (arrives as previousTrack). Double press is instant.
    /// Retest: 0/10, not usable on this firmware (findings.md).
    case hold
    /// Experimental: one click one way then one click back within `wiggleWindowMs`. Double press is instant.
    case wiggle

    var title: String {
        switch self {
        case .doublePressTurn: return "Double press, then turn"
        case .hold: return "Press and hold"
        case .wiggle: return "Wiggle (right-left or left-right)"
        }
    }
}

/// User configuration, persisted as JSON in ~/Library/Application Support/DialHack/config.json.
struct DialConfig: Codable, Equatable {
    var startMode: ModeID = .passthrough
    var pickerModes: [ModeID] = ModeID.allCases
    var pickerGesture: PickerGesture = .doublePressTurn
    var scrollLinesPerStep: Int = 5
    var comboCode: [Int] = [1, 2, 3, 4]
    var comboSuccessMacro: Macro? = nil
    var macros: [Macro] = DialConfig.defaultMacros
    /// Double press → turn window for the mode picker.
    var pickerWindowMs: Double = 500
    /// Wiggle: max time between the two opposite clicks. Phase 0 never saw clicks closer than ~300 ms.
    var wiggleWindowMs: Double = 400
    /// Mode picker closes itself after this long without input.
    var pickerTimeoutMs: Double = 6000
    /// Lazy restore: snap volume back to 50% after this much dial idle time…
    var restoreIdleMs: Double = 1500
    /// …or immediately when within this many 1/16 steps of either end.
    var restoreEdgeSteps: Int = 2
    /// Claim Now Playing with silent audio while a hijacking mode is active.
    var keepNowPlaying: Bool = true
    var feedbackSounds: Bool = true
    /// Drop back to Passthrough after this many minutes without dial input in a hijacking mode
    /// (0 = never). Guards against stray inputs: in-ear detection sends PAUSE, and the dial gets
    /// nudged in a pocket (findings.md, "Stray inputs").
    var autoPassthroughMinutes: Double = 5
    /// Only hijack volume when the default output's name contains this (case-insensitive).
    /// Empty = any Bluetooth output. Keeps keyboard volume keys normal on speakers.
    var deviceMatch: String = "CMF"

    static let defaultMacros: [Macro] = [
        Macro(name: "Mission Control", kind: .shortcut(.key(KeyStroke.upArrow, .control))),
        Macro(name: "Next desktop", kind: .shortcut(.key(KeyStroke.rightArrow, .control))),
        Macro(name: "Previous desktop", kind: .shortcut(.key(KeyStroke.leftArrow, .control))),
        Macro(name: "Spotlight", kind: .shortcut(.key(KeyStroke.space, .command))),
        Macro(name: "Screenshot (area)", kind: .shortcut(.key(KeyStroke.key4, .command, .shift))),
        Macro(name: "Lock screen", kind: .shortcut(.key(KeyStroke.keyQ, .control, .command))),
    ]

    // Tolerant decoding: missing keys fall back to defaults so old config files keep working.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DialConfig()
        startMode = (try? c.decode(ModeID.self, forKey: .startMode)) ?? d.startMode
        pickerModes = (try? c.decode([ModeID].self, forKey: .pickerModes)) ?? d.pickerModes
        pickerGesture = (try? c.decode(PickerGesture.self, forKey: .pickerGesture)) ?? d.pickerGesture
        scrollLinesPerStep = (try? c.decode(Int.self, forKey: .scrollLinesPerStep)) ?? d.scrollLinesPerStep
        comboCode = (try? c.decode([Int].self, forKey: .comboCode)) ?? d.comboCode
        comboSuccessMacro = try? c.decode(Macro.self, forKey: .comboSuccessMacro)
        macros = (try? c.decode([Macro].self, forKey: .macros)) ?? d.macros
        pickerWindowMs = (try? c.decode(Double.self, forKey: .pickerWindowMs)) ?? d.pickerWindowMs
        wiggleWindowMs = (try? c.decode(Double.self, forKey: .wiggleWindowMs)) ?? d.wiggleWindowMs
        pickerTimeoutMs = (try? c.decode(Double.self, forKey: .pickerTimeoutMs)) ?? d.pickerTimeoutMs
        restoreIdleMs = (try? c.decode(Double.self, forKey: .restoreIdleMs)) ?? d.restoreIdleMs
        restoreEdgeSteps = (try? c.decode(Int.self, forKey: .restoreEdgeSteps)) ?? d.restoreEdgeSteps
        keepNowPlaying = (try? c.decode(Bool.self, forKey: .keepNowPlaying)) ?? d.keepNowPlaying
        feedbackSounds = (try? c.decode(Bool.self, forKey: .feedbackSounds)) ?? d.feedbackSounds
        autoPassthroughMinutes = (try? c.decode(Double.self, forKey: .autoPassthroughMinutes)) ?? d.autoPassthroughMinutes
        deviceMatch = (try? c.decode(String.self, forKey: .deviceMatch)) ?? d.deviceMatch
        if pickerModes.isEmpty { pickerModes = d.pickerModes }
        if comboCode.isEmpty { comboCode = d.comboCode }
    }

    static func load(from url: URL) -> DialConfig {
        guard let data = try? Data(contentsOf: url), let cfg = try? JSONDecoder().decode(DialConfig.self, from: data) else {
            return DialConfig()
        }
        return cfg
    }

    func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
