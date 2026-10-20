"""Window labels from three sources, each kept separately:

  dashboard           labeled by hand in the dashboard (data/labels.csv)
  focus_timer_tag     "distracted" double press during a Focus Timer session, timestamped in the moment
  focus_session_end   the rating you give when a Focus Timer session ends; covers the whole session

When sources disagree on a window, the more deliberate and more specific one wins:
dashboard > focus_timer_tag > focus_session_end. `label_sources` keeps every vote.
"""
from __future__ import annotations

from pathlib import Path

import pandas as pd

LABELS = ["focused", "distracted", "stressed", "bored"]
DASHBOARD = "dashboard"
TAG = "focus_timer_tag"
SESSION = "focus_session_end"
PRIORITY = [DASHBOARD, TAG, SESSION]


def read_dashboard_labels(path: Path) -> pd.DataFrame:
    """CSV: window_start, label[, window_minutes]. Older files without window_minutes count as 5 min."""
    cols = ["window_start", "label", "window_minutes"]
    if not Path(path).exists():
        return pd.DataFrame(columns=cols)
    df = pd.read_csv(path)
    if df.empty:
        return pd.DataFrame(columns=cols)
    if "window_minutes" not in df:
        df["window_minutes"] = 5.0
    df["window_start"] = pd.to_datetime(df["window_start"], utc=True)
    df["label"] = df["label"].astype(str).str.lower()
    return df.dropna(subset=["label"])[cols]


def votes(label_events: pd.DataFrame, dashboard: pd.DataFrame, window_minutes: float) -> pd.DataFrame:
    """One row per (window_start, source, label) vote, on the current window grid."""
    w = pd.Timedelta(minutes=window_minutes)
    freq = f"{int(window_minutes * 60)}s"
    rows = []

    le = label_events if label_events is not None else pd.DataFrame()
    for r in le.itertuples(index=False):
        if r.source == TAG:
            rows.append((pd.Timestamp(r.ts).floor(freq), TAG, r.label))
        elif r.source == SESSION and pd.notna(r.start_ts) and pd.notna(r.end_ts):
            ws = pd.Timestamp(r.start_ts).floor(freq)
            while ws < pd.Timestamp(r.end_ts):
                rows.append((ws, SESSION, r.label))
                ws += w

    for r in (dashboard if dashboard is not None else pd.DataFrame()).itertuples(index=False):
        # A dashboard label covers the window it was made on; map it onto the current grid by overlap.
        start, end = pd.Timestamp(r.window_start), pd.Timestamp(r.window_start) + pd.Timedelta(minutes=float(r.window_minutes))
        ws = start.floor(freq)
        while ws < end:
            rows.append((ws, DASHBOARD, r.label))
            ws += w

    return pd.DataFrame(rows, columns=["window_start", "source", "label"]).drop_duplicates()


def assign(windows: pd.DataFrame, v: pd.DataFrame) -> pd.DataFrame:
    """Adds label (effective), label_source, label_sources ("source:label; …")."""
    w = windows.copy()
    w["label"], w["label_source"], w["label_sources"] = None, None, None
    if v.empty or w.empty:
        return w
    rank = {s: i for i, s in enumerate(PRIORITY)}
    v = v.assign(rank=v["source"].map(rank)).sort_values(["window_start", "rank"])
    best = v.groupby("window_start").first()
    allv = v.groupby("window_start").apply(
        lambda g: "; ".join(f"{s}:{l}" for s, l in zip(g["source"], g["label"])), include_groups=False)
    w["label"] = w["window_start"].map(best["label"])
    w["label_source"] = w["window_start"].map(best["source"])
    w["label_sources"] = w["window_start"].map(allv)
    return w
