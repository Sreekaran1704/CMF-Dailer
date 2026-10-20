import Foundation

/// Turns raw output-volume readings into dial steps (findings.md):
///  - CoreAudio fires the main volume property ~5× per change: duplicates are dropped by value.
///  - Our own restores are tagged: a reading at the restore target inside the self window is ignored.
///  - macOS quantizes Bluetooth volume to 1/16 steps; a reading that jumps several steps is
///    reported as that many steps (never seen in Phase 0, handled anyway).
final class VolumeTracker {
    enum Result: Equatable {
        case ignored(String)
        case steps(direction: Int, count: Int, from: Float, to: Float)
    }

    static let stepsPerRange: Float = 16

    var selfWindowMs: Double = 450
    private(set) var last: Float?
    private var selfTarget: Float?
    private var selfUntil: Double = 0

    func reset(to v: Float?) {
        last = v
        selfTarget = nil
        selfUntil = 0
    }

    /// Call right before setting the volume ourselves.
    func expectSelf(target: Float, at t: Double) {
        selfTarget = target
        selfUntil = t + selfWindowMs
    }

    func feed(_ v: Float, at t: Double) -> Result {
        guard let prev = last else {
            last = v
            return .ignored("initial")
        }
        if abs(v - prev) < 0.001 { return .ignored("duplicate") }
        if let target = selfTarget, t < selfUntil, abs(v - target) < 0.01 {
            last = v
            return .ignored("self")
        }
        last = v
        selfTarget = nil // a real change supersedes any restore still in flight
        let delta = v - prev
        let count = max(1, Int((abs(delta) * Self.stepsPerRange).rounded()))
        return .steps(direction: delta > 0 ? 1 : -1, count: count, from: prev, to: v)
    }

    /// Volume level in 1/16 steps (0...16).
    static func level(_ v: Float) -> Int { Int((v * stepsPerRange).rounded()) }

    /// Lazy restore's edge rule: restore now if within `edgeSteps` of either end.
    static func nearEdge(_ v: Float, edgeSteps: Int) -> Bool {
        let l = level(v)
        return l <= edgeSteps || l >= Int(stepsPerRange) - edgeSteps
    }
}
