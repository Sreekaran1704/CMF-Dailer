"""Phase 2 pipeline tests. Run: analytics/.venv/bin/python -m pytest analytics/tests -q"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd
import pytest
from sklearn.metrics import adjusted_rand_score

from dialhack_analytics import features, ingest, labels, model, paths, pipeline, synth

ANALYTICS = Path(__file__).resolve().parent.parent


def ev(ts, event, **kw):
    raw = {"ROTATE_CW": "VOLUME_UP", "ROTATE_CCW": "VOLUME_DOWN", "PRESS_1": "PAUSE", "PRESS_2": "NEXT"}.get(event, "X")
    return {"ts": ts, "platform": "mac", "source": "volume", "raw": raw, "event": event, "mode": "scroll",
            "action": "a", "latency_ms": 1.0, "session_id": kw.get("session", "s1"), **kw}


def write(path: Path, rows) -> Path:
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n\nnot json\n" + json.dumps({"ts": "2026-10-01T00:00:00Z", "kind": "control"}) + "\n")
    return path


def test_ingest_parses_dedupes_and_is_idempotent(tmp_path, monkeypatch):
    monkeypatch.setattr(paths, "EXCLUDE_PATH", tmp_path / "none.txt")
    src = write(tmp_path / "a.jsonl", [ev("2026-10-01T10:00:00.000Z", "ROTATE_CW"), ev("2026-10-01T10:00:00.000Z", "ROTATE_CW"),
                                      ev("2026-10-01T10:00:01.500Z", "PRESS_1")])
    db = tmp_path / "t.duckdb"
    assert ingest.ingest([src], db_path=db) == 2  # duplicate line, blank line, bad JSON and control lines dropped
    assert ingest.ingest([src], db_path=db) == 0
    df = ingest.load_events(db)
    assert list(df["event"]) == ["ROTATE_CW", "PRESS_1"]
    assert str(df["ts"].dt.tz) == "UTC" and (df["steps"] == 1).all()


def test_excluded_sessions_are_dropped_and_purged(tmp_path, monkeypatch):
    ex = tmp_path / "exclude.txt"
    monkeypatch.setattr(paths, "EXCLUDE_PATH", ex)
    src = write(tmp_path / "a.jsonl", [ev("2026-10-01T10:00:00Z", "ROTATE_CW", session="real"),
                                      ev("2026-10-01T10:00:01Z", "ROTATE_CW", session="test-run")])
    db = tmp_path / "t.duckdb"
    ingest.ingest([src], db_path=db)
    ex.write_text("test-run  # scripted\n")
    ingest.ingest([src], db_path=db)
    assert list(ingest.load_events(db)["session_id"]) == ["real"]


def test_window_features_on_a_known_sequence():
    t0 = pd.Timestamp("2026-10-01T10:00:00Z")
    secs = [0, 0.5, 1.0, 1.4, 10, 10.4, 30]
    kinds = ["ROTATE_CW", "ROTATE_CW", "ROTATE_CCW", "ROTATE_CW", "PRESS_1", "ROTATE_CCW", "PRESS_2"]
    df = pd.DataFrame([ev(t0 + pd.Timedelta(seconds=s), k) for s, k in zip(secs, kinds)])
    w = features.compute_windows(df, window_minutes=5, burst_gap_s=2.0, tz="UTC")
    assert len(w) == 1
    r = w.iloc[0]
    assert r.n_rotations == 5 and r.n_cw == 3 and r.n_ccw == 2
    assert r.reversals == 3 and r.reversal_rate == pytest.approx(3 / 4)  # CW CW CCW CW CCW
    assert r.n_bursts == 3 and r.max_burst_size == 4                     # [0..1.4] [10, 10.4] [30]
    assert r.rotations_per_min == pytest.approx(1.0)
    assert r.press_ratio == pytest.approx(2 / 7)
    assert r.max_idle_s == pytest.approx(19.6)
    assert r.hour == 10 and not r.likely_stray


def test_multi_step_rotation_counts_each_click():
    t0 = pd.Timestamp("2026-10-01T10:00:00Z")
    df = pd.DataFrame([ev(t0, "ROTATE_CW", steps=2), ev(t0 + pd.Timedelta(seconds=1), "ROTATE_CCW")])
    r = features.compute_windows(df, tz="UTC").iloc[0]
    assert r.n_rotations == 3 and r.reversals == 1


def test_stray_windows_flagged_and_excluded():
    t0 = pd.Timestamp("2026-10-01T10:00:00Z")
    df = pd.DataFrame([ev(t0 + pd.Timedelta(hours=h), "PRESS_1") for h in range(10)])
    w = features.compute_windows(df, tz="UTC")
    assert w["likely_stray"].all()
    a = model.analyze(w)
    assert (a.windows["cluster"] == -1).all() and any("stray" in n for n in a.notes)


def test_empty_and_tiny_inputs_degrade_gracefully():
    assert model.analyze(features.compute_windows(pd.DataFrame(columns=ingest.COLUMNS))).notes
    t0 = pd.Timestamp("2026-10-01T10:00:00Z")
    df = pd.DataFrame([ev(t0 + pd.Timedelta(seconds=s), "ROTATE_CW") for s in range(5)])
    a = model.analyze(features.compute_windows(df, tz="UTC"))
    assert a.k is None and any("Clustering needs" in n for n in a.notes)


@pytest.fixture(scope="module")
def synthetic():
    df = synth.generate(days=10, seed=1)
    w = features.compute_windows(df, window_minutes=5, tz="UTC")
    truth = synth.window_truth(df)
    return df, w.merge(truth, on="window_start", how="left")


def test_clusters_recover_synthetic_regimes(synthetic):
    _, w = synthetic
    a = model.analyze(w)
    cw = a.windows[(a.windows["cluster"] >= 0) & a.windows["truth"].isin(synth.REGIMES)]
    assert a.k is not None and a.silhouette > 0.3
    assert adjusted_rand_score(cw["truth"], cw["cluster"]) > 0.6


def test_injected_spikes_are_flagged_restless(synthetic):
    df, w = synthetic
    a = model.analyze(w)
    spike_windows = set(pd.to_datetime(df[df["session_id"].str.startswith("spike")]["ts"], utc=True).dt.floor("300s"))
    flagged = set(a.windows[a.windows["restless"]]["window_start"])
    assert len(spike_windows & flagged) >= 0.6 * len(spike_windows)
    assert a.windows["restless"].mean() < 0.1  # rare, not everything


def labeled_windows(w, frac=1.0, seed=0):
    t = w[w["truth"].isin(synth.REGIMES)]
    t = t.sample(frac=frac, random_state=seed) if frac < 1 else t
    out = w.copy()
    out["label"] = None
    out.loc[t.index, "label"] = t["truth"]
    return out


def test_classifier_uses_time_ordered_folds_and_beats_baseline(synthetic):
    _, w = synthetic
    rep = model.classify(labeled_windows(w, frac=0.5))
    assert rep.status == "ok", rep.reason
    f = rep.folds
    assert len(f) >= 2
    assert (pd.to_datetime(f["train_until"]) < pd.to_datetime(f["test_from"])).all()  # never trains on the future
    assert rep.baseline_balanced == pytest.approx(1 / len(rep.classes_used), abs=0.15)
    assert rep.beats_baseline and rep.model_balanced > rep.baseline_balanced + 0.2


def test_classifier_reports_not_enough_data_below_minimums(synthetic):
    _, w = synthetic
    lw = labeled_windows(w)
    few = lw.copy()
    keep = few[few["label"].notna()].index[: model.MIN_LABELED - 1]
    few.loc[~few.index.isin(keep), "label"] = None
    rep = model.classify(few)
    assert rep.status == "not_enough_data" and rep.model_balanced is None and "Not enough data" in rep.reason

    one_class = lw.copy()
    one_class.loc[one_class["label"].notna(), "label"] = "focused"
    rep = model.classify(one_class)
    assert rep.status == "not_enough_data" and "at least 2 labels" in rep.reason

    rare = lw.copy()
    idx = rare[rare["label"] == "bored"].index
    rare.loc[idx[model.MIN_PER_CLASS - 1:], "label"] = None   # bored drops below the per-class minimum
    rep = model.classify(rare)
    assert rep.status == "ok" and "bored" not in rep.classes_used and "bored" in rep.reason


def test_focus_labels_ingest_with_sources_and_exclusions(tmp_path, monkeypatch):
    ex = tmp_path / "exclude.txt"
    monkeypatch.setattr(paths, "EXCLUDE_PATH", ex)
    f = tmp_path / "labels.jsonl"
    f.write_text("\n".join(json.dumps(r) for r in [
        {"ts": "2026-10-01T10:03:00Z", "label": "distracted", "source": "focus_timer_tag", "focus_session_id": "F1", "session_id": "app"},
        {"ts": "2026-10-01T10:30:00Z", "label": "Focused", "source": "focus_session_end", "focus_session_id": "F1",
         "start": "2026-10-01T10:00:00Z", "end": "2026-10-01T10:25:00Z", "session_id": "app"},
        {"ts": "2026-10-01T11:00:00Z", "label": "bored", "source": "focus_timer_tag", "focus_session_id": "T", "session_id": "test"},
        {"ts": "2026-10-01T11:00:00Z", "event": "PRESS_1"},
    ]) + "\n")
    db = tmp_path / "t.duckdb"
    ingest.ingest([f], db_path=db)
    ingest.ingest([f], db_path=db)  # idempotent
    le = ingest.load_label_events(db)
    assert sorted(le["source"]) == ["focus_session_end", "focus_timer_tag", "focus_timer_tag"]
    assert "focused" in set(le["label"])  # normalized
    ex.write_text("test\n")
    ingest.ingest([f], db_path=db)
    assert len(ingest.load_label_events(db)) == 2


def test_label_priority_session_span_and_empty_windows(tmp_path):
    t0 = pd.Timestamp("2026-10-01T10:00:00Z")
    events = pd.DataFrame([ev(t0 + pd.Timedelta(minutes=m, seconds=s), "ROTATE_CW") for m in (1, 7) for s in range(5)])
    le = pd.DataFrame([
        {"ts": t0 + pd.Timedelta(minutes=3), "label": "distracted", "source": labels.TAG, "start_ts": pd.NaT, "end_ts": pd.NaT},
        {"ts": t0 + pd.Timedelta(minutes=26), "label": "focused", "source": labels.SESSION,
         "start_ts": t0, "end_ts": t0 + pd.Timedelta(minutes=25)},
    ])
    dash = pd.DataFrame({"window_start": [t0 + pd.Timedelta(minutes=5)], "label": ["stressed"], "window_minutes": [5.0]})
    _, a = pipeline.build(tmp_path / "x.duckdb", window_minutes=5, tz="UTC", events=events, label_events=le,
                          dashboard_labels=dash)
    w = a.windows.set_index("window_start")
    assert len(w) == 5                                                    # 10:00–10:20: session span incl. empty windows
    assert w.loc[t0, "label"] == "distracted" and w.loc[t0, "label_source"] == labels.TAG       # tag beats session
    assert "focus_session_end:focused" in w.loc[t0, "label_sources"]                           # other vote kept
    assert w.loc[t0 + pd.Timedelta(minutes=5), "label_source"] == labels.DASHBOARD             # dashboard beats all
    assert w.loc[t0 + pd.Timedelta(minutes=15), "label"] == "focused"                          # session covers quiet window
    assert w.loc[t0 + pd.Timedelta(minutes=15), "n_events"] == 0


def test_focus_control_presses_are_not_features():
    t0 = pd.Timestamp("2026-10-01T10:00:00Z")
    rows = [ev(t0, "PRESS_1", action="focus_start"), ev(t0 + pd.Timedelta(seconds=20), "PRESS_2", action="focus_tag_distracted"),
            ev(t0 + pd.Timedelta(seconds=30), "ROTATE_CW", action="focus_fidget"),
            ev(t0 + pd.Timedelta(seconds=31), "ROTATE_CW", action="focus_rate_stressed"),
            ev(t0 + pd.Timedelta(seconds=40), "MODE_PICKER", action="open_mode_picker")]
    kept = features.fidget_events(pd.DataFrame(rows))
    assert list(kept["action"]) == ["focus_fidget"]


def test_dashboard_renders_with_demo_and_empty_data(tmp_path, monkeypatch):
    from streamlit.testing.v1 import AppTest

    df = synth.generate(days=3, seed=2)
    demo_db = tmp_path / "demo.duckdb"
    ingest.ingest([synth.write_jsonl(df, tmp_path / "demo.jsonl")], db_path=demo_db)
    monkeypatch.setattr(paths, "DEMO_DB_PATH", demo_db)
    monkeypatch.setattr(paths, "DB_PATH", tmp_path / "real.duckdb")
    monkeypatch.setattr(paths, "MAC_EVENTS", tmp_path / "missing.jsonl")
    monkeypatch.setattr(paths, "MAC_LABELS", tmp_path / "missing-labels.jsonl")
    monkeypatch.setattr(paths, "EXCLUDE_PATH", tmp_path / "no-excludes.txt")
    monkeypatch.setattr(paths, "INBOX_DIR", tmp_path / "inbox")
    monkeypatch.setattr(paths, "LABELS_PATH", tmp_path / "labels.csv")
    monkeypatch.setattr(paths, "DEMO_LABELS_PATH", tmp_path / "demo-labels.csv")

    at = AppTest.from_file(str(ANALYTICS / "dashboard.py"), default_timeout=60).run()
    assert not at.exception
    assert any("No dial events yet" in i.value for i in at.info)  # real DB empty

    at.sidebar.radio[0].set_value("Demo (synthetic)").run()
    assert not at.exception
    assert at.metric[0].value == f"{len(df):,}"
    assert len(at.tabs) == 5
    # Too few labels in a 3-day demo → the labels tab says so instead of showing a score.
    assert any("Not enough data" in x.value or "No labels" in x.value for x in at.warning)
