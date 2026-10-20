import Foundation

/// Logger: one JSON line per recognized dial input, in the shared schema (docs/event-schema.md),
/// at ~/Library/Application Support/DialHack/events.jsonl. Local only.
final class EventLogger {
    static let directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DialHack", isDirectory: true)

    let url: URL
    let sessionId = UUID().uuidString
    private let q = DispatchQueue(label: "dialhack.log")
    private var handle: FileHandle?
    private var labelHandle: FileHandle?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(url: URL = EventLogger.directory.appendingPathComponent("events.jsonl")) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    /// Self-report labels (Focus Timer) go to their own file, labels.jsonl, with their source kept.
    func logLabel(_ r: LabelRecord) {
        q.async {
            var obj: [String: Any] = [
                "ts": self.iso.string(from: r.ts),
                "platform": "mac",
                "label": r.label,
                "source": r.source,
                "focus_session_id": r.focusSession,
                "session_id": self.sessionId,
            ]
            if let s = r.start { obj["start"] = self.iso.string(from: s) }
            if let e = r.end { obj["end"] = self.iso.string(from: e) }
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
            if self.labelHandle == nil {
                let url = self.url.deletingLastPathComponent().appendingPathComponent("labels.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                self.labelHandle = try? FileHandle(forWritingTo: url)
                self.labelHandle?.seekToEndOfFile()
            }
            self.labelHandle?.write(data)
            self.labelHandle?.write(Data([0x0A]))
        }
    }

    func log(raw: RawInput, event: String, mode: ModeID, action: String, latencyMs: Double, steps: Int = 1) {
        let now = Date()
        q.async {
            var obj: [String: Any] = [
                "ts": self.iso.string(from: now),
                "platform": "mac",
                "source": raw.source,
                "raw": raw.name,
                "event": event,
                "mode": mode.rawValue,
                "action": action,
                "latency_ms": NSDecimalNumber(string: String(format: "%.1f", latencyMs)),
                "session_id": self.sessionId,
            ]
            if steps != 1 { obj["steps"] = steps }
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
            self.handle?.write(data)
            self.handle?.write(Data([0x0A]))
        }
    }
}
