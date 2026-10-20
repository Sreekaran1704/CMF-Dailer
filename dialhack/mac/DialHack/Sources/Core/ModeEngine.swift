import Foundation

struct EngineOutput: Equatable {
    var actions: [Action] = []
    /// Short name for the event log's `action` field.
    var name: String = "none"
}

/// Mode engine: Gesture → actions, given the current mode. Pure state machine, no side effects.
final class ModeEngine {
    private(set) var mode: ModeID
    private(set) var pickerOpen = false
    var config: DialConfig {
        didSet {
            if !config.pickerModes.contains(mode) && mode != .passthrough { mode = config.startMode }
            if !focus.isActive { focus.minutes = config.focusMinutes }
        }
    }

    private var pickerIndex = 0
    private var comboEntered: [Int] = []
    private var comboDigit = 0
    private var macroIndex = 0
    private(set) var focus: FocusTimer

    init(config: DialConfig) {
        self.config = config
        self.mode = config.startMode
        self.focus = FocusTimer(minutes: config.focusMinutes)
    }

    // MARK: - entry points

    func handle(_ gesture: Gesture, now: Date = Date()) -> EngineOutput {
        switch gesture {
        case .openModePicker(let step):
            // A second hold while the picker is open cancels it.
            if pickerOpen && step == 0 {
                pickerOpen = false
                return EngineOutput(actions: [.hud(.hide)], name: "picker_cancel")
            }
            return openPicker(step: step)
        case .event(let e):
            if pickerOpen { return pickerInput(e) }
            switch mode {
            case .passthrough: return passthrough(e)
            case .scroll: return scroll(e)
            case .scrub: return scrub(e)
            case .comboLock: return combo(e)
            case .macro: return macro(e)
            case .focusTimer: return focus.input(e, now: now)
            }
        }
    }

    func pickerTimedOut() -> EngineOutput {
        guard pickerOpen else { return EngineOutput() }
        pickerOpen = false
        return EngineOutput(actions: [.hud(.hide)], name: "picker_timeout")
    }

    /// From the app window: rate a finished focus session directly.
    func focusRate(_ label: String, now: Date = Date()) -> EngineOutput {
        guard mode == .focusTimer else { return EngineOutput() }
        return focus.rate(label, now: now)
    }

    /// The coordinator calls this when the focus timer reaches zero.
    func focusExpired(now: Date = Date()) -> EngineOutput {
        guard mode == .focusTimer else { return EngineOutput() }
        return focus.expire(now: now)
    }

    func setMode(_ m: ModeID) -> EngineOutput {
        if mode == .focusTimer && m != .focusTimer { focus.abandon() }
        mode = m
        pickerOpen = false
        comboEntered = []
        comboDigit = 0
        macroIndex = 0
        return EngineOutput(actions: [.setMode(m), .sound(.modeChange), .hud(.banner(title: m.title, subtitle: m.hint))],
                            name: "mode:\(m.rawValue)")
    }

    // MARK: - picker

    private var pickerItems: [ModeID] { config.pickerModes.isEmpty ? ModeID.allCases : config.pickerModes }

    private func wrap(_ i: Int, _ n: Int) -> Int { n == 0 ? 0 : ((i % n) + n) % n }

    private func pickerHUD() -> Action {
        .hud(.list(title: "Choose mode · turn, then press", items: pickerItems.map(\.title), selected: pickerIndex))
    }

    /// Opens on the current mode. The turn that opened the picker (double press, then turn) only opens it;
    /// it doesn't also move the highlight, so the first turn never jumps (e.g. Focus Timer → wrapped to the top).
    private func openPicker(step _: Int) -> EngineOutput {
        let items = pickerItems
        pickerIndex = items.firstIndex(of: mode) ?? 0
        pickerOpen = true
        return EngineOutput(actions: [pickerHUD(), .sound(.select)], name: "open_mode_picker")
    }

    private func pickerInput(_ e: DialEvent) -> EngineOutput {
        switch e {
        case .rotateCW, .rotateCCW:
            pickerIndex = wrap(pickerIndex + e.step, pickerItems.count)
            return EngineOutput(actions: [pickerHUD()], name: "picker_move")
        case .press1:
            return setMode(pickerItems[pickerIndex])
        case .press2, .press3:
            pickerOpen = false
            return EngineOutput(actions: [.hud(.hide)], name: "picker_cancel")
        }
    }

    // MARK: - modes

    private func passthrough(_ e: DialEvent) -> EngineOutput {
        // The OS already applied the volume change / the media key went to the Now Playing app.
        // (DialHack lets go of Now Playing in Passthrough, so presses normally don't reach it at all.)
        switch e {
        case .rotateCW: return EngineOutput(name: "volume_up")
        case .rotateCCW: return EngineOutput(name: "volume_down")
        case .press1: return EngineOutput(name: "play_pause")
        case .press2: return EngineOutput(name: "next_track")
        case .press3: return EngineOutput(name: "previous_track")
        }
    }

    private func scroll(_ e: DialEvent) -> EngineOutput {
        switch e {
        case .rotateCW: return EngineOutput(actions: [.scroll(lines: config.scrollLinesPerStep)], name: "scroll_down")
        case .rotateCCW: return EngineOutput(actions: [.scroll(lines: -config.scrollLinesPerStep)], name: "scroll_up")
        case .press1: return EngineOutput(actions: [.key(.key(KeyStroke.pageDown))], name: "page_down")
        case .press2: return EngineOutput(actions: [.key(.key(KeyStroke.upArrow, .command))], name: "jump_to_top")
        case .press3: return EngineOutput()
        }
    }

    private func scrub(_ e: DialEvent) -> EngineOutput {
        switch e {
        case .rotateCW: return EngineOutput(actions: [.key(.key(KeyStroke.rightArrow))], name: "seek_forward")
        case .rotateCCW: return EngineOutput(actions: [.key(.key(KeyStroke.leftArrow))], name: "seek_back")
        case .press1: return EngineOutput(actions: [.key(.key(KeyStroke.space))], name: "play_pause_key")
        case .press2: return EngineOutput(actions: [.key(.key(KeyStroke.keyL))], name: "jump_10s")
        case .press3: return EngineOutput()
        }
    }

    private func comboHUD() -> Action {
        .hud(.combo(entered: comboEntered.count, length: config.comboCode.count, current: comboDigit))
    }

    private func combo(_ e: DialEvent) -> EngineOutput {
        switch e {
        case .rotateCW, .rotateCCW:
            comboDigit = wrap(comboDigit + e.step, 10)
            return EngineOutput(actions: [comboHUD()], name: "digit_\(comboDigit)")
        case .press1:
            comboEntered.append(comboDigit)
            guard comboEntered.count >= config.comboCode.count else {
                return EngineOutput(actions: [comboHUD(), .sound(.select)], name: "enter_digit")
            }
            let ok = comboEntered == config.comboCode
            comboEntered = []
            comboDigit = 0
            var actions: [Action] = [.hud(.message(ok ? "Unlocked" : "Wrong code", success: ok)), .sound(ok ? .success : .failure)]
            if ok, let m = config.comboSuccessMacro { actions.append(.runMacro(m)) }
            return EngineOutput(actions: actions, name: ok ? "combo_unlock" : "combo_wrong")
        case .press2:
            comboEntered = []
            comboDigit = 0
            return EngineOutput(actions: [comboHUD()], name: "combo_reset")
        case .press3:
            return EngineOutput()
        }
    }

    private func macroHUD() -> Action {
        .hud(.list(title: "Macro · turn to choose, press to run", items: config.macros.map(\.name), selected: macroIndex))
    }

    private func macro(_ e: DialEvent) -> EngineOutput {
        let macros = config.macros
        guard !macros.isEmpty else { return EngineOutput(actions: [.hud(.message("No macros configured", success: false))], name: "macro_none") }
        macroIndex = min(macroIndex, macros.count - 1)
        switch e {
        case .rotateCW, .rotateCCW:
            macroIndex = wrap(macroIndex + e.step, macros.count)
            return EngineOutput(actions: [macroHUD()], name: "macro_select_\(macroIndex)")
        case .press1:
            let m = macros[macroIndex]
            return EngineOutput(actions: [.hud(.message("Ran \(m.name)", success: true)), .runMacro(m)], name: "run_macro:\(m.name)")
        case .press2:
            return EngineOutput(actions: [.hud(.hide)], name: "macro_cancel")
        case .press3:
            return EngineOutput()
        }
    }
}
