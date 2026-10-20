"""DialHack fidget telemetry (Phase 2): ingest dial event logs, engineer per-window features,
cluster sessions, flag unusually restless windows, and optionally learn user labels.

Everything is local: logs in, a DuckDB file out, a Streamlit dashboard on localhost.
"""
