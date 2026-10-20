import AppKit
import SwiftUI

/// On-screen overlay: mode banners, the mode picker, macro list and combo lock display.
/// A borderless, non-activating, click-through panel so it never steals focus from the app
/// receiving the dial's actions.

/// The HUD as a comic panel popping onto the screen: ink border, hard shadow, yellow caption, Bangers.
struct HUDView: View {
    let content: HUDContent

    var body: some View {
        Group {
            switch content {
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
                            Spacer(minLength: 24)
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
            case let .armed(since, windowMs):
                VStack(spacing: 8) {
                    Narration(text: "Clik-clik!").rotationEffect(.degrees(-2))
                    SFX(text: "Turn to switch mode", size: 28, fill: CK.yellow, tilt: -2)
                    TimelineView(.periodic(from: since, by: 0.04)) { ctx in
                        let left = max(0, 1 - ctx.date.timeIntervalSince(since) * 1000 / windowMs)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(CK.panelDeep)
                            Rectangle().fill(CK.red).frame(width: 220 * left)
                        }
                        .frame(width: 220, height: 8)
                        .overlay(Rectangle().strokeBorder(CK.line, lineWidth: 2))
                    }
                    Text("…or wait, and it counts as a double press").font(CK.bodyBold(12.5)).foregroundStyle(CK.inkSoft)
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
        .fixedSize(horizontal: true, vertical: false)   // its own ideal width, however wide the proposal
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
    /// The panel is measured and centred for each new content before it's shown, so the first frame is already
    /// right (e.g. when the mode picker replaces the smaller Focus Timer pop-up). The hosting view sits in a plain
    /// container and never sizes the window itself: letting SwiftUI and our own setFrame both drive the window
    /// size is what made it jump, and can even loop.
    private lazy var host: NSHostingView<HUDView> = {
        let h = NSHostingView(rootView: HUDView(content: .hide))
        h.sizingOptions = []
        h.autoresizingMask = [.width, .height]
        return h
    }()
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
        let container = NSView()
        host.frame = container.bounds
        container.addSubview(host)
        p.contentView = container
        return p
    }()
    private var hideWork: DispatchWorkItem?
    var debugPanel: NSPanel { panel }

    /// Banners and messages fade on their own; lists and the combo stay until replaced or hidden
    /// (with a long safety timeout).
    func show(_ content: HUDContent) {
        hideWork?.cancel()
        guard content != .hide else { panel.orderOut(nil); return }

        let view = HUDView(content: content)
        let fit = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 640, height: 1000))
        let size = CGSize(width: ceil(fit.width), height: ceil(fit.height))
        host.rootView = view
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.22,
                              width: size.width, height: size.height), display: true)
        host.frame = panel.contentView?.bounds ?? .zero
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
