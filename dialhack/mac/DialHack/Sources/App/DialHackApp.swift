import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Coordinator.shared.start()
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

    var body: some Scene {
        MenuBarExtra {
            MenuContent(c: c)
        } label: {
            Image(systemName: c.mode.hijacks ? "dial.high.fill" : "dial.low")
        }
        Settings {
            SettingsView(c: c)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var c: Coordinator

    var body: some View {
        Text("DialHack · \(c.mode.title)")
        Text(c.mode.hint)
        Divider()
        ForEach(ModeID.allCases, id: \.self) { m in
            Toggle(m.title, isOn: Binding(get: { c.mode == m }, set: { _ in c.selectMode(m) }))
        }
        Text("Switch modes: \(c.config.pickerGesture.title.lowercased())")
        Divider()
        Text(c.device.matches ? "Output: \(c.device.name) ✓" : "Output: \(c.device.name) (dial inactive)")
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

struct SettingsView: View {
    @ObservedObject var c: Coordinator

    /// Digits only; ignores edits that would leave the code empty. (No @State: the CLT build lacks
    /// the SwiftUI macro plugin.)
    private var comboText: Binding<String> {
        Binding(get: { c.config.comboCode.map(String.init).joined() },
                set: { text in
                    let digits = text.compactMap { $0.wholeNumberValue }
                    if !digits.isEmpty { c.config.comboCode = digits }
                })
    }

    var body: some View {
        Form {
            Section("Modes") {
                Picker("Start in", selection: $c.config.startMode) {
                    ForEach(ModeID.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Stepper("Scroll: \(c.config.scrollLinesPerStep) lines per click", value: $c.config.scrollLinesPerStep, in: 1...30)
                HStack {
                    Text("Combo code")
                    TextField("digits", text: comboText)
                        .frame(width: 120)
                }
                Button("Edit macros (config.json)…") {
                    NSWorkspace.shared.activateFileViewerSelecting([Coordinator.configURL])
                }
            }
            Section("Dial") {
                Picker("Open mode picker with", selection: $c.config.pickerGesture) {
                    ForEach(PickerGesture.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if c.config.pickerGesture == .doublePressTurn {
                    Stepper("Double press → turn window: \(Int(c.config.pickerWindowMs)) ms", value: $c.config.pickerWindowMs, in: 300...2500, step: 50)
                }
                if c.config.pickerGesture == .wiggle {
                    Stepper("Wiggle window: \(Int(c.config.wiggleWindowMs)) ms", value: $c.config.wiggleWindowMs, in: 200...1000, step: 50)
                    Text("Experimental. The buds send at most ~3 clicks per second, so windows under ~300 ms can't trigger.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Restore volume after \(Int(c.config.restoreIdleMs)) ms idle", value: $c.config.restoreIdleMs, in: 500...5000, step: 250)
                Stepper("…or within \(c.config.restoreEdgeSteps) clicks of either end", value: $c.config.restoreEdgeSteps, in: 1...4)
                TextField("Only for outputs named", text: $c.config.deviceMatch)
                Stepper(c.config.autoPassthroughMinutes > 0
                        ? "Back to Passthrough after \(Int(c.config.autoPassthroughMinutes)) min idle"
                        : "Never return to Passthrough automatically",
                        value: $c.config.autoPassthroughMinutes, in: 0...60, step: 1)
                Toggle("Hold Now Playing with silent audio", isOn: $c.config.keepNowPlaying)
                Toggle("Feedback sounds", isOn: $c.config.feedbackSounds)
            }
            Section("Permissions") {
                LabeledContent("Accessibility", value: c.accessibilityTrusted ? "Allowed" : "Not allowed")
                if !c.accessibilityTrusted {
                    Button("Allow Accessibility…") { c.requestAccessibility() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { NSApp.activate() }
    }
}
