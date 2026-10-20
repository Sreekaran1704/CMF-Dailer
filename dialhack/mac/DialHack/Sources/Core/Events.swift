import Foundation

// Shared vocabulary between the capture layer, the normalizer, the mode engine and the executor.
// Nothing in Core imports AppKit/CoreAudio, so it can be tested headlessly.

/// What a capture source actually received.
enum RawInput: Equatable {
    case volumeUp
    case volumeDown
    /// MPRemoteCommandCenter play / pause / togglePlayPause (the buds alternate play and pause).
    case playPause(String)
    case nextTrack
    case previousTrack

    var name: String {
        switch self {
        case .volumeUp: return "VOLUME_UP"
        case .volumeDown: return "VOLUME_DOWN"
        case .playPause(let n): return n.uppercased() // PLAY / PAUSE / TOGGLEPLAYPAUSE
        case .nextTrack: return "NEXT"
        case .previousTrack: return "PREV"
        }
    }

    var source: String {
        switch self {
        case .volumeUp, .volumeDown: return "volume"
        default: return "media_key"
        }
    }
}

/// Normalized dial input (the five inputs of the brief).
enum DialEvent: String, Equatable {
    case rotateCW = "ROTATE_CW"
    case rotateCCW = "ROTATE_CCW"
    case press1 = "PRESS_1"
    case press2 = "PRESS_2"
    case press3 = "PRESS_3"

    var step: Int {
        switch self {
        case .rotateCW: return 1
        case .rotateCCW: return -1
        default: return 0
        }
    }
}

/// Output of the gesture recognizer.
enum Gesture: Equatable {
    case event(DialEvent)
    /// Double press followed by a turn within the picker window. `initialStep` is that first turn (±1).
    case openModePicker(initialStep: Int)
}

struct Recognized: Equatable {
    let gesture: Gesture
    let raw: RawInput
    /// Monotonic ms when the raw input was captured (for latency logging).
    let captureMs: Double
    /// The turn that completed "double press, then turn". It opens the picker instead of acting, but
    /// it's still a dial click, so the logger records it too (telemetry counts every click).
    var consumedTurn: RawInput? = nil
}

enum Modifier: String, Codable, CaseIterable {
    case command, shift, control, option
}

struct KeyStroke: Codable, Equatable {
    /// macOS virtual key code (kVK_*).
    let keyCode: UInt16
    var modifiers: [Modifier] = []

    static func key(_ code: UInt16, _ mods: Modifier...) -> KeyStroke { KeyStroke(keyCode: code, modifiers: mods) }

    // kVK_* codes used by the starter modes.
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let space: UInt16 = 49
    static let pageDown: UInt16 = 121
    static let keyL: UInt16 = 37
    static let keyQ: UInt16 = 12
    static let key4: UInt16 = 21
}

enum MacroKind: Codable, Equatable {
    case shortcut(KeyStroke)
    case openApp(String)
    case shell(String)
}

struct Macro: Codable, Equatable {
    let name: String
    let kind: MacroKind
}

enum HUDContent: Equatable {
    case banner(title: String, subtitle: String)
    case list(title: String, items: [String], selected: Int)
    case combo(entered: Int, length: Int, current: Int)
    case message(String, success: Bool)
    case focus(title: String, seconds: Int, running: Bool, tags: Int)
    /// A double press is being held: turn before `until` to open the mode picker.
    case armed(since: Date, windowMs: Double)
    case hide
}

enum FeedbackSound: String, Equatable {
    case modeChange = "Glass"
    case select = "Tink"
    case success = "Hero"
    case failure = "Basso"
}

/// Everything the executor knows how to do.
enum Action: Equatable {
    /// Positive = scroll down / content moves up.
    case scroll(lines: Int)
    case key(KeyStroke)
    case runMacro(Macro)
    case hud(HUDContent)
    case sound(FeedbackSound)
    case setMode(ModeID)
    /// A self-report label (Focus Timer) for the label log.
    case label(LabelRecord)
}
