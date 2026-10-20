"""CLI: python -m dialhack_analytics {ingest,summary,make-demo,dashboard}"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import pandas as pd

from . import ingest, model, paths, pipeline, synth


def print_classifier(rep: model.ClassifierReport | None) -> None:
    if rep is None:
        return
    print(f"\nLabels: {rep.n_labeled} labeled windows {rep.class_counts}")
    if rep.status != "ok":
        print("Classifier:", rep.reason)
        return
    print(f"Classifier ({len(rep.folds)} time-ordered folds, classes {rep.classes_used}):")
    print(f"  accuracy           model {rep.model_accuracy:.0%}  vs  majority baseline {rep.baseline_accuracy:.0%}")
    print(f"  balanced accuracy  model {rep.model_balanced:.0%}  vs  majority baseline {rep.baseline_balanced:.0%}"
          + ("" if rep.beats_baseline else "   ← does NOT beat the baseline"))
    if rep.reason:
        print(" ", rep.reason)


def cmd_ingest(a):
    added = ingest.ingest([Path(s) for s in a.sources] or None, db_path=Path(a.db))
    total = len(ingest.load_events(Path(a.db)))
    print(f"Added {added} events; {total} in {a.db}")


def cmd_summary(a):
    ev, r = pipeline.build(Path(a.db), window_minutes=a.window, include_stray=a.include_stray)
    w = r.windows
    print(f"{len(ev)} events, {len(w)} windows of {a.window} min ({int(w['likely_stray'].sum()) if len(w) else 0} likely stray)")
    if r.k:
        print(f"Clusters: k={r.k}, silhouette {r.silhouette:.2f}")
        print(r.profiles.to_string())
    rw = r.windows
    if rw["restless"].any():
        print("\nUnusually restless windows:")
        print(rw[rw["restless"]][["window_start", "rotations_per_min", "reversal_rate", "anomaly_score"]].to_string(index=False))
    print_classifier(r.classifier)
    for n in r.notes:
        print("note:", n)


def cmd_make_demo(a):
    df = synth.generate(days=a.days, seed=a.seed)
    src = synth.write_jsonl(df, paths.DATA_DIR / "demo-events.jsonl")
    if paths.DEMO_DB_PATH.exists():
        paths.DEMO_DB_PATH.unlink()
    lsrc = synth.write_label_jsonl(synth.focus_labels(df, seed=a.seed), paths.DATA_DIR / "demo-labels.jsonl")
    ingest.ingest([src, lsrc], db_path=paths.DEMO_DB_PATH)
    dash = synth.dashboard_labels(df, seed=a.seed)
    dash.to_csv(paths.DEMO_LABELS_PATH, index=False)
    n_lab = len(ingest.load_label_events(paths.DEMO_DB_PATH))
    print(f"Demo: {len(df)} synthetic events over {a.days} days → {paths.DEMO_DB_PATH} "
          f"({n_lab} Focus Timer labels, {len(dash)} dashboard labels)")


def cmd_dashboard(a):
    app = paths.ANALYTICS_DIR / "dashboard.py"
    sys.exit(subprocess.call([sys.executable, "-m", "streamlit", "run", str(app), "--server.address", "localhost",
                              "--server.headless", "true", "--browser.gatherUsageStats", "false", "--client.toolbarMode", "minimal",
                              "--server.port", str(a.port)]))


def main(argv=None):
    p = argparse.ArgumentParser(prog="dialhack_analytics")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("ingest", help="load JSONL logs (default: Mac log + data/inbox/*.jsonl)")
    s.add_argument("sources", nargs="*")
    s.add_argument("--db", default=str(paths.DB_PATH))
    s.set_defaults(func=cmd_ingest)

    s = sub.add_parser("summary", help="windows, clusters, restless windows")
    s.add_argument("--db", default=str(paths.DB_PATH))
    s.add_argument("--window", type=float, default=5)
    s.add_argument("--include-stray", action="store_true")
    s.set_defaults(func=cmd_summary)

    s = sub.add_parser("make-demo", help="build the synthetic demo database")
    s.add_argument("--days", type=int, default=14)
    s.add_argument("--seed", type=int, default=0)
    s.set_defaults(func=cmd_make_demo)

    s = sub.add_parser("dashboard", help="Streamlit dashboard on localhost")
    s.add_argument("--port", type=int, default=8501)
    s.set_defaults(func=cmd_dashboard)

    a = p.parse_args(argv)
    a.func(a)


if __name__ == "__main__":
    main()
