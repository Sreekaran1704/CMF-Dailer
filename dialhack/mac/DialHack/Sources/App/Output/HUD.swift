import AppKit
import SwiftUI

/// On-screen overlay: mode banners, the mode picker, macro list and combo lock display.
/// A borderless, non-activating, click-through panel so it never steals focus from the app
/// receiving the dial's actions.
final class HUDModel: ObservableObject {
    @Published var content: HUDContent = .hide
}

/// The HUD as a comic panel popping onto the screen: ink border, hard shadow, yellow caption, Bangers.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        Group {
            switch model.content {
            case .hide:
                EmptyView()
            case let .banner(title, subtitle):
                VStack(spacing: 8) {
                    Narration(text: "Now on the dial").rotationEffect(.degrees(-2))
                    SFX(text: title, size: 40, fill: CK.yellow, tilt: -2)
                    Text(subtitle).font(CK.bodyBold(14)).foregroundStyle(CK.inkSoft).multilineTextAlignment(.center)
                }
            case let .list(title, items, selected):
                VStack(alignment: .leading, spacing: 6) {
                    Narration(text: title).padding(.bottom, 4)
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        let on = i == selected
                        HStack(spacing: 10) {
                            Text(item.uppercased()).font(CK.title(on ? 22 : 17)).tracking(0.6)
                                .foregroundStyle(on ? CK.onYellow : CK.inkSoft)
                            Spacer()
                            if on { Text("PRESS!").font(CK.title(15)).foregroundStyle(CK.red) }
                        }
                        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
                        .background(on ? CK.yellow : Color.clear)
                        .overlay(Rectangle().strokeBorder(on ? CK.onYellow : Color.clear, lineWidth: 2))
                        .rotationEffect(.degrees(on ? -1 : 0))
                    }
                }
            case let .combo(entered, length, current):
                VStack(spacing: 10) {
                    Narration(text: "Combo lock")
                    HStack(spacing: 10) {
                        ForEach(0..<length, id: \.self) { i in
                            Text(i < entered ? "★" : (i == entered ? "\(current)" : "–"))
                                .font(CK.title(44))
                                .frame(width: 42)
                                .foregroundStyle(i == entered ? CK.purple : CK.ink)
                        }
                    }
                }
            case let .message(text, success):
                VStack(spacing: 6) {
                    SFX(text: success ? "Pow!" : "Bonk!", size: 30, fill: success ? CK.green : CK.red, tilt: -4)
                    Text(text).font(CK.title(22)).tracking(0.5)
                }
            case let .focus(title, seconds, running, tags):
                VStack(spacing: 6) {
                    Narration(text: title)
                    SFX(text: String(format: "%d:%02d", seconds / 60, seconds % 60), size: 52, fill: CK.red, tilt: -2).monospacedDigit()
                    Text(running ? (tags > 0 ? "\(tags) distraction\(tags == 1 ? "" : "s") noted · double-press to note another"
                                             : "Double-press if you get distracted")
                                 : "Press to start")
                        .font(CK.bodyBold(13)).foregroundStyle(CK.inkSoft)
                }
            }
        }
        .foregroundStyle(CK.ink)
        .padding(.horizontal, 26).padding(.vertical, 20)
        .frame(minWidth: 300)
        .background(alignment: .bottomTrailing) {
            Halftone(color: CK.blue.opacity(0.16), spacing: 8, minRadius: 0, maxRadius: 2.6).frame(width: 140, height: 80)
        }
        .comicPanel(border: 3.5, shadow: 7)
        .padding(.trailing, 8).padding(.bottom, 8)   // room for the hard shadow inside the panel window
    }
}

final class HUD {
    private let model = HUDModel()
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false   // the panel draws its own hard comic shadow
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        return p
    }()
    private var hideWork: DispatchWorkItem?

    /// Banners and messages fade on their own; lists and the combo stay until replaced or hidden
    /// (with a long safety timeout).
    func show(_ content: HUDContent) {
        hideWork?.cancel()
        model.content = content
        guard content != .hide else { panel.orderOut(nil); return }

        if let view = panel.contentView {
            let size = view.fittingSize
            let screen = NSScreen.main?.visibleFrame ?? .zero
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.22,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()

        let linger: Double
        switch content {
        case .banner, .message: linger = 1.4
        default: linger = 8
        }
        let work = DispatchWorkItem { [weak self] in self?.show(.hide) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }
}
