import Foundation

/// Event normalizer: RawInput → Gesture.
///
/// Two picker gestures (config `pickerGesture`):
///  - `.doublePressTurn`: a nextTrack (double press) is held for `pickerWindowMs`. A turn inside that
///    window opens the mode picker; otherwise the hold expires and becomes PRESS_2.
///  - `.hold`: previousTrack (press-and-hold mapped to "skip back") opens the picker; double press is instant.
///  - `.wiggle`: a click one way then one click back within `wiggleWindowMs` opens the picker; double press
///    is instant. Turns are never delayed: both clicks are emitted as rotations first (their effects cancel
///    out in every mode), then the picker opens. Our own volume restores never reach this class
///    (VolumeTracker drops them), so lazy restore can't fake a reversal.
/// Time is injected so this is deterministic in tests.
final class GestureRecognizer {
    var pickerGesture: PickerGesture = .doublePressTurn {
        didSet {
            if pickerGesture != .doublePressTurn { pending = nil }
            lastTurn = nil
        }
    }
    var wiggleWindowMs: Double = 400
    /// While the picker is open, turns move its selection, so wiggles aren't detected.
    var suppressWiggle = false {
        didSet { if suppressWiggle { lastTurn = nil } }
    }
    var pickerWindowMs: Double
    /// When true (e.g. while the picker is already open), PRESS_2 is emitted immediately.
    var immediatePress2 = false

    private var pending: (raw: RawInput, at: Double)?
    private var lastTurn: (direction: Int, at: Double)?

    init(pickerWindowMs: Double = 1000) {
        self.pickerWindowMs = pickerWindowMs
    }

    /// When the coordinator should call `tick` next, if anything is pending.
    var nextDeadline: Double? { pending.map { $0.at + pickerWindowMs } }

    func feed(_ raw: RawInput, at t: Double) -> [Recognized] {
        var out = flushExpired(at: t)

        switch raw {
        case .volumeUp, .volumeDown:
            let step = raw == .volumeUp ? 1 : -1
            if let p = pending {
                pending = nil
                out.append(Recognized(gesture: .openModePicker(initialStep: step), raw: p.raw, captureMs: p.at))
            } else {
                out.append(Recognized(gesture: .event(step > 0 ? .rotateCW : .rotateCCW), raw: raw, captureMs: t))
                if pickerGesture == .wiggle && !suppressWiggle {
                    if let last = lastTurn, last.direction != step, t - last.at <= wiggleWindowMs {
                        lastTurn = nil // one trigger per wiggle; the next turn starts fresh
                        out.append(Recognized(gesture: .openModePicker(initialStep: 0), raw: raw, captureMs: t))
                    } else {
                        lastTurn = (step, t)
                    }
                }
            }
        case .nextTrack:
            out += flushPending() // a second double press ends the first one's window
            if immediatePress2 || pickerGesture != .doublePressTurn {
                out.append(Recognized(gesture: .event(.press2), raw: raw, captureMs: t))
            } else {
                pending = (raw, t)
            }
        case .playPause:
            out += flushPending()
            out.append(Recognized(gesture: .event(.press1), raw: raw, captureMs: t))
        case .previousTrack:
            out += flushPending()
            let g: Gesture = pickerGesture == .hold ? .openModePicker(initialStep: 0) : .event(.press3)
            out.append(Recognized(gesture: g, raw: raw, captureMs: t))
        }
        return out
    }

    func tick(at t: Double) -> [Recognized] { flushExpired(at: t) }

    func reset() {
        pending = nil
        lastTurn = nil
    }

    private func flushExpired(at t: Double) -> [Recognized] {
        guard let p = pending, t - p.at > pickerWindowMs else { return [] }
        return flushPending()
    }

    private func flushPending() -> [Recognized] {
        guard let p = pending else { return [] }
        pending = nil
        return [Recognized(gesture: .event(.press2), raw: p.raw, captureMs: p.at)]
    }
}
