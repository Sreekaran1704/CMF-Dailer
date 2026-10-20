import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Snapshot/click-test instances are inert: no capture, no Now Playing claim, no status writes,
        // so they never fight the real DialHack for the dial.
        if !SnapshotRunner.requested { Coordinator.shared.start() }
        SnapshotRunner.runIfRequested()
        // `pkill` / logout: quit through NSApp so the user's volume is restored on the way out.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        Coordinator.shared.shutdown()
    }
}

@main
struct DialHackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var c = Coordinator.shared

    init() {
        CK.registerFonts()
    }

    var body: some Scene {
        Window("DialHack", id: "main") {
            MainWindow(c: c)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuContent(c: c)
        } label: {
            // The label depends on the exact mode, so the status item (and its menu) re-render on every switch,
            // whether it came from the window, the dial or the menu itself.
            if let clock = c.focusClock {
                Label(clock, systemImage: "timer").labelStyle(.titleAndIcon)
            } else if c.mode.hijacks {
                Label(c.mode.title, systemImage: c.mode.symbol).labelStyle(.titleAndIcon)
            } else {
                Image(systemName: c.mode.symbol)
            }
        }
        Settings {
            ScrollView { SettingsPane(c: c, compact: true).padding(24) }
                .frame(width: 560, height: 680)
                .background(PaperPage())
                .foregroundStyle(CK.ink)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var c: Coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open DialHack…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Divider()
        Text("DialHack · \(c.mode.title)")
        Text(c.mode.hint)
        if let clock = c.focusClock { Text("Focus: \(clock) left") }
        Divider()
        Picker("Mode", selection: Binding(get: { c.mode }, set: { c.selectMode($0) })) {
            ForEach(ModeID.allCases, id: \.self) { m in
                Label(m.title, systemImage: m.symbol).tag(m)
            }
        }
        .pickerStyle(.inline)
        Text("Switch modes: \(c.config.pickerGesture.title.lowercased())")
        Divider()
        Text(c.device.matches ? "Output: \(c.device.name) ✓" : "Output: \(c.device.name) (dial inactive)")
        if c.mode.hijacks && !c.pressRoute.ok { Text("⚠ \(c.pressRoute.text)") }
        if !c.accessibilityTrusted {
            Button("Allow Accessibility… (needed for actions)") { c.requestAccessibility() }
        }
        Toggle("Launch at login", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
        if !c.loginItemStatus.isEmpty && !c.launchAtLogin { Text(c.loginItemStatus) }
        Toggle("Feedback sounds", isOn: $c.config.feedbackSounds)
        SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        Button("Show event log") { NSWorkspace.shared.activateFileViewerSelecting([c.logger.url]) }
        Divider()
        Text("Last: \(c.lastEvent)")
        Button("Quit DialHack") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}


extension ModeID {
    /// Menu bar symbol for each mode.
    var symbol: String {
        switch self {
        case .passthrough: return "dial.low"
        case .scroll: return "arrow.up.arrow.down"
        case .scrub: return "film"
        case .comboLock: return "lock"
        case .macro: return "command"
        case .focusTimer: return "timer"
        }
    }
}
