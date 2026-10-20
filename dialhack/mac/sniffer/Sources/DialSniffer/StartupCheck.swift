import AppKit
import Foundation

/// Prints the pre-flight checks before a test run and logs them as a `startup_check` control event.
enum StartupCheck {
    static let mediaApps: [String: String] = [
        "com.spotify.client": "Spotify", "com.apple.Music": "Music", "com.apple.TV": "TV",
        "com.apple.podcasts": "Podcasts", "org.videolan.vlc": "VLC", "com.colliderli.iina": "IINA",
    ]
    static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc", "com.microsoft.edgemac": "Edge", "com.brave.Browser": "Brave",
    ]
    static let edgeMargin: Float = 10 // in /127 units

    static func run(_ coreAudio: CoreAudioSniffer) {
        let snap = coreAudio.snapshot()
        var out = ["", "==== DialSniffer startup check ===="]
        var warnings: [String] = []

        let bt = snap.transport == "blue"
        out.append("Output device : \(snap.name)  (transport '\(snap.transport)'\(bt ? " = Bluetooth" : ""))")
        if !bt { warnings.append("Default output is not Bluetooth. Select the CMF Buds Pro 2 as the output device.") }

        var units: Float?
        if let v = snap.volume {
            let u = v * 127
            units = u
            out.append(String(format: "Start volume  : %.4f = %.1f/127  (via %@)", v, u, snap.primary))
            if u <= edgeMargin {
                warnings.append(String(format: "Volume is %.1f/127, within %.0f of the minimum. Down-rotations may be clamped. Turn it up to about 64/127 (50%%).", u, edgeMargin))
            } else if u >= 127 - edgeMargin {
                warnings.append(String(format: "Volume is %.1f/127, within %.0f of the maximum. Up-rotations may be clamped. Turn it down to about 64/127 (50%%).", u, edgeMargin))
            }
        } else {
            out.append("Start volume  : unreadable")
            warnings.append("Couldn't read the output volume.")
        }

        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let media = running.compactMap { mediaApps[$0] }.sorted()
        let web = running.compactMap { browsers[$0] }.sorted()
        if !media.isEmpty {
            warnings.append("Media apps running: \(media.joined(separator: ", ")). Quit them so they can't take Now Playing.")
        }
        if !web.isEmpty {
            out.append("Browsers open : \(web.joined(separator: ", ")) (fine, as long as no tab is playing audio/video)")
        }

        for w in warnings { out.append("WARNING: \(w)") }
        out.append("REMINDER: quit other media apps (Spotify, Music, YouTube tabs) and turn OFF Bluetooth on your phone,")
        out.append("          so the buds' multipoint link can't route dial events to another device.")
        out.append("====================================")
        print(out.joined(separator: "\n"))
        fflush(stdout)

        log.write(kind: "control", method: "startup_check", raw: warnings.isEmpty ? "ok" : "warnings", fields: [
            "device": snap.name, "transport": snap.transport,
            "volume": snap.volume.map { Double($0) } as Any, "volume_127": units.map { Double($0) } as Any,
            "media_apps": media, "browsers": web, "warnings": warnings,
        ])
    }
}
