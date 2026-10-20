import AudioToolbox
import CoreAudio
import Foundation

/// Watches every volume-ish property on the default output device and follows default-device changes.
/// Optional "restore" mode snaps volume back to a baseline after each change so we can measure
/// the infinite-encoder trick: echo callbacks, blips, and whether fast spins merge.
final class CoreAudioSniffer {
    /// 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume (AudioToolbox).
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    struct Prop {
        let key: String
        let selector: AudioObjectPropertySelector
        let element: UInt32
        let isMute: Bool
    }

    static let candidates: [Prop] = [
        Prop(key: "virtual_main", selector: virtualMainVolume, element: kAudioObjectPropertyElementMain, isMute: false),
        Prop(key: "scalar_main", selector: kAudioDevicePropertyVolumeScalar, element: 0, isMute: false),
        Prop(key: "scalar_ch1", selector: kAudioDevicePropertyVolumeScalar, element: 1, isMute: false),
        Prop(key: "scalar_ch2", selector: kAudioDevicePropertyVolumeScalar, element: 2, isMute: false),
        Prop(key: "mute_main", selector: kAudioDevicePropertyMute, element: 0, isMute: true),
    ]

    var restoreEnabled = false
    /// DialHack-style lazy restore: snap back after `lazyIdleMs` of dial idle, or at once within 2
    /// steps (of 16) of either end. Independent of the per-click `restoreEnabled`.
    var lazyRestore = false
    var lazyIdleMs: Double = 1500
    private var lazyWork: DispatchWorkItem?
    var baseline: Float32 = 0.5
    /// How long after our own restore a callback is attributed to us (if it lands at baseline).
    var selfWindowMs: Double = 300

    private let q = DispatchQueue(label: "dialsniffer.coreaudio")
    private let log = SnifferLog.shared
    private var device: AudioObjectID = 0
    private var attached: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var last: [String: Float32] = [:]
    private var selfUntilMs: Double = 0
    private var primaryKey: String?

    func start() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, q) { [weak self] _, _ in
            self?.attachDefault(reason: "default_output_changed")
        }
        q.async { self.attachDefault(reason: "start") }
    }

    func setRestore(_ on: Bool) { q.async { self.restoreEnabled = on } }
    func setLazyRestore(_ on: Bool) {
        q.async {
            self.lazyRestore = on
            if !on { self.lazyWork?.cancel() }
        }
    }
    func setBaseline(_ v: Float32) { q.async { self.baseline = v } }

    /// Sets the primary volume to `v` as a tagged self-change (its echo is logged as kind "self").
    /// Leaves the restore baseline at `restoreBaseline` afterwards.
    func setVolumeTagged(_ v: Float32, restoreBaseline: Float32 = 0.5) {
        q.async {
            self.baseline = v
            self.restore()
            // Keep the echo classified as self, then switch the baseline back once it has landed.
            self.q.asyncAfter(deadline: .now() + .milliseconds(Int(self.selfWindowMs))) { self.baseline = restoreBaseline }
        }
    }

    func status() -> [String: Any] {
        q.sync {
            ["device_id": device, "device": Self.name(of: device) ?? "?", "transport": Self.transport(of: device),
             "restore": restoreEnabled, "baseline": baseline, "primary": primaryKey ?? "none",
             "values": last.mapValues { Double($0) }]
        }
    }

    /// Synchronous read for the startup check. Runs after the queued initial attach.
    func snapshot() -> (name: String, transport: String, volume: Float32?, primary: String) {
        q.sync { (Self.name(of: device) ?? "?", Self.transport(of: device), primaryKey.flatMap { last[$0] }, primaryKey ?? "none") }
    }

    // MARK: - attach

    private func attachDefault(reason: String) {
        for (addr, block) in attached {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device, &a, q, block)
        }
        attached.removeAll()
        last.removeAll()
        primaryKey = nil

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        device = dev

        var available: [String] = []
        for prop in Self.candidates {
            var a = AudioObjectPropertyAddress(mSelector: prop.selector, mScope: kAudioDevicePropertyScopeOutput, mElement: prop.element)
            guard AudioObjectHasProperty(dev, &a) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed(prop) }
            let st = AudioObjectAddPropertyListenerBlock(dev, &a, q, block)
            if st == noErr {
                attached.append((a, block))
                available.append(prop.key)
                if let v = read(prop) { last[prop.key] = v }
            }
        }
        primaryKey = ["virtual_main", "scalar_main", "scalar_ch1"].first { available.contains($0) }

        log.write(kind: "control", method: "coreaudio.device", raw: reason, fields: [
            "device_id": dev,
            "device": Self.name(of: dev) ?? "?",
            "transport": Self.transport(of: dev),
            "listening": available,
            "settable_primary": primaryKey.map { isSettable(key: $0) } ?? false,
            "values": last.mapValues { Double($0) },
        ])
    }

    // MARK: - change handling

    private func changed(_ prop: Prop) {
        guard let v = read(prop) else { return }
        let prev = last[prop.key]
        last[prop.key] = v
        let now = SnifferLog.monoMs()
        let delta = prev.map { v - $0 } ?? 0
        let raw: String
        if prop.isMute {
            raw = v > 0.5 ? "MUTE_ON" : "MUTE_OFF"
        } else {
            raw = delta > 0 ? "VOLUME_UP" : (delta < 0 ? "VOLUME_DOWN" : "VOLUME_SAME")
        }
        let inWindow = now < selfUntilMs
        let atBaseline = abs(v - baseline) < 0.002
        let isSelf = inWindow && atBaseline

        var fields: [String: Any] = [
            "value": Double(v), "prev": prev.map { Double($0) } as Any, "delta": Double(delta),
            "self_window": inWindow, "at_baseline": atBaseline,
        ]
        if !prop.isMute {
            // Raw before/after in AVRCP absolute-volume units (0...127) so step size per click is readable.
            let after = Double(v) * 127
            fields["after_127"] = Self.round2(after)
            fields["before_127"] = prev.map { Self.round2(Double($0) * 127) } as Any
            fields["step_127"] = Self.round2(Double(delta) * 127)
            fields["at_limit"] = after <= 0.5 || after >= 126.5
        }
        log.write(kind: isSelf ? "self" : "capture", method: "coreaudio.\(prop.key)", raw: raw, fields: fields)

        // Restore only off the primary property, and never in response to our own echo.
        if restoreEnabled, !isSelf, !prop.isMute, prop.key == primaryKey, !atBaseline {
            restore()
        }
        if lazyRestore, !restoreEnabled, !isSelf, !prop.isMute, prop.key == primaryKey, delta != 0 {
            lazyWork?.cancel()
            let level = Int((v * 16).rounded())
            if level <= 2 || level >= 14 {
                restore()
            } else {
                let work = DispatchWorkItem { [weak self] in self?.restore() }
                lazyWork = work
                q.asyncAfter(deadline: .now() + .milliseconds(Int(lazyIdleMs)), execute: work)
            }
        }
    }

    private func restore() {
        guard let key = primaryKey, let prop = Self.candidates.first(where: { $0.key == key }) else { return }
        selfUntilMs = SnifferLog.monoMs() + selfWindowMs
        var a = AudioObjectPropertyAddress(mSelector: prop.selector, mScope: kAudioDevicePropertyScopeOutput, mElement: prop.element)
        let before = read(prop)
        var value = baseline
        let st = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        let after = read(prop)
        log.write(kind: "control", method: "restore.set", raw: key, fields: [
            "baseline": Double(baseline), "status": Int(st),
            "before_127": before.map { Self.round2(Double($0) * 127) } as Any,
            "after_127": after.map { Self.round2(Double($0) * 127) } as Any,
        ])
    }

    // MARK: - property helpers

    private func read(_ prop: Prop) -> Float32? {
        var a = AudioObjectPropertyAddress(mSelector: prop.selector, mScope: kAudioDevicePropertyScopeOutput, mElement: prop.element)
        if prop.isMute {
            var m: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m) == noErr ? Float32(m) : nil
        }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func isSettable(key: String) -> Bool {
        guard let prop = Self.candidates.first(where: { $0.key == key }) else { return false }
        var a = AudioObjectPropertyAddress(mSelector: prop.selector, mScope: kAudioDevicePropertyScopeOutput, mElement: prop.element)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    static func name(of dev: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    static func transport(of dev: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &t) == noErr else { return "?" }
        let bytes = [24, 16, 8, 0].map { UInt8((t >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(t)
    }
}
