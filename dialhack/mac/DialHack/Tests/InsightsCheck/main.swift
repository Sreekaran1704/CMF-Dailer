import Foundation

// Parity harness: run the native insights engine on JSONL logs and print JSON for Tests/parity.py.
// Usage: InsightsCheck events.jsonl [labels.jsonl] [hand_labels.csv]
let a = CommandLine.arguments
let ev = InsightsIO.events(URL(fileURLWithPath: a[1]))
let le = a.count > 2 ? InsightsIO.labelEvents(URL(fileURLWithPath: a[2])) : []
let hand = a.count > 3 ? InsightsIO.handLabels(URL(fileURLWithPath: a[3])) : []
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!
let r = Insights.analyze(events: ev, labelEvents: le, hand: hand, minutes: 5, calendar: cal)
let iso = ISO8601DateFormatter()
func num(_ x: Double?) -> Any { x.map { $0 as Any } ?? NSNull() }
let windows: [[String: Any]] = r.windows.map { w in
    ["window_start": iso.string(from: w.start), "n_events": w.nEvents, "n_rotations": w.nRotations, "reversals": w.reversals,
     "reversal_rate": w.reversalRate, "rotations_per_min": w.rotationsPerMin, "n_bursts": w.nBursts,
     "max_burst_size": w.maxBurstSize, "mean_burst_size": w.meanBurstSize, "iet_median_s": num(w.ietMedian),
     "iet_p90_s": num(w.ietP90), "iet_cv": num(w.ietCV), "max_idle_s": w.maxIdle, "press_ratio": w.pressRatio,
     "n_presses": w.nPresses, "hour": w.hour, "weekday": w.weekday, "label": w.label ?? NSNull(),
     "label_source": w.labelSource ?? NSNull(), "cluster": w.cluster, "restless": w.restless,
     "predicted": w.predicted ?? NSNull()]
}
let c = r.classifier
let out: [String: Any] = ["windows": windows, "k": r.k ?? NSNull(), "silhouette": num(r.silhouette),
                          "classifier": ["ok": c.ok, "reason": c.reason, "labeled": c.labeled, "folds": c.folds.count,
                                         "model_balanced": c.ok ? c.modelBalanced : NSNull(),
                                         "baseline_balanced": c.ok ? c.baselineBalanced : NSNull(),
                                         "model_accuracy": c.ok ? c.modelAccuracy : NSNull(),
                                         "baseline_accuracy": c.ok ? c.baselineAccuracy : NSNull()]]
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out))
