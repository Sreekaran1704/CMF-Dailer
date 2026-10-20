import AppKit
import Foundation

// DialSniffer: Phase 0 logger. Runs every macOS capture candidate at once and logs to
// ~/Library/Application Support/DialHack/sniffer.jsonl. Driven by typed commands on stdin.
//
// Runs as a real NSApplication (accessory policy: no Dock icon, no menu bar) so the main run loop
// is live for MPRemoteCommandCenter, CoreAudio listener blocks and the CGEventTap source.

/// Launch arguments. When macOS relaunches the .app itself (e.g. "Quit & Reopen" after a permission
/// grant) it passes none, so fall back to the arguments run-guided.sh saved in the last 15 minutes.
func launchArguments() -> [String] {
    let given = Array(CommandLine.arguments.dropFirst())
    guard given.isEmpty, isatty(STDIN_FILENO) == 0, Bundle.main.bundlePath.hasSuffix(".app") else { return given }
    let saved = SnifferLog.shared.url.deletingLastPathComponent().appendingPathComponent(".guided-args")
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: saved.path),
          let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 900,
          let text = try? String(contentsOf: saved, encoding: .utf8) else {
        // The .app bundle exists for guided mode; never come back as an invisible stdin logger.
        return ["--guided"]
    }
    return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

let argv = launchArguments()
let args = Set(argv)
let log = SnifferLog.shared
let guided = args.contains("--guided")

func argValue(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

let coreAudio = CoreAudioSniffer()
let remote = RemoteCommandSniffer()
let silent = SilentAudio()
let eventTap = EventTapSniffer()

let presetLabels: [String: String] = [
    "0": "idle",
    "1": "rotate_cw",
    "2": "rotate_ccw",
    "3": "fast_cw",
    "4": "press_single",
    "5": "press_double",
    "6": "press_triple",
    "7": "press_long",
    "8": "keyboard_media_keys",
]

let help = """
DialSniffer commands (type and press Return):
  1..8 / 0           set label: 1 rotate_cw  2 rotate_ccw  3 fast_cw  4 press_single
                     5 press_double  6 press_triple  7 press_long  8 keyboard_media_keys  0 idle
  label <name>       set a custom label
  m                  latency marker (Right Shift also works, and is more precise)
  np on|off          own Now Playing (MPNowPlayingInfoCenter)
  state playing|paused
  audio on|off       looping digital silence (on by default)
  restore on|off     snap volume back to baseline after each change
  baseline <0-1>     restore target (default 0.5)
  note <text>        free-form note into the log
  status             print current config
  q                  quit
Log file: \(log.url.path)
"""

func handle(_ line: String) {
    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
    guard let cmd = parts.first else { return }
    let arg = parts.count > 1 ? parts[1] : ""
    switch cmd {
    case _ where presetLabels[cmd] != nil: log.setLabel(presetLabels[cmd]!)
    case "label": log.setLabel(arg.isEmpty ? "unlabeled" : arg)
    case "m": log.write(kind: "marker", method: "marker.stdin", raw: "MARK")
    case "np": remote.setNowPlaying(arg == "on")
    case "state": remote.setNowPlaying(true, state: arg == "paused" ? .paused : .playing)
    case "audio":
        silent.set(arg == "on")
        if remote.nowPlaying { remote.setNowPlaying(true) } // re-assert playbackState = .playing
    case "restore":
        coreAudio.setRestore(arg == "on")
        log.write(kind: "control", method: "restore", raw: arg)
    case "baseline":
        if let v = Float(arg), (0.05...0.95).contains(v) {
            coreAudio.setBaseline(v)
            log.write(kind: "control", method: "baseline", raw: arg)
        } else { print("baseline must be between 0.05 and 0.95") }
    case "note": log.write(kind: "control", method: "note", raw: arg)
    case "status":
        var s = coreAudio.status()
        s["now_playing"] = remote.nowPlaying
        s["silent_audio"] = silent.playing
        s["label"] = log.currentLabel()
        log.write(kind: "control", method: "status", raw: "status", fields: s)
    case "q", "quit", "exit":
        log.write(kind: "control", method: "stop", raw: "quit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    case "help", "?": print(help)
    default: print("unknown command '\(cmd)' (type help)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        log.write(kind: "control", method: "start", raw: "DialSniffer", fields: [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "args": Array(args).sorted(),
            "activation_policy": "accessory",
            "main_run_loop": Thread.isMainThread,
        ])

        coreAudio.start()
        StartupCheck.run(coreAudio)

        // Silence first, then claim Now Playing, so the session is "playing" from the start.
        if !args.contains("--no-audio") { silent.set(true) }
        if args.contains("--no-remote") {
            log.write(kind: "control", method: "remote_command", raw: "disabled_by_flag")
        } else {
            remote.start()
        }
        if guided {
            startGuided()
            return
        }
        if args.contains("--no-tap") {
            log.write(kind: "control", method: "event_tap", raw: "disabled_by_flag")
        } else {
            eventTap.start()
        }
        if args.contains("--restore") {
            coreAudio.setRestore(true)
            log.write(kind: "control", method: "restore", raw: "on")
        }

        print(help)

        Thread.detachNewThread {
            while let line = readLine() {
                DispatchQueue.main.async { handle(line) }
            }
        }
    }
}

var guidedRunner: GuidedRunner?
var windowUI: WindowGuidedUI?

/// Guided mode: the runner owns the event tap (it checks permission first) and drives everything else.
func startGuided() {
    let headless = args.contains("--headless")
    let report = argValue("--report")
    let only = argValue("--only").map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
    if let bad = only?.subtracting(GuidedRunner.sectionIds), !bad.isEmpty {
        print("unknown --only section(s): \(bad.sorted()). Valid: \(GuidedRunner.sectionIds.joined(separator: ", "))")
        exit(2)
    }
    // The media-key tap (and its permission prompt) is only needed for the latency step.
    let needsTap = only == nil || only!.contains("latency")
    let ui: GuidedUI
    if headless {
        ui = ConsoleGuidedUI()
    } else {
        log.echo = false
        let w = WindowGuidedUI()
        w.show()
        windowUI = w
        ui = w
    }
    let runner = GuidedRunner(ui: ui, fast: args.contains("--fast"), useTap: needsTap && !args.contains("--no-tap"),
                              reportPath: report, only: only)
    let inbox = runner.inbox
    log.observer = { inbox.add($0) }
    windowUI?.onClose = { [weak runner] in runner?.aborted = true }
    guidedRunner = runner
    Thread.detachNewThread { runner.run() }
}

signal(SIGINT) { _ in exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
