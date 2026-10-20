"""DialHack fidget telemetry dashboard (Phase 2). Run: python -m dialhack_analytics dashboard

Local only: reads analytics/data/*.duckdb, writes labels CSVs next to them.
"""
from __future__ import annotations

import datetime as _dt
from pathlib import Path

import pandas as pd
import plotly.graph_objects as go
import streamlit as st

from dialhack_analytics import ingest, labels, model, paths, pipeline, synth

st.set_page_config(page_title="DialHack · Fidget telemetry", page_icon="🎛️", layout="wide")

# --- palette (dataviz reference palette; light and dark are separately validated steps) -------------
PALETTE = {
    "light": {"surface": "#fcfcfb", "ink": "#0b0b0b", "ink2": "#52514e", "muted": "#898781", "grid": "#e1e0d9",
              "axis": "#c3c2b7", "series": ["#2a78d6", "#eb6834", "#1baf7a"], "critical": "#d03b3b",
              "seq": ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]},
    "dark": {"surface": "#1a1a19", "ink": "#f0efec", "ink2": "#c3c2b7", "muted": "#898781", "grid": "#2c2c2a",
             "axis": "#383835", "series": ["#3987e5", "#d95926", "#199e70"], "critical": "#d03b3b",
             # Low values recede toward the dark surface; magnitude rises toward the light end.
             "seq": ["#0d366b", "#104281", "#184f95", "#256abf", "#3987e5", "#6da7ec", "#b7d3f6"]},
}
theme_type = getattr(getattr(st.context, "theme", None), "type", None) or "light"
P = PALETTE["dark" if theme_type == "dark" else "light"]
LOCAL_TZ = _dt.datetime.now().astimezone().tzinfo
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def style(fig: go.Figure, height: int = 320, legend: bool = False) -> go.Figure:
    fig.update_layout(
        height=height, margin=dict(l=8, r=8, t=8, b=8), paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(family="system-ui, -apple-system, Segoe UI, sans-serif", size=13, color=P["ink2"]),
        showlegend=legend, legend=dict(orientation="h", yanchor="bottom", y=1.02, x=0, font=dict(color=P["ink2"])),
        hoverlabel=dict(bgcolor=P["surface"], font=dict(color=P["ink"]), bordercolor=P["axis"]),
        bargap=0.15,
    )
    fig.update_xaxes(gridcolor=P["grid"], linecolor=P["axis"], tickfont=dict(color=P["muted"]), zeroline=False)
    fig.update_yaxes(gridcolor=P["grid"], linecolor=P["axis"], tickfont=dict(color=P["muted"]), zeroline=False)
    return fig


# --- data ---------------------------------------------------------------------------------------------
def mtime(p: Path) -> float:
    return p.stat().st_mtime if p.exists() else 0.0


@st.cache_data(show_spinner=False)
def load(db: str, _mtime: float, window: float, include_stray: bool, labels_mtime: float):
    return pipeline.build(Path(db), window_minutes=window, include_stray=include_stray)


with st.sidebar:
    st.header("Data")
    source = st.radio("Source", ["Real telemetry", "Demo (synthetic)"], index=0)
    demo = source.startswith("Demo")
    db = paths.DEMO_DB_PATH if demo else paths.DB_PATH
    if demo and not db.exists():
        st.info("No demo data yet.")
        if st.button("Build demo data"):
            df = synth.generate(days=14)
            src = synth.write_jsonl(df, paths.DATA_DIR / "demo-events.jsonl")
            lsrc = synth.write_label_jsonl(synth.focus_labels(df), paths.DATA_DIR / "demo-labels.jsonl")
            ingest.ingest([src, lsrc], db_path=db)
            synth.dashboard_labels(df).to_csv(paths.DEMO_LABELS_PATH, index=False)
            st.rerun()
    if not demo:
        added = ingest.ingest(db_path=db)  # idempotent: picks up new events from the Mac log and data/inbox
        if added:
            st.caption(f"Ingested {added} new events.")
    window = st.select_slider("Window", options=[1, 5, 15, 30], value=5, format_func=lambda m: f"{m} min")
    include_stray = st.toggle("Include likely-stray windows", value=False,
                              help="Windows with ≤ 2 events are usually in-ear-detection pauses or pocket nudges.")
    st.caption(f"Database: `{db.name}`")

ev, res = load(str(db), mtime(db), window, include_stray, mtime(paths.labels_path_for(db)))
w = res.windows.copy()
if not w.empty:
    w["local"] = w["window_start"].dt.tz_convert(LOCAL_TZ)

st.title("Fidget telemetry")
st.caption("Synthetic demo data — not yours." if demo else "Your dial events from DialHack (Mac now; Android once it ships).")

if w.empty:
    st.info("No dial events yet. Use the dial with DialHack running, then reload.")
    st.stop()

active = w if include_stray else w[~w["likely_stray"]]
c = st.columns(5)
c[0].metric("Events", f"{len(ev):,}")
c[1].metric("Active windows", f"{len(active):,}", help=f"{window}-min windows with dial activity"
            + ("" if include_stray else ", excluding likely-stray ones"))
c[2].metric("Turns", f"{int(w['n_rotations'].sum()):,}")
c[3].metric("Presses", f"{int(w['n_presses'].sum()):,}")
c[4].metric("Unusually restless", f"{int(w['restless'].sum())}")
for n in res.notes:
    st.caption("ℹ️ " + n)

tab_time, tab_heat, tab_clusters, tab_restless, tab_labels = st.tabs(
    ["Timeline", "Time of day", "Clusters", "Restless windows", "Label windows"])

# --- timeline -----------------------------------------------------------------------------------------
with tab_time:
    st.subheader("Turning intensity per window")
    a = active.sort_values("local").assign(mid=lambda d: d["local"] + pd.Timedelta(minutes=window / 2))
    calm, hot = a[~a["restless"]], a[a["restless"]]
    bar_ms = window * 60_000 * 0.85  # bars span their window (with a gap), however sparse the data
    # Show at least 6 h so a lone window reads as a short bar, not a full-width block.
    lo, hi = a["local"].min(), a["local"].max() + pd.Timedelta(minutes=window)
    pad = max(pd.Timedelta(hours=6) - (hi - lo), pd.Timedelta(0)) / 2
    xrange = [lo - pad, hi + pad]
    fig = go.Figure()
    hover = "%{x|%a %d %b %H:%M}<br>%{y:.1f} turns/min<br>reversal rate %{customdata[0]:.0%}<extra></extra>"
    fig.add_bar(x=calm["mid"], y=calm["rotations_per_min"], width=bar_ms, name="Turns per minute",
                marker_color=P["series"][0], marker_line_width=0, customdata=calm[["reversal_rate"]], hovertemplate=hover)
    if len(hot):
        fig.add_bar(x=hot["mid"], y=hot["rotations_per_min"], width=bar_ms, name="⚠ Unusually restless",
                    marker_color=P["critical"], marker_line_width=0, customdata=hot[["reversal_rate"]], hovertemplate=hover)
    fig.update_layout(barmode="overlay", barcornerradius=4)
    fig.update_yaxes(title=dict(text="turns / min", font=dict(color=P["muted"])))
    fig.update_xaxes(range=xrange)
    st.plotly_chart(style(fig, legend=len(hot) > 0), width="stretch", theme=None)

    st.subheader("Presses per window")
    fig = go.Figure()
    fig.add_bar(x=a["mid"], y=a["n_presses"], width=bar_ms, name="Presses", marker_color=P["series"][0], marker_line_width=0,
                hovertemplate="%{x|%a %d %b %H:%M}<br>%{y} presses<extra></extra>")
    fig.update_layout(barcornerradius=4)
    fig.update_xaxes(range=xrange)
    st.plotly_chart(style(fig, height=220), width="stretch", theme=None)

# --- time of day heatmap ------------------------------------------------------------------------------
with tab_heat:
    st.subheader("When you fidget")
    metric = st.radio("Measure", ["Dial events", "Turns per active minute"], horizontal=True)
    h = active.copy()
    if metric == "Dial events":
        grid = h.pivot_table(index="hour", columns="weekday", values="n_events", aggfunc="sum")
        label = "events"
    else:
        grid = h.pivot_table(index="hour", columns="weekday", values="rotations_per_min", aggfunc="mean")
        label = "turns/min"
    grid = grid.reindex(index=range(24), columns=range(7))
    fig = go.Figure(go.Heatmap(
        z=grid.to_numpy(), x=DAYS, y=[f"{hh:02d}:00" for hh in range(24)],
        colorscale=[[i / (len(P["seq"]) - 1), col] for i, col in enumerate(P["seq"])],
        xgap=2, ygap=2, hoverongaps=False, colorbar=dict(title=dict(text=label), tickfont=dict(color=P["muted"])),
        hovertemplate="%{x} %{y}<br>%{z:.1f} " + label + "<extra></extra>"))
    fig.update_yaxes(autorange="reversed", showgrid=False)
    fig.update_xaxes(showgrid=False, side="top")
    st.plotly_chart(style(fig, height=620), width="stretch", theme=None)
    st.caption("Empty cells: no dial activity. Local time.")

# --- clusters -----------------------------------------------------------------------------------------
with tab_clusters:
    st.subheader("Fidget session clusters")
    if not res.k:
        st.info("Not enough active windows to cluster yet.")
    else:
        cl = w[w["cluster"] >= 0].copy()
        med = cl[["rotations_per_min", "reversal_rate", "press_ratio"]].median()

        def describe(row) -> str:
            parts = ["fast" if row.rotations_per_min > med.rotations_per_min * 1.5 else
                     "slow" if row.rotations_per_min < med.rotations_per_min * 0.5 else "moderate",
                     "back-and-forth" if row.reversal_rate > 0.25 else "one-way"]
            if row.press_ratio > 0.3:
                parts.append("press-heavy")
            return ", ".join(parts)

        prof = res.profiles.copy()
        prof["description"] = prof.apply(describe, axis=1)
        # Fixed slot order by cluster size; the scatter shows at most three slots, the rest fold into "Other".
        order = prof.sort_values("windows", ascending=False).index.tolist()
        names = {cid: f"Cluster {i + 1}: {prof.loc[cid, 'description']}" for i, cid in enumerate(order)}
        fig = go.Figure()
        for i, cid in enumerate(order[:3]):
            d = cl[cl["cluster"] == cid]
            fig.add_scatter(x=d["pca_x"], y=d["pca_y"], mode="markers", name=names[cid],
                            marker=dict(size=9, color=P["series"][i], line=dict(width=2, color=P["surface"])),
                            customdata=d[["rotations_per_min", "reversal_rate"]].assign(t=d["local"].dt.strftime("%a %d %b %H:%M")),
                            hovertemplate="%{customdata[2]}<br>%{customdata[0]:.1f} turns/min · reversals %{customdata[1]:.0%}<extra></extra>")
        rest = cl[cl["cluster"].isin(order[3:])]
        if len(rest):
            fig.add_scatter(x=rest["pca_x"], y=rest["pca_y"], mode="markers", name=f"Other ({len(order) - 3} clusters)",
                            marker=dict(size=9, color=P["muted"], line=dict(width=2, color=P["surface"])),
                            hovertemplate="other cluster<extra></extra>")
        fig.update_xaxes(title=dict(text="PCA 1", font=dict(color=P["muted"])))
        fig.update_yaxes(title=dict(text="PCA 2", font=dict(color=P["muted"])))
        st.plotly_chart(style(fig, height=440, legend=True), width="stretch", theme=None)
        st.caption(f"k = {res.k} (chosen by silhouette, {res.silhouette:.2f}). Each dot is one {window}-min window.")
        table = prof.loc[order].copy()
        table.index = [names[c].split(":")[0] for c in order]
        st.dataframe(table, width="stretch")

# --- restless windows ---------------------------------------------------------------------------------
with tab_restless:
    st.subheader("Unusually restless windows")
    st.caption("Isolation-forest anomalies with an above-median turning rate.")
    r = w[w["restless"]].sort_values("anomaly_score", ascending=False)
    if r.empty:
        st.info("None flagged" + ("" if w["anomaly_score"].notna().any() else " (not enough data for anomaly detection yet)") + ".")
    else:
        st.dataframe(r.assign(when=r["local"].dt.strftime("%a %d %b %H:%M"))[
            ["when", "rotations_per_min", "reversal_rate", "n_bursts", "max_burst_size", "anomaly_score"]],
            hide_index=True, width="stretch")

# --- labels -------------------------------------------------------------------------------------------
SOURCE_NAMES = {labels.DASHBOARD: "Dashboard", labels.TAG: "Focus Timer tag", labels.SESSION: "Focus session rating"}

with tab_labels:
    st.subheader("Labels and classifier")
    st.caption("Labels come from three sources, kept separately: your Focus Timer double-press (“distracted”, in the moment), "
               "the rating at the end of a Focus Timer session, and labels you set here. "
               "When they disagree on a window: dashboard > tag > session rating.")
    lw = w[w["label"].notna()]
    if len(lw):
        by_src = lw.groupby(["label_source", "label"]).size().unstack(fill_value=0)
        by_src.index = [SOURCE_NAMES.get(i, i) for i in by_src.index]
        st.dataframe(by_src, width="stretch")

    rep = res.classifier
    if rep is None or rep.status != "ok":
        st.warning((rep.reason if rep else "No labels yet.") + f" Labeled so far: {len(lw)} windows.")
    else:
        m = st.columns(4)
        m[0].metric("Balanced accuracy", f"{rep.model_balanced:.0%}",
                    delta=f"{(rep.model_balanced - rep.baseline_balanced) * 100:+.0f} pts vs baseline")
        m[1].metric("Majority baseline (balanced)", f"{rep.baseline_balanced:.0%}")
        m[2].metric("Accuracy", f"{rep.model_accuracy:.0%}", delta=f"{(rep.model_accuracy - rep.baseline_accuracy) * 100:+.0f} pts vs baseline")
        m[3].metric("Majority baseline", f"{rep.baseline_accuracy:.0%}")
        if not rep.beats_baseline:
            st.error("The classifier does not beat always guessing the most common label. Don't trust its predictions yet.")
        st.caption(f"{len(rep.folds)} time-ordered folds: each trains only on windows before its test windows "
                   f"(one-window gap). Classes: {', '.join(rep.classes_used)}. {rep.reason}")
        f = rep.folds.copy()
        for c in ("train_until", "test_from"):
            f[c] = pd.to_datetime(f[c], utc=True).dt.tz_convert(LOCAL_TZ).dt.strftime("%a %d %b %H:%M")
        st.dataframe(f, hide_index=True, width="stretch", column_config={
            c: st.column_config.NumberColumn(c.replace("_", " "), format="percent")
            for c in ("model_accuracy", "baseline_accuracy", "model_balanced", "baseline_balanced")})

    st.markdown("**Label windows by hand**")
    ed = active.sort_values("local", ascending=False).assign(
        when=lambda d: d["local"].dt.strftime("%a %d %b %H:%M"),
        source=lambda d: d["label_source"].map(SOURCE_NAMES),
        mine=lambda d: d["label"].where(d["label_source"] == labels.DASHBOARD))[
        ["window_start", "when", "rotations_per_min", "reversal_rate", "n_presses", "cluster", "label", "source",
         "predicted_label", "mine"]]
    edited = st.data_editor(
        ed, hide_index=True, width="stretch", height=420,
        disabled=["window_start", "when", "rotations_per_min", "reversal_rate", "n_presses", "cluster", "label",
                  "source", "predicted_label"],
        column_config={"window_start": None,
                       "label": "current label",
                       "mine": st.column_config.SelectboxColumn("your label", options=labels.LABELS),
                       "rotations_per_min": st.column_config.NumberColumn("turns/min", format="%.1f"),
                       "reversal_rate": st.column_config.NumberColumn("reversals", format="percent"),
                       "predicted_label": "predicted"})
    if st.button("Save my labels", type="primary"):
        out = edited.dropna(subset=["mine"])[["window_start", "mine"]].rename(columns={"mine": "label"})
        out["window_minutes"] = window
        lp = paths.labels_path_for(db)
        old = labels.read_dashboard_labels(lp)
        old = old[~old["window_start"].isin(ed["window_start"]) | (old["window_minutes"] != window)]
        allv = pd.concat([old, out], ignore_index=True)
        allv.assign(window_start=pd.to_datetime(allv["window_start"], utc=True).dt.strftime("%Y-%m-%dT%H:%M:%SZ")).to_csv(lp, index=False)
        st.toast(f"Saved {len(out)} labels")
        st.cache_data.clear()
        st.rerun()
