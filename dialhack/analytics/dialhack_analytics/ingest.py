"""Ingest DialHack JSONL event logs (shared schema, docs/event-schema.md) into one DuckDB table.

Idempotent: re-ingesting the same file adds nothing, so it's safe to run on every dashboard load.
"""
from __future__ import annotations

import json
from pathlib import Path

import duckdb
import pandas as pd

from . import paths

COLUMNS = ["ts", "platform", "source", "raw", "event", "mode", "action", "latency_ms", "steps", "session_id", "src_file"]

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    ts          TIMESTAMPTZ NOT NULL,
    platform    VARCHAR,
    source      VARCHAR,
    raw         VARCHAR,
    event       VARCHAR NOT NULL,
    mode        VARCHAR,
    action      VARCHAR,
    latency_ms  DOUBLE,
    steps       INTEGER,
    session_id  VARCHAR,
    src_file    VARCHAR
)
"""

EVENT_TYPES = {"ROTATE_CW", "ROTATE_CCW", "PRESS_1", "PRESS_2", "PRESS_3", "MODE_PICKER"}


def connect(db_path: Path = paths.DB_PATH) -> duckdb.DuckDBPyConnection:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(db_path))
    con.execute(SCHEMA)
    return con


def read_jsonl(path: Path) -> pd.DataFrame:
    """Parse one log file, skipping malformed lines and anything that isn't a dial event."""
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("event") not in EVENT_TYPES or "ts" not in e:
                continue
            rows.append(e)
    df = pd.DataFrame(rows)
    if df.empty:
        return pd.DataFrame(columns=COLUMNS)
    for c in COLUMNS:
        if c not in df.columns:
            df[c] = None
    df["ts"] = pd.to_datetime(df["ts"], utc=True, format="ISO8601", errors="coerce")
    df = df.dropna(subset=["ts"])
    df["latency_ms"] = pd.to_numeric(df["latency_ms"], errors="coerce")
    df["steps"] = pd.to_numeric(df["steps"], errors="coerce").fillna(1).astype("int64")
    df["src_file"] = str(path)
    return df[COLUMNS]


def excluded_sessions() -> set[str]:
    if not paths.EXCLUDE_PATH.exists():
        return set()
    lines = (l.split("#", 1)[0].strip() for l in paths.EXCLUDE_PATH.read_text().splitlines())
    return {l for l in lines if l}


def default_sources() -> list[Path]:
    srcs = [paths.MAC_EVENTS] if paths.MAC_EVENTS.exists() else []
    if paths.INBOX_DIR.exists():
        srcs += sorted(paths.INBOX_DIR.glob("*.jsonl"))
    return srcs


def ingest(sources: list[Path] | None = None, db_path: Path = paths.DB_PATH) -> int:
    """Load events from `sources` (default: the Mac log plus data/inbox/*.jsonl). Returns rows added."""
    sources = default_sources() if sources is None else [Path(s) for s in sources]
    frames = [read_jsonl(p) for p in sources if Path(p).exists()]
    frames = [f for f in frames if not f.empty]
    con = connect(db_path)
    try:
        if not frames:
            return 0
        new = pd.concat(frames, ignore_index=True).drop_duplicates(subset=["session_id", "ts", "event", "raw"])
        skip = excluded_sessions()
        if skip:
            new = new[~new["session_id"].isin(skip)]
            con.execute("DELETE FROM events WHERE session_id IN (SELECT unnest(?::VARCHAR[]))", [sorted(skip)])
        before = con.execute("SELECT count(*) FROM events").fetchone()[0]
        con.register("incoming", new)
        con.execute("""
            INSERT INTO events
            SELECT i.* FROM incoming i
            WHERE NOT EXISTS (
                SELECT 1 FROM events e
                WHERE e.session_id IS NOT DISTINCT FROM i.session_id AND e.ts = i.ts
                  AND e.event = i.event AND e.raw IS NOT DISTINCT FROM i.raw
            )
        """)
        con.unregister("incoming")
        return con.execute("SELECT count(*) FROM events").fetchone()[0] - before
    finally:
        con.close()


def load_events(db_path: Path = paths.DB_PATH) -> pd.DataFrame:
    if not Path(db_path).exists():
        return pd.DataFrame(columns=COLUMNS)
    con = connect(db_path)
    try:
        df = con.execute("SELECT * FROM events ORDER BY ts").df()
    finally:
        con.close()
    if not df.empty:
        df["ts"] = pd.to_datetime(df["ts"], utc=True)
    return df
