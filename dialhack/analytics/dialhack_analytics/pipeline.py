"""events + labels → labeled windows → analysis. Shared by the CLI, the dashboard and the tests."""
from __future__ import annotations

from pathlib import Path

import pandas as pd

from . import features, ingest, labels, model, paths


def build(db: Path, window_minutes: float = 5, include_stray: bool = False, tz: str | None = None,
          events: pd.DataFrame | None = None, label_events: pd.DataFrame | None = None,
          dashboard_labels: pd.DataFrame | None = None) -> tuple[pd.DataFrame, model.Analysis]:
    ev = ingest.load_events(db) if events is None else events
    le = ingest.load_label_events(db) if label_events is None else label_events
    dl = labels.read_dashboard_labels(paths.labels_path_for(db)) if dashboard_labels is None else dashboard_labels

    v = labels.votes(le, dl, window_minutes)
    fidget = features.fidget_events(ev)
    w = features.compute_windows(fidget, window_minutes=window_minutes, tz=tz,
                                 include=v["window_start"].unique() if not v.empty else None)
    w = labels.assign(w, v)
    return ev, model.analyze(w, include_stray=include_stray)
