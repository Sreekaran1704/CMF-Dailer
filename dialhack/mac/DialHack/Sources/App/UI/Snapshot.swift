import AppKit
import SwiftUI

/// Visual check without Screen Recording permission: DialHack captures its *own* window.
///   DialHack --snapshot <out dir> [--data-dir <dir with events.jsonl, labels.jsonl, dashboard_labels.csv>]
/// Writes <section>-light.png / <section>-dark.png (plus -2, -3… further down) for every section, then quits.
enum SnapshotRunner {
    static func scrollView(in v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = scrollView(in: sub) { return s } }
        return nil
    }

    static var requested: Bool { CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--click-test") }

    /// Clicks real window points with synthetic mouse events (no Accessibility needed: they're sent to our own window)
    /// and prints what changed. Points are in window coordinates from the top-left.
    static func clickTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = NSApp.windows.first(where: { $0.title == "DialHack" || $0.identifier?.rawValue.contains("main") == true }),
                  let view = window.contentView else { print("click-test: no window"); NSApp.terminate(nil); return }
            window.setContentSize(NSSize(width: 1180, height: 820))
            AppUI.shared.section = .dial
            let c = Coordinator.shared
            func click(_ x: CGFloat, _ yTop: CGFloat, then: @escaping () -> Void) {
                let p = NSPoint(x: x, y: view.bounds.height - yTop)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(e)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: then)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("click-test: start mode=\(c.mode.rawValue) section=\(AppUI.shared.section?.rawValue ?? "-")")
                if let scroll = scrollView(in: view), let doc = scroll.documentView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? 760 : doc.frame.height - scroll.contentView.bounds.height - 760))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                // The "Scroll" mode card (middle of the first row of "Pick a power").
                click(590, 425) {
                    print("click-test: after Scroll card mode=\(c.mode.rawValue)")
                    click(990, 425) {
                        print("click-test: after Scrub card mode=\(c.mode.rawValue)")
                        // The "Focus" chapter tab.
                        click(460, 224) {
                            print("click-test: after Focus tab section=\(AppUI.shared.section?.rawValue ?? "-")")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    static func runIfRequested() {
        if CommandLine.arguments.contains("--click-test") { clickTest(); return }
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let d = args.firstIndex(of: "--data-dir"), d + 1 < args.count {
            InsightsModel.shared.dir = URL(fileURLWithPath: args[d + 1])
        }
        let steps = AppUI.Section.allCases.flatMap { s in ["light", "dark"].map { (s, $0) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { capture(steps[...], into: out) }
    }

    private static func capture(_ steps: ArraySlice<(AppUI.Section, String)>, into out: URL) {
        guard let (section, look) = steps.first else {
            NSApp.terminate(nil)
            return
        }
        guard let window = NSApp.windows.first(where: { $0.title == "DialHack" || $0.identifier?.rawValue.contains("main") == true }) else {
            print("snapshot: main window not found")
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 1180, height: 820))
        NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        AppUI.shared.section = section
        InsightsModel.shared.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let file = out.appendingPathComponent("\(section.rawValue.lowercased())-\(look).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                print("snapshot: \(file.lastPathComponent)")
                // Further down the page: scroll and capture again (-2.png, -3.png, …).
                if let scroll = scrollView(in: view), let doc = scroll.documentView {
                    let page = scroll.contentView.bounds.height - 60
                    var y = page, n = 2
                    while y < doc.frame.height - 60, n <= 6 {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : doc.frame.height - page - y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        view.layoutSubtreeIfNeeded()
                        if let rep2 = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep2)
                            let f2 = out.appendingPathComponent("\(section.rawValue.lowercased())-\(look)-\(n).png")
                            try? rep2.representation(using: .png, properties: [:])?.write(to: f2)
                        }
                        y += page; n += 1
                    }
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? 0 : doc.frame.height - scroll.contentView.bounds.height))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            capture(steps.dropFirst(), into: out)
        }
    }
}
