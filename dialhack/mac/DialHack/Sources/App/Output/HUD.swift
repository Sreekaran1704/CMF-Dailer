import AppKit
import SwiftUI

/// On-screen overlay: mode banners, the mode picker, macro list and combo lock display.
/// A borderless, non-activating, click-through panel so it never steals focus from the app
/// receiving the dial's actions.
final class HUDModel: ObservableObject {
    @Published var content: HUDContent = .hide
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        Group {
            switch model.content {
            case .hide:
                EmptyView()
            case let .banner(title, subtitle):
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 26, weight: .bold))
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            case let .list(title, items, selected):
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        Text(item)
                            .font(.system(size: 17, weight: i == selected ? .bold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(i == selected ? Color.accentColor.opacity(0.35) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            case let .combo(entered, length, current):
                VStack(spacing: 10) {
                    Text("Combo Lock").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(0..<length, id: \.self) { i in
                            Text(i < entered ? "•" : (i == entered ? "\(current)" : "–"))
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .frame(width: 36)
                                .foregroundStyle(i == entered ? Color.accentColor : Color.primary)
                        }
                    }
                }
            case let .message(text, success):
                Label(text, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(success ? Color.green : Color.red)
            }
        }
        .padding(22)
        .frame(minWidth: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
        p.hasShadow = true
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
