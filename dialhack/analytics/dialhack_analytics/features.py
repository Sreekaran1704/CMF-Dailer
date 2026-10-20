"""Per-window fidget features (brief, Phase 2).

One row per time window that has at least one dial event:
  rotations per minute, direction reversals, bursts, inter-event time distribution,
  idle gaps, press ratios, plus time-of-day context.

Windows with very few events are flagged `likely_stray`. In everyday use most of those are
in-ear-detection pauses and pocket nudges (findings.md, "Stray inputs"), not fidgeting.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

ROTATIONS = ("ROTATE_CW", "ROTATE_CCW")
PRESSES = ("PRESS_1", "PRESS_2", "PRESS_3")

#: Numeric features used for clustering / anomaly detection / classification.
MODEL_FEATURES = [
    "rotations_per_min", "reversal_rate", "n_bursts", "mean_burst_size", "max_burst_size",
    "iet_median_s", "iet_p90_s", "iet_cv", "max_idle_s", "press_ratio",
]

WINDOW_COLUMNS = [
    "window_start", "minutes", "n_events", "n_rotations", "n_cw", "n_ccw", "n_presses", "n_press1", "n_press2",
    "n_picker", "rotations_per_min", "reversals", "reversal_rate", "n_bursts", "mean_burst_size",
    "max_burst_size", "iet_median_s", "iet_p90_s", "iet_cv", "max_idle_s", "press_ratio", "active_span_s",
    "dominant_mode", "platforms", "hour", "weekday", "likely_stray",
]


def _window_row(ws: pd.Timestamp, g: pd.DataFrame, minutes: float, burst_gap_s: float) -> dict:
    g = g.sort_values("ts")
    secs = (g["ts"] - g["ts"].iloc[0]).dt.total_seconds().to_numpy()
    gaps = np.diff(secs)
    n = len(g)

    rot = g[g["event"].isin(ROTATIONS)]
    steps = rot["steps"].fillna(1).astype(int).to_numpy() if "steps" in rot else np.ones(len(rot), int)
    dirs = np.repeat(np.where(rot["event"].to_numpy() == "ROTATE_CW", 1, -1), np.maximum(steps, 1))
    n_rot = int(len(dirs))
    reversals = int((np.diff(dirs) != 0).sum()) if n_rot > 1 else 0

    if n:
        burst_id = np.concatenate([[0], np.cumsum(gaps > burst_gap_s)])
        sizes = np.bincount(burst_id)
    else:
        sizes = np.array([], int)

    presses = g["event"].isin(PRESSES)
    return {
        "window_start": ws,
        "minutes": minutes,
        "n_events": n,
        "n_rotations": n_rot,
        "n_cw": int((dirs > 0).sum()),
        "n_ccw": int((dirs < 0).sum()),
        "n_presses": int(presses.sum()),
        "n_press1": int((g["event"] == "PRESS_1").sum()),
        "n_press2": int((g["event"] == "PRESS_2").sum()),
        "n_picker": int((g["event"] == "MODE_PICKER").sum()),
        "rotations_per_min": n_rot / minutes,
        "reversals": reversals,
        "reversal_rate": reversals / (n_rot - 1) if n_rot > 1 else 0.0,
        "n_bursts": int(len(sizes)),
        "mean_burst_size": float(sizes.mean()) if len(sizes) else 0.0,
        "max_burst_size": int(sizes.max()) if len(sizes) else 0,
        "iet_median_s": float(np.median(gaps)) if len(gaps) else np.nan,
        "iet_p90_s": float(np.percentile(gaps, 90)) if len(gaps) else np.nan,
        "iet_cv": float(gaps.std() / gaps.mean()) if len(gaps) > 1 and gaps.mean() > 0 else np.nan,
        "max_idle_s": float(gaps.max()) if len(gaps) else minutes * 60.0,
        "press_ratio": float(presses.mean()) if n else 0.0,
        "active_span_s": float(secs[-1]) if n else 0.0,
        "dominant_mode": g["mode"].mode().iloc[0] if g["mode"].notna().any() else None,
        "platforms": ",".join(sorted(g["platform"].dropna().astype(str).unique())),
    }


def compute_windows(events: pd.DataFrame, window_minutes: float = 5, burst_gap_s: float = 2.0,
                    stray_max_events: int = 2, tz: str | None = None) -> pd.DataFrame:
    """Aggregate events into fixed windows. `tz` sets the timezone for hour/weekday (default: local)."""
    if events.empty:
        return pd.DataFrame(columns=WINDOW_COLUMNS)
    ev = events.copy()
    ev["ts"] = pd.to_datetime(ev["ts"], utc=True)
    if "steps" not in ev:
        ev["steps"] = 1
    freq = f"{int(window_minutes * 60)}s"
    ev["window_start"] = ev["ts"].dt.floor(freq)
    rows = [_window_row(ws, g, window_minutes, burst_gap_s) for ws, g in ev.groupby("window_start", sort=True)]
    df = pd.DataFrame(rows)
    local = df["window_start"].dt.tz_convert(tz) if tz else df["window_start"].dt.tz_convert(_local_tz())
    df["hour"] = local.dt.hour
    df["weekday"] = local.dt.dayofweek
    df["likely_stray"] = df["n_events"] <= stray_max_events
    return df[WINDOW_COLUMNS]


def _local_tz():
    import datetime as _dt
    return _dt.datetime.now().astimezone().tzinfo


def model_matrix(windows: pd.DataFrame) -> pd.DataFrame:
    """Feature matrix with NaNs filled: missing inter-event stats mean 'too few events', i.e. calm."""
    X = windows[MODEL_FEATURES].astype(float).copy()
    fill = {"iet_median_s": windows["minutes"].iloc[0] * 60 if len(windows) else 300.0,
            "iet_p90_s": windows["minutes"].iloc[0] * 60 if len(windows) else 300.0,
            "iet_cv": 0.0}
    return X.fillna(fill).fillna(0.0)


def minute_series(events: pd.DataFrame) -> pd.DataFrame:
    """Events per minute by event type, for the timeline chart."""
    if events.empty:
        return pd.DataFrame(columns=["minute", "event", "count"])
    ev = events.copy()
    ev["minute"] = pd.to_datetime(ev["ts"], utc=True).dt.floor("60s")
    return ev.groupby(["minute", "event"]).size().reset_index(name="count")
