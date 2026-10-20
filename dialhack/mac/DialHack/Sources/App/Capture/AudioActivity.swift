import AppKit
import CoreAudio

/// Which apps are playing audio right now (CoreAudio process objects, macOS 14.4+).
///
/// macOS sends dial presses to the "Now Playing" app. DialHack can't read that directly, but an app
/// that is actively playing audio almost always is it. So: if another app is playing, warn that the
/// dial's presses will go there.
enum AudioActivity {
    struct Player: Equatable {
        let pid: pid_t
        let name: String
    }

    /// Apps (other than DialHack itself and system daemons) currently running audio output.
    static func otherPlayers() -> [Player] {
        guard #available(macOS 14.4, *) else { return [] }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        var out: [Player] = []
        for id in ids {
            guard uint32(id, kAudioProcessPropertyIsRunningOutput) != 0 else { continue }
            var pid: pid_t = 0
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid)
            guard pid != me else { continue }
            // Helpers (browser renderers) report their own pid; name them after their app.
            guard let app = NSRunningApplication(processIdentifier: pid) ?? owningApp(of: pid) else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            if seen.insert(name).inserted { out.append(Player(pid: pid, name: name)) }
        }
        return out
    }

    private static func uint32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var s = UInt32(4)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? v : 0
    }

    /// Helper processes (e.g. "Arc Helper (Renderer)") aren't apps; walk up to the .app bundle.
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        guard let r = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<r.lowerBound]) + ".app"
        let outer = bundle.components(separatedBy: ".app/").first.map { $0 + ".app" } ?? bundle
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == outer }
    }
}
