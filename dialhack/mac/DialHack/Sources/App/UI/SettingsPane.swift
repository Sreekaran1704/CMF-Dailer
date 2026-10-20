import SwiftUI

struct SettingsPane: View {
    @ObservedObject var c: Coordinator
    var compact = false

    /// Digits only; ignores edits that would leave the code empty.
    private var comboText: Binding<String> {
        Binding(get: { c.config.comboCode.map(String.init).joined() },
                set: { text in
                    let digits = text.compactMap { $0.wholeNumberValue }
                    if !digits.isEmpty { c.config.comboCode = digits }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if !compact {
                ChapterHeader(number: 5, name: "Settings", title: "Settings",
                              subtitle: "Tune your hero's powers. Everything stays on this Mac.", color: CK.orange)
            }

            group("Modes", color: CK.blue) {
                row("Mode right now", note: "switches immediately, same as the dial and the menu bar") {
                    menu(Binding(get: { c.mode }, set: { c.selectMode($0) }), ModeID.allCases.map { ($0, $0.title) })
                }
                row("Mode when DialHack opens", note: "only used at launch; doesn't change the current mode") {
                    menu($c.config.startMode, ModeID.allCases.map { ($0, $0.title) })
                }
                row("Scroll distance", note: "lines per click") {
                    ComicStepper(value: c.config.scrollLinesPerStep, range: 1...30) { c.config.scrollLinesPerStep = $0 }
                }
                row("Focus Timer default") {
                    ComicStepper(value: c.config.focusMinutes, range: 5...120, step: 5, unit: " min") { c.config.focusMinutes = $0 }
                }
                row("Combo code", note: "digits") {
                    ComicField(text: comboText, width: 120)
                }
                row("Macros", note: "edit the list in config.json") {
                    Button("Open config ↗") { NSWorkspace.shared.activateFileViewerSelecting([Coordinator.configURL]) }.buttonStyle(.comicLink)
                }
            }

            group("The dial", color: CK.red) {
                row("Open the mode picker with") { menu($c.config.pickerGesture, PickerGesture.allCases.map { ($0, $0.title) }) }
                if c.config.pickerGesture == .doublePressTurn {
                    row("Double press → turn window", note: "longer is easier to hit; a plain double press waits this long to act") {
                        ComicStepper(value: Int(c.config.pickerWindowMs), range: 300...2500, step: 50, unit: " ms") { c.config.pickerWindowMs = Double($0) }
                    }
                }
                if c.config.pickerGesture == .wiggle {
                    row("Wiggle window", note: "experimental; the buds send at most ~3 clicks a second") {
                        ComicStepper(value: Int(c.config.wiggleWindowMs), range: 200...1000, step: 50, unit: " ms") { c.config.wiggleWindowMs = Double($0) }
                    }
                }
                row("Put the volume back", note: c.config.restoreTiming == .everyClick ? "keeps volume steady; very fast spins may lose clicks" : nil) {
                    menu($c.config.restoreTiming, RestoreTiming.allCases.map { ($0, $0.title) })
                }
                if c.config.restoreTiming == .whenIdle {
                    row("…after no clicks for") {
                        ComicStepper(value: Int(c.config.restoreIdleMs), range: 300...5000, step: 100, unit: " ms") { c.config.restoreIdleMs = Double($0) }
                    }
                    row("…or within this many clicks of either end") {
                        ComicStepper(value: c.config.restoreEdgeSteps, range: 1...4) { c.config.restoreEdgeSteps = $0 }
                    }
                }
                row("Only for outputs named") {
                    ComicField(text: $c.config.deviceMatch)
                }
                row("Back to Passthrough after idle", note: "0 = never; never interrupts a focus session") {
                    ComicStepper(value: Int(c.config.autoPassthroughMinutes), range: 0...60, unit: " min") { c.config.autoPassthroughMinutes = Double($0) }
                }
                toggleRow("Hold Now Playing with silent audio", $c.config.keepNowPlaying, note: "how dial presses reach DialHack in dial modes")
                toggleRow("Feedback sounds", $c.config.feedbackSounds)
            }

            group("The app", color: CK.green) {
                toggleRow("Show in Dock", $c.config.showInDock, note: "off: menu bar only; open this window from its menu")
                toggleRow("Launch at login", Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }),
                          note: c.loginItemStatus.isEmpty || c.launchAtLogin ? nil : c.loginItemStatus)
                row("Your data", note: "~/Library/Application Support/DialHack · nothing leaves this Mac") {
                    Button("Show folder ↗") { NSWorkspace.shared.activateFileViewerSelecting([EventLogger.directory]) }.buttonStyle(.comicLink)
                }
            }

            group("Permissions", color: CK.purple) {
                row("Accessibility", note: "needed to scroll, seek and run shortcuts") {
                    if c.accessibilityTrusted {
                        Sticker(text: "Allowed!", color: CK.green)
                    } else {
                        Button("Allow!") { c.requestAccessibility() }.buttonStyle(.comic)
                    }
                }
            }
        }
    }

    // MARK: building blocks

    private func group<Content: View>(_ title: String, color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SubHead(text: title, color: color)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 18).padding(.vertical, 4)
                .comicPanel()
                .padding(.trailing, 6)
        }
    }

    private func row<Control: View>(_ label: String, note: String? = nil, @ViewBuilder _ control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(CK.bodyBold(15))
                    if let note { Text(note).font(CK.bodyItalic(12.5)).foregroundStyle(CK.muted) }
                }
                Spacer()
                control()
            }
            .padding(.vertical, 11)
            Hairline(color: CK.ink.opacity(0.25), height: 1.5)
        }
    }

    private func toggleRow(_ label: String, _ isOn: Binding<Bool>, note: String? = nil) -> some View {
        row(label, note: note) {
            Toggle(isOn: isOn) { Caps(isOn.wrappedValue ? "On" : "Off", size: 10.5, color: CK.muted) }
                .toggleStyle(ComicToggleStyle())
        }
    }

    private func menu<T: Hashable>(_ sel: Binding<T>, _ options: [(T, String)]) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Button(o.1) { sel.wrappedValue = o.0 }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == sel.wrappedValue }?.1 ?? "–").font(CK.title(16)).textCase(.uppercase).tracking(0.7)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(CK.ink)
            .padding(.horizontal, 11).padding(.top, 6).padding(.bottom, 4)
            .background(CK.panel)
            .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2.5))
            .background(Rectangle().fill(CK.shadow).offset(x: 3, y: 3))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
