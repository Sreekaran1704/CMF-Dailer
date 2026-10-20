import Foundation

/// Append-only JSONL logger for sniffer runs.
/// Every line carries `kind`: "capture" (a candidate dial signal), "self" (our own restore echo),
/// "marker" (latency reference), or "control" (labels, config, diagnostics).
final class SnifferLog {
    static let shared = SnifferLog()

    let sessionId = UUID().uuidString
    let url: URL
    private var label = "unlabeled"
    private let queue = DispatchQueue(label: "dialsniffer.log")
    private let handle: FileHandle
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    struct Record {
        let kind: String
        let method: String
        let raw: String
        let monoMs: Double
        let fields: [String: Any]
    }

    /// Called on the log queue for every line written (guided mode watches captures through this).
    var observer: ((Record) -> Void)?
    /// Print each line to stdout.
    var echo = true

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DialHack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let override = ProcessInfo.processInfo.environment["DIALSNIFFER_LOG"] {
            url = URL(fileURLWithPath: override)
        } else {
            url = dir.appendingPathComponent("sniffer.jsonl")
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    static func monoMs() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000
    }

    func setLabel(_ newLabel: String) {
        queue.async { self.label = newLabel }
        write(kind: "control", method: "label", raw: newLabel)
    }

    func currentLabel() -> String { queue.sync { label } }

    /// Fields arrive as `Any`, often wrapping Optionals. Unwrap them so JSON gets the value or null
    /// and the console doesn't print `Optional(...)`.
    static func unwrap(_ v: Any) -> Any {
        let m = Mirror(reflecting: v)
        guard m.displayStyle == .optional else { return v }
        return m.children.first.map { unwrap($0.value) } ?? NSNull()
    }

    func write(kind: String, method: String, raw: String, fields rawFields: [String: Any] = [:]) {
        let fields = rawFields.mapValues(SnifferLog.unwrap)
        let mono = SnifferLog.monoMs()
        let now = Date()
        queue.async {
            var obj: [String: Any] = [
                "ts": self.iso.string(from: now),
                "platform": "mac",
                "kind": kind,
                "method": method,
                "raw": raw,
                "label": self.label,
                "session_id": self.sessionId,
                "mono_ms": mono,
            ]
            for (k, v) in fields { obj[k] = v }
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
            self.handle.write(data)
            self.handle.write(Data([0x0A]))

            let extras = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
            let t = String(format: "%.1f", mono)
            if self.echo {
                print("[\(t)] [\(self.label)] \(kind.padding(toLength: 7, withPad: " ", startingAt: 0)) \(method)  \(raw)  \(extras)")
                fflush(stdout)
            }
            self.observer?(Record(kind: kind, method: method, raw: raw, monoMs: mono, fields: fields))
        }
    }
}
