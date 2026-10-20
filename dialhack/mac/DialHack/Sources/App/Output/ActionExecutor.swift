import AppKit
import ApplicationServices
import CoreGraphics

/// Action executor: posts CGEvents (needs Accessibility), runs macros, plays feedback sounds.
/// Every synthetic event is tagged with `tag` in eventSourceUserData. DialHack never posts media
/// keys or volume keys, so nothing it posts can reach its own capture layer.
final class ActionExecutor {
    static let tag: Int64 = 0x4448_4B21 // "DHK!"

    var soundsEnabled = true
    var onNeedsAccessibility: (() -> Void)?

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (only call from a user action).
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Returns false if the action needed Accessibility and it isn't granted.
    @discardableResult
    func perform(_ action: Action) -> Bool {
        switch action {
        case .scroll(let lines):
            return post { src in
                // wheel1 > 0 scrolls content down (towards the top); our positive = scroll down.
                CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: Int32(-lines), wheel2: 0, wheel3: 0)
            }
        case .key(let k):
            return press(k)
        case .runMacro(let m):
            switch m.kind {
            case .shortcut(let k): return press(k)
            case .openApp(let path):
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            case .shell(let cmd):
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-c", cmd]
                try? p.run()
            }
            return true
        case .sound(let s):
            if soundsEnabled { NSSound(named: NSSound.Name(s.rawValue))?.play() }
            return true
        case .hud, .setMode, .label:
            return true // handled by the coordinator
        }
    }

    private func press(_ k: KeyStroke) -> Bool {
        let flags = Self.flags(k.modifiers)
        return post { src in
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k.keyCode), keyDown: true)
            e?.flags = flags
            return e
        } && post { src in
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k.keyCode), keyDown: false)
            e?.flags = flags
            return e
        }
    }

    private func post(_ make: (CGEventSource?) -> CGEvent?) -> Bool {
        guard Self.accessibilityTrusted else {
            onNeedsAccessibility?()
            return false
        }
        let src = CGEventSource(stateID: .hidSystemState)
        src?.userData = Self.tag
        guard let e = make(src) else { return false }
        e.setIntegerValueField(.eventSourceUserData, value: Self.tag)
        e.post(tap: .cghidEventTap)
        return true
    }

    static func flags(_ mods: [Modifier]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods {
            switch m {
            case .command: f.insert(.maskCommand)
            case .shift: f.insert(.maskShift)
            case .control: f.insert(.maskControl)
            case .option: f.insert(.maskAlternate)
            }
        }
        return f
    }
}
