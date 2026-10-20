# DialHack analytics

Two things live here:

- `sniffer_report.py`: Phase 0 sniffer log → findings tables (standard library only).
- `dialhack_analytics/` + `dashboard.py`: **Phase 2 fidget telemetry**.

Everything runs locally. Nothing is uploaded; the dashboard binds to `localhost` and Streamlit usage stats are off.

## Setup (once)

```bash
cd analytics
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

`requirements.lock.txt` pins the exact versions that were tested.

## Use

```bash
cd analytics
.venv/bin/python -m dialhack_analytics dashboard        # http://localhost:8501
.venv/bin/python -m dialhack_analytics summary          # same analysis in the terminal
.venv/bin/python -m dialhack_analytics ingest [files]   # load logs (the dashboard also does this on every load)
.venv/bin/python -m dialhack_analytics make-demo        # synthetic demo database, separate from real data
.venv/bin/python -m pytest tests -q                     # tests
```

**Data sources.** By default, ingest reads the Mac log (`~/Library/Application Support/DialHack/events.jsonl`) and any `data/inbox/*.jsonl` (drop Android exports there). Re-ingesting is idempotent. Session ids listed in `data/exclude_sessions.txt` are dropped; use it for scripted test runs.

**Storage.** `data/telemetry.duckdb` holds real events, `data/demo.duckdb` holds demo events, and `data/labels.csv` holds your labels. All of `data/` is git-ignored.

## What it computes

Per window (5 min by default; 1, 5, 15 or 30 in the dashboard):

| Feature | Meaning |
|---|---|
| `rotations_per_min` | dial clicks per minute (multi-step changes count each click) |
| `reversal_rate` | share of consecutive clicks that change direction |
| `n_bursts`, `mean/max_burst_size` | runs of events with gaps ≤ 2 s |
| `iet_median_s`, `iet_p90_s`, `iet_cv` | inter-event time distribution |
| `max_idle_s` | longest pause inside the window |
| `press_ratio` | presses / all events |

**Likely stray.** Windows with ≤ 2 events are flagged as likely stray and left out of modeling by default. In real use these are mostly in-ear-detection pauses and pocket nudges (`docs/findings.md`).

**Models**
1. **KMeans clustering.** k is chosen by silhouette; there's a PCA scatter and an auto-described profile per cluster. Needs ≥ 6 active windows.
2. **IsolationForest anomalies.** A window is *unusually restless* when it's an anomaly **and** turning faster than the median. Needs ≥ 8 active windows.
3. **Optional classifier.** Label windows `focused` / `stressed` / `bored` in the dashboard. With ≥ 10 labels across ≥ 2 kinds, a random forest reports cross-validated accuracy and predicts the rest.

Charts use the data-viz reference palette, with separate light and dark steps, status red plus a ⚠ label for "restless", and at most three cluster colors before "Other".

## Honest limits

- The tests check the pipeline on **synthetic** regimes (cluster recovery ARI > 0.6, injected spikes flagged, classifier > 80%). That proves the code works, not that real fidgeting splits the same way.
- Real data so far is about 30 events, nearly all stray. The models need a few days of actual dial use before clusters or anomalies mean anything.
