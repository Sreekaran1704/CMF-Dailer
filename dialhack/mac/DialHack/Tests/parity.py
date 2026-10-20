"""Native (Swift) insights vs the Python pipeline on the same logs.
Run: analytics/.venv/bin/python mac/DialHack/Tests/parity.py <InsightsCheck binary> events.jsonl [labels.jsonl] [hand.csv]
Exact match required for every per-window feature and label; clustering/restless/classifier
are compared by agreement, since the RNGs (and kNN vs random forest) differ."""
import json, math, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "analytics"))
import pandas as pd
from sklearn.metrics import adjusted_rand_score
from dialhack_analytics import features, ingest, labels, model, synth

binary, events_path, *rest = sys.argv[1:]
labels_path = rest[0] if rest else None
hand_path = rest[1] if len(rest) > 1 else None

swift = json.loads(subprocess.check_output([binary, events_path, *rest]))
sw = pd.DataFrame(swift["windows"])
sw["window_start"] = pd.to_datetime(sw["window_start"], utc=True)

ev = ingest.read_jsonl(Path(events_path)).drop_duplicates(subset=["session_id", "ts", "event", "raw"])
le = ingest.read_label_jsonl(Path(labels_path)) if labels_path else None
hand = labels.read_dashboard_labels(Path(hand_path)) if hand_path else None
v = labels.votes(le, hand, 5)
w = features.compute_windows(features.fidget_events(ev), 5, tz="UTC", include=v["window_start"].unique() if not v.empty else None)
w = labels.assign(w, v)
a = model.analyze(w)
py = a.windows

m = py.merge(sw, on="window_start", suffixes=("_py", "_sw"), how="outer", indicator=True)
assert (m["_merge"] == "both").all(), f"window sets differ: {m['_merge'].value_counts().to_dict()}"
bad = []
for c in ["n_events", "n_rotations", "reversals", "reversal_rate", "rotations_per_min", "n_bursts", "max_burst_size",
          "mean_burst_size", "iet_median_s", "iet_p90_s", "iet_cv", "max_idle_s", "press_ratio", "n_presses", "hour", "weekday"]:
    x, y = m[f"{c}_py"].astype(float), m[f"{c}_sw"].astype(float)
    diff = ~(((x - y).abs() < 1e-6) | (x.isna() & y.isna()))
    if diff.any():
        bad.append((c, int(diff.sum())))
lab_diff = (m["label_py"].fillna("-") != m["label_sw"].fillna("-")).sum() + (m["label_source_py"].fillna("-") != m["label_source_sw"].fillna("-")).sum()
print(f"windows: {len(m)}  features mismatched: {bad or 'none'}  label mismatches: {lab_diff}")

act = m[(m["cluster_py"] >= 0) & (m["cluster_sw"] >= 0)]
if len(act):
    print(f"clusters: python k={a.k} swift k={swift['k']}  agreement ARI={adjusted_rand_score(act['cluster_py'], act['cluster_sw']):.2f}")
    rp, rs = set(m[m["restless_py"] == True]["window_start"]), set(m[m["restless_sw"] == True]["window_start"])
    print(f"restless: python {len(rp)}, swift {len(rs)}, both {len(rp & rs)}")
c = swift["classifier"]; pc = a.classifier
print(f"classifier swift: ok={c['ok']} balanced {c['model_balanced']} vs baseline {c['baseline_balanced']} ({c['folds']} folds) {c['reason']}")
print(f"classifier python: {pc.status} balanced {pc.model_balanced} vs baseline {pc.baseline_balanced} {pc.reason}")
sys.exit(1 if bad or lab_diff else 0)
