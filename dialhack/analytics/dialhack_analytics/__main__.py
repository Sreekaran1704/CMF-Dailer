"""CLI: python -m dialhack_analytics {ingest,summary,make-demo,dashboard}"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import pandas as pd

from . import features, ingest, model, paths, synth


def load_labels(db: Path) -> pd.DataFrame:
    p = paths.labels_path_for(db)
    return pd.read_csv(p) if p.exists() else pd.DataFrame(columns=["window_start", "label"])


def cmd_ingest(a):
    added = ingest.ingest([Path(s) for s in a.sources] or None, db_path=Path(a.db))
    total = len(ingest.load_events(Path(a.db)))
    print(f"Added {added} events; {total} in {a.db}")


def cmd_summary(a):
    ev = ingest.load_events(Path(a.db))
    w = features.compute_windows(ev, window_minutes=a.window)
    r = model.analyze(w, include_stray=a.include_stray, labels=load_labels(Path(a.db)))
    print(f"{len(ev)} events, {len(w)} windows of {a.window} min ({int(w['likely_stray'].sum()) if len(w) else 0} likely stray)")
    if r.k:
        print(f"Clusters: k={r.k}, silhouette {r.silhouette:.2f}")
        print(r.profiles.to_string())
    rw = r.windows
    if rw["restless"].any():
        print("\nUnusually restless windows:")
        print(rw[rw["restless"]][["window_start", "rotations_per_min", "reversal_rate", "anomaly_score"]].to_string(index=False))
    if r.classifier_accuracy is not None:
        print(f"\nClassifier: {r.classifier_accuracy:.0%} cross-validated accuracy ({r.classifier_folds} folds)")
    for n in r.notes:
        print("note:", n)


def cmd_make_demo(a):
    df = synth.generate(days=a.days, seed=a.seed)
    src = synth.write_jsonl(df, paths.DATA_DIR / "demo-events.jsonl")
    if paths.DEMO_DB_PATH.exists():
        paths.DEMO_DB_PATH.unlink()
    ingest.ingest([src], db_path=paths.DEMO_DB_PATH)
    truth = synth.window_truth(df)
    truth = truth[truth["truth"].isin(synth.REGIMES)]
    demo_labels = truth.sample(frac=0.3, random_state=a.seed).rename(columns={"truth": "label"})
    demo_labels["label"] = demo_labels["label"].map({"focused": "focused", "restless": "stressed", "bored": "bored"})
    demo_labels.to_csv(paths.DEMO_LABELS_PATH, index=False)
    print(f"Demo: {len(df)} synthetic events over {a.days} days → {paths.DEMO_DB_PATH} "
          f"({len(demo_labels)} pre-labeled windows in {paths.DEMO_LABELS_PATH.name})")


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
