import AppKit
import CoreGraphics
import Foundation

/// Media keys path B: a listen-only CGEventTap for NX_SYSDEFINED (type 14) events.
/// Also watches Right Shift (flagsChanged) as the latency marker key, and nothing else from the keyboard.
final class EventTapSniffer {
    static let nxSysDefined: UInt32 = 14
    static let auxControlButtons: Int16 = 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    static let rightShiftKeyCode: Int64 = 60

    static let nxKeyNames: [Int: String] = [
        0: "SOUND_UP", 1: "SOUND_DOWN", 2: "BRIGHTNESS_UP", 3: "BRIGHTNESS_DOWN", 7: "MUTE",
        16: "PLAY", 17: "NEXT", 18: "PREVIOUS", 19: "FAST", 20: "REWIND",
        21: "ILLUMINATION_UP", 22: "ILLUMINATION_DOWN",
    ]

    fileprivate var tap: CFMachPort?
    fileprivate var rightShiftDown = false
    let log = SnifferLog.shared

    @discardableResult
    func start() -> Bool {
        let listenOK = CGPreflightListenEventAccess()
        log.write(kind: "control", method: "event_tap.permissions", raw: listenOK ? "granted" : "missing",
                  fields: ["input_monitoring": listenOK, "accessibility": AXIsProcessTrusted()])
        if !listenOK { CGRequestListenEventAccess() }

        let mask: CGEventMask = (1 << CGEventMask(Self.nxSysDefined)) | (1 << CGEventMask(CGEventType.flagsChanged.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.write(kind: "control", method: "event_tap", raw: "create_failed",
                      fields: ["hint": "Grant Input Monitoring to the app running this binary (Terminal/iTerm/Claude), then restart it"])
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.write(kind: "control", method: "event_tap", raw: "started")
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        let cgTs = event.timestamp
        let machNow = mach_absolute_time()

        if type.rawValue == Self.nxSysDefined {
            guard let ns = NSEvent(cgEvent: event) else { return }
            let subtype = ns.subtype.rawValue
            // Subtype 7 is mouse-button bookkeeping (every click): not a media key, and not ours to log.
            if subtype == 7 { return }
            let data1 = ns.data1
            var fields: [String: Any] = ["subtype": Int(subtype), "data1": data1, "data2": ns.data2,
                                         "cg_ts": cgTs, "mach_now": machNow]
            var raw = "SYSDEFINED_SUBTYPE_\(subtype)"
            if subtype == Self.auxControlButtons {
                let keyCode = (data1 & 0xFFFF_0000) >> 16
                let keyFlags = data1 & 0x0000_FFFF
                let keyState = (keyFlags & 0xFF00) >> 8
                fields["nx_key"] = keyCode
                fields["state"] = keyState == 0x0A ? "down" : (keyState == 0x0B ? "up" : String(keyState))
                fields["repeat"] = (keyFlags & 0x1) != 0
                raw = Self.nxKeyNames[keyCode] ?? "NX_KEY_\(keyCode)"
            }
            log.write(kind: "capture", method: "event_tap.sysdefined", raw: raw, fields: fields)
        } else if type == .flagsChanged {
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.rightShiftKeyCode else { return }
            let down = event.flags.contains(.maskShift) && !rightShiftDown
            rightShiftDown = event.flags.contains(.maskShift)
            if down {
                log.write(kind: "marker", method: "marker.right_shift", raw: "MARK", fields: ["cg_ts": cgTs, "mach_now": machNow])
            }
        }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let sniffer = Unmanaged<EventTapSniffer>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = sniffer.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        sniffer.log.write(kind: "control", method: "event_tap", raw: "re_enabled", fields: ["reason": Int(type.rawValue)])
        return Unmanaged.passUnretained(event)
    }
    sniffer.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
