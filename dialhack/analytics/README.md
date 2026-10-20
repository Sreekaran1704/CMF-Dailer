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

**Data sources.** By default, ingest reads the Mac logs (`~/Library/Application Support/DialHack/events.jsonl` and the Focus Timer's `labels.jsonl`) and any `data/inbox/*.jsonl` (drop Android exports there). Re-ingesting is idempotent. Session ids listed in `~/Library/Application Support/DialHack/exclude_sessions.txt` are dropped; use it for scripted test runs.

**Storage.** `data/telemetry.duckdb` holds real events, `data/demo.duckdb` holds demo events, and your hand-made labels are in `~/Library/Application Support/DialHack/dashboard_labels.csv`, shared with the DialHack app. All of `data/` is git-ignored.

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
3. **Classifier.** Labels come from three sources, each kept separately (`label_source`, plus every vote in `label_sources`):

   | Source | Where it comes from | Covers |
   |---|---|---|
   | `dashboard` | you, in the Label windows tab | the window you labeled |
   | `focus_timer_tag` | Focus Timer double press ("distracted"), in the moment | the window it happened in |
   | `focus_session_end` | the rating at the end of a Focus Timer session | every window in the session, including quiet ones |

   When sources disagree on a window: **dashboard > tag > session rating**.
   - **Evaluation is time-ordered:** each fold trains only on windows *before* its test windows, with a one-window gap. It's always reported against a **majority-class baseline** fit on the same training part, using both accuracy and balanced accuracy.
   - **Below 30 labeled windows**, or with fewer than 2 labels that have ≥ 5 windows each, it shows **"Not enough data"** instead of a score. Labels with < 5 windows are left out and named.
   - **Focus Timer control presses** (start, pause, the tag press, rating turns) and mode-picker inputs are **excluded from features**, so a classifier can't learn "has a tag press = distracted". Turns made while a timer runs count as fidgeting.

Charts use the data-viz reference palette, with separate light and dark steps, status red plus a ⚠ label for "restless", and at most three cluster colors before "Other".

## Honest limits

- The tests check the pipeline on **synthetic** regimes (cluster recovery ARI > 0.6, injected spikes flagged, classifier clearly above the majority baseline on time-ordered folds). That proves the code works, not that real fidgeting splits the same way.
- Real data so far is about 30 events, nearly all stray. The models need a few days of actual dial use before clusters or anomalies mean anything.
