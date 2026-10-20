import AppKit
import SwiftUI

/// Floating always-on-top window for guided mode. All updates arrive from the runner thread
/// and are hopped onto the main thread here.
final class GuidedModel: ObservableObject {
    @Published var section = ""
    @Published var prompt = "Starting…"
    @Published var detail = ""
    @Published var progress = 0.0
    @Published var state: TrialState = .info
    @Published var buttons: [String] = []
    @Published var skippable = false
    @Published var notes: [String] = []
    var onButton: ((String) -> Void)?
}

struct GuidedView: View {
    @ObservedObject var m: GuidedModel

    private var tint: Color {
        switch m.state {
        case .waiting: return .accentColor
        case .got: return .green
        case .miss: return .orange
        case .done: return .green
        case .info: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(m.section).font(.headline).foregroundStyle(.secondary)
                Spacer()
                if m.state == .waiting { ProgressView().controlSize(.small) }
            }
            ProgressView(value: m.progress)
            Text(m.prompt)
                .font(.system(size: 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !m.detail.isEmpty {
                Text(m.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ForEach(m.buttons, id: \.self) { b in
                    Button(b) { m.onButton?(b) }
                        .controlSize(.large)
                        .keyboardShortcut(b == m.buttons.first ? .defaultAction : nil)
                }
                Spacer()
                if m.skippable {
                    Button("Skip this gesture") { m.onButton?("__skip") }.controlSize(.regular)
                }
            }
            if !m.notes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(m.notes.suffix(4).enumerated()), id: \.offset) { _, n in
                        Text(n).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 600, height: 420, alignment: .topLeading)
        .background(tint.opacity(m.state == .info ? 0.04 : 0.12))
        .animation(.easeOut(duration: 0.15), value: m.state)
    }
}

final class WindowGuidedUI: NSObject, GuidedUI, NSWindowDelegate {
    let model = GuidedModel()
    private var window: NSWindow!
    private let lock = NSLock()
    private var skip = false
    private var pendingChoice: String?
    private let choiceSignal = DispatchSemaphore(value: 0)
    var onClose: (() -> Void)?

    var skipRequested: Bool { lock.lock(); defer { lock.unlock() }; return skip }
    func clearSkip() { lock.lock(); skip = false; lock.unlock() }

    /// Call on the main thread.
    func show() {
        let host = NSHostingView(rootView: GuidedView(m: model))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "DialSniffer · guided test"
        window.contentView = host
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        model.onButton = { [weak self] b in
            guard let self else { return }
            if b == "__skip" {
                self.lock.lock(); self.skip = true; self.lock.unlock()
                return
            }
            self.lock.lock()
            let waiting = self.pendingChoice == nil && !self.model.buttons.isEmpty
            if waiting { self.pendingChoice = b }
            self.lock.unlock()
            if waiting {
                self.model.buttons = []
                self.choiceSignal.signal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        choiceSignal.signal() // unblock a pending choose()
    }

    func update(section: String, prompt: String, detail: String, progress: Double, state: TrialState) {
        DispatchQueue.main.async {
            self.model.section = section
            self.model.prompt = prompt
            self.model.detail = detail
            self.model.progress = progress
            self.model.state = state
        }
    }

    func note(_ line: String) {
        DispatchQueue.main.async { self.model.notes.append(line) }
    }

    func setSkippable(_ on: Bool) {
        DispatchQueue.main.async { self.model.skippable = on }
    }

    func choose(_ prompt: String, detail: String, options: [String], timeout: Double?, fallback: String) -> String {
        lock.lock(); pendingChoice = nil; lock.unlock()
        DispatchQueue.main.sync {
            model.prompt = prompt
            model.detail = detail
            model.state = .info
            model.buttons = options
        }
        let result: DispatchTimeoutResult
        if let t = timeout {
            result = choiceSignal.wait(timeout: .now() + t)
        } else {
            choiceSignal.wait()
            result = .success
        }
        DispatchQueue.main.sync { model.buttons = [] }
        lock.lock(); defer { lock.unlock() }
        if result == .timedOut { return fallback }
        return pendingChoice ?? fallback
    }
}
