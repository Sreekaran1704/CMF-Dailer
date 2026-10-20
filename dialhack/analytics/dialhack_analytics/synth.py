"""Synthetic dial telemetry for tests and the demo dashboard. Never written to the real database.

Three fidget regimes, shaped by Phase 0 hardware limits (one click per ≥ ~300 ms):
  focused   steady same-direction scrolling, few reversals, few presses
  restless  fast clicks, frequent reversals, bursty
  bored     sparse, press-heavy, long idle gaps
plus a few extreme "restless spike" windows and isolated stray PAUSE presses.
"""
from __future__ import annotations

import json
import uuid
from pathlib import Path

import numpy as np
import pandas as pd

REGIMES = ("focused", "restless", "bored")


def _session(rng, start: pd.Timestamp, regime: str, minutes: float, session_id: str, spike=False):
    rows, t, end = [], start, start + pd.Timedelta(minutes=minutes)
    direction = 1
    while t < end:
        if regime == "focused":
            gap, p_rev, p_press = rng.uniform(1.5, 6.0), 0.05, 0.04
        elif regime == "restless":
            gap, p_rev, p_press = rng.uniform(0.3, 1.2), 0.45, 0.03
            if rng.random() < 0.08:
                gap += rng.uniform(3, 8)  # burst boundary
        else:
            gap, p_rev, p_press = rng.uniform(15, 90), 0.3, 0.45
        if spike:
            gap, p_rev = rng.uniform(0.3, 0.45), 0.7
        t = t + pd.Timedelta(seconds=float(gap))
        if rng.random() < p_press:
            ev, raw = ("PRESS_1", "PAUSE") if rng.random() < 0.7 else ("PRESS_2", "NEXT")
        else:
            if rng.random() < p_rev:
                direction = -direction
            ev, raw = ("ROTATE_CW", "VOLUME_UP") if direction > 0 else ("ROTATE_CCW", "VOLUME_DOWN")
        rows.append({"ts": t, "platform": "mac" if rng.random() < 0.7 else "android",
                     "source": "volume" if raw.startswith("VOLUME") else "media_key", "raw": raw, "event": ev,
                     "mode": "scroll" if regime == "focused" else "passthrough", "action": "synthetic",
                     "latency_ms": float(rng.uniform(1, 40)), "session_id": session_id, "regime": regime})
    return rows


def generate(days: int = 7, seed: int = 0, start: str = "2026-10-05T08:00:00Z") -> pd.DataFrame:
    """Returns events (shared schema) plus a `regime` ground-truth column."""
    rng = np.random.default_rng(seed)
    rows = []
    day0 = pd.Timestamp(start)
    for d in range(days):
        day = day0 + pd.Timedelta(days=d)
        # Mornings focused, afternoons mixed, evenings bored-ish.
        for hour, weights in [(9, (0.7, 0.2, 0.1)), (11, (0.6, 0.3, 0.1)), (14, (0.3, 0.5, 0.2)),
                              (16, (0.3, 0.5, 0.2)), (20, (0.1, 0.3, 0.6))]:
            regime = REGIMES[rng.choice(3, p=weights)]
            st = day + pd.Timedelta(hours=hour - 8, minutes=float(rng.uniform(0, 40)))
            rows += _session(rng, st, regime, float(rng.uniform(15, 45)), str(uuid.UUID(int=int(rng.integers(1 << 62)))))
        for _ in range(int(rng.integers(3, 8))):  # stray in-ear pauses
            t = day + pd.Timedelta(minutes=float(rng.uniform(0, 14 * 60)))
            rows.append({"ts": t, "platform": "mac", "source": "media_key", "raw": "PAUSE", "event": "PRESS_1",
                         "mode": "passthrough", "action": "play_pause", "latency_ms": 2.0,
                         "session_id": "stray", "regime": "stray"})
    for i in range(3):  # extreme spikes
        st = day0 + pd.Timedelta(days=int(rng.integers(days)), hours=4, minutes=7 * i)
        rows += _session(rng, st, "restless", 4, f"spike-{i}", spike=True)
    df = pd.DataFrame(rows).sort_values("ts").reset_index(drop=True)
    df["steps"] = 1
    return df


def write_jsonl(df: pd.DataFrame, path: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for r in df.drop(columns=["regime"], errors="ignore").to_dict("records"):
            r["ts"] = pd.Timestamp(r["ts"]).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
            f.write(json.dumps(r) + "\n")
    return path


REGIME_LABEL = {"focused": "focused", "restless": "distracted", "bored": "bored"}


def focus_labels(df: pd.DataFrame, seed: int = 0, rate_share: float = 0.6) -> pd.DataFrame:
    """Synthetic Focus Timer labels: a session rating for ~60% of sessions (its regime) and
    "distracted" tags sprinkled through restless sessions."""
    rng = np.random.default_rng(seed + 1)
    rows = []
    for sid, g in df[df["regime"].isin(REGIMES)].groupby("session_id"):
        start, end, regime = g["ts"].min(), g["ts"].max(), g["regime"].iloc[0]
        if rng.random() < rate_share:
            rows.append({"ts": end, "label": REGIME_LABEL[regime], "source": "focus_session_end",
                         "focus_session_id": sid, "start": start, "end": end, "platform": "mac", "session_id": "demo"})
        if regime == "restless":
            for t in g["ts"].sample(n=min(3, len(g)), random_state=int(rng.integers(1 << 31))):
                rows.append({"ts": t, "label": "distracted", "source": "focus_timer_tag", "focus_session_id": sid,
                             "platform": "mac", "session_id": "demo"})
    return pd.DataFrame(rows)


def write_label_jsonl(df: pd.DataFrame, path: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fmt = lambda t: pd.Timestamp(t).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"  # noqa: E731
    with open(path, "w", encoding="utf-8") as f:
        for r in df.to_dict("records"):
            for k in ("ts", "start", "end"):
                if k in r and pd.notna(r[k]):
                    r[k] = fmt(r[k])
                else:
                    r.pop(k, None)
            f.write(json.dumps(r) + "\n")
    return path


def dashboard_labels(df: pd.DataFrame, seed: int = 0, frac: float = 0.1, window_minutes: float = 5) -> pd.DataFrame:
    """A few hand labels, as if made in the dashboard (restless shown as "stressed")."""
    t = window_truth(df, window_minutes)
    t = t[t["truth"].isin(REGIMES)].sample(frac=frac, random_state=seed)
    lab = t["truth"].map({"focused": "focused", "restless": "stressed", "bored": "bored"})
    return pd.DataFrame({"window_start": t["window_start"].dt.strftime("%Y-%m-%dT%H:%M:%SZ"), "label": lab,
                         "window_minutes": window_minutes})


def window_truth(df: pd.DataFrame, window_minutes: float = 5) -> pd.DataFrame:
    """Majority regime per window (ground truth for tests and demo labels)."""
    d = df.copy()
    d["window_start"] = pd.to_datetime(d["ts"], utc=True).dt.floor(f"{int(window_minutes * 60)}s")
    return (d.groupby("window_start")["regime"].agg(lambda s: s.value_counts().index[0])
            .reset_index().rename(columns={"regime": "truth"}))
