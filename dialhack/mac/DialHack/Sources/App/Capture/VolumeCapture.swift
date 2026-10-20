import AudioToolbox
import CoreAudio
import Foundation

func monoMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000 }

/// Capture layer, rotation: listens to the default output's VirtualMainVolume and implements the
/// infinite-encoder hijack with *lazy* restore (findings.md): the volume is left where each click
/// puts it and snapped back to 50% only after the dial goes idle, or immediately near either end.
final class VolumeCapture {
    /// 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663
    static let baseline: Float = 0.5

    struct DeviceInfo: Equatable {
        var name = "none"
        var bluetooth = false
        var matches = false
    }

    /// Called on the main queue: (raw, step count, capture time).
    var onSteps: ((RawInput, Int, Double) -> Void)?
    var onDevice: ((DeviceInfo) -> Void)?

    private let q = DispatchQueue(label: "dialhack.volume")
    private let tracker = VolumeTracker()
    private var device: AudioObjectID = 0
    private var listener: AudioObjectPropertyListenerBlock?
    private var info = DeviceInfo()
    private var hijack = false
    private var savedUserVolume: Float?
    private var idleRestore: DispatchWorkItem?
    private var restoreIdleMs: Double = 1500
    private var edgeSteps = 2
    private var deviceMatch = "CMF"

    func start(config: DialConfig) {
        apply(config: config)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, q) { [weak self] _, _ in
            self?.attachDefault()
        }
        q.async { self.attachDefault() }
    }

    func apply(config: DialConfig) {
        q.async {
            self.restoreIdleMs = config.restoreIdleMs
            self.edgeSteps = config.restoreEdgeSteps
            self.deviceMatch = config.deviceMatch
            self.refreshMatch()
        }
    }

    /// Enter/leave the infinite-encoder mode. Entering parks the volume at 50%; leaving puts the
    /// user's own volume back.
    func setHijack(_ on: Bool) {
        q.async {
            guard on != self.hijack else { return }
            self.hijack = on
            self.idleRestore?.cancel()
            guard self.info.matches, let current = self.read() else { return }
            if on {
                self.savedUserVolume = current
                self.restore(to: Self.baseline)
            } else if let v = self.savedUserVolume {
                self.restore(to: v)
                self.savedUserVolume = nil
            }
        }
    }

    /// Synchronously leaves hijack mode (restoring the user's volume) before the app quits.
    func stopSync() {
        q.sync {
            idleRestore?.cancel()
            if hijack, info.matches, let v = savedUserVolume { restore(to: v) }
            hijack = false
        }
    }

    // MARK: - device

    private func attachDefault() {
        if let l = listener {
            var a = address()
            AudioObjectRemovePropertyListenerBlock(device, &a, q, l)
            listener = nil
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        device = dev

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        var a = address()
        if AudioObjectHasProperty(dev, &a), AudioObjectAddPropertyListenerBlock(dev, &a, q, block) == noErr {
            listener = block
        }
        info.name = Self.name(of: dev) ?? "unknown"
        info.bluetooth = Self.isBluetooth(dev)
        tracker.reset(to: read())
        refreshMatch()
        // A hijack in progress moves to the new device only if it matches.
        if hijack && info.matches { restore(to: Self.baseline) }
    }

    private func refreshMatch() {
        let m = deviceMatch.trimmingCharacters(in: .whitespaces)
        info.matches = info.bluetooth && (m.isEmpty || info.name.localizedCaseInsensitiveContains(m))
        let snapshot = info
        DispatchQueue.main.async { self.onDevice?(snapshot) }
    }

    // MARK: - changes

    private func changed() {
        guard let v = read() else { return }
        let t = monoMs()
        guard case let .steps(direction, count, _, _) = tracker.feed(v, at: t) else { return }
        guard info.matches else { return }
        let raw: RawInput = direction > 0 ? .volumeUp : .volumeDown
        DispatchQueue.main.async { self.onSteps?(raw, count, t) }

        guard hijack else { return }
        idleRestore?.cancel()
        if VolumeTracker.nearEdge(v, edgeSteps: edgeSteps) {
            restore(to: Self.baseline)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.restore(to: Self.baseline) }
            idleRestore = work
            q.asyncAfter(deadline: .now() + .milliseconds(Int(restoreIdleMs)), execute: work)
        }
    }

    /// Sets the volume as a tagged self-change (the tracker ignores its echo). Runs on `q`.
    private func restore(to target: Float) {
        guard let current = read(), abs(current - target) > 0.001 else { return }
        tracker.expectSelf(target: target, at: monoMs())
        var a = address()
        var value = target
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    // MARK: - helpers

    private func address() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: Self.virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func read() -> Float? {
        var a = address()
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func name(of dev: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    private static func isBluetooth(_ dev: AudioObjectID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }
}
