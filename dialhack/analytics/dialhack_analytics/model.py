"""Unsupervised first, then optional supervised (brief, Phase 2).

- KMeans clustering of fidget windows (k chosen by silhouette), with a 2-D PCA projection for plotting.
- IsolationForest anomaly scores. "Unusually restless" = anomalous *and* above-median rotation rate.
- If you've labeled enough windows (focused / stressed / bored), a random forest with cross-validation.

Every function degrades gracefully with little data instead of raising.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.ensemble import IsolationForest, RandomForestClassifier
from sklearn.metrics import silhouette_score
from sklearn.model_selection import StratifiedKFold, cross_val_score
from sklearn.preprocessing import StandardScaler

from .features import MODEL_FEATURES, model_matrix

MIN_WINDOWS_TO_CLUSTER = 6
MIN_WINDOWS_FOR_ANOMALIES = 8
MIN_LABELS = 10
LABELS = ["focused", "stressed", "bored"]


@dataclass
class Analysis:
    windows: pd.DataFrame
    k: int | None = None
    silhouette: float | None = None
    profiles: pd.DataFrame | None = None
    classifier_accuracy: float | None = None
    classifier_folds: int | None = None
    notes: list[str] = field(default_factory=list)


def analyze(windows: pd.DataFrame, include_stray: bool = False, labels: pd.DataFrame | None = None,
            max_k: int = 6, seed: int = 0) -> Analysis:
    """Adds columns: cluster, pca_x, pca_y, anomaly_score, is_anomaly, restless, label, predicted_label."""
    w = windows.copy()
    for col, default in [("cluster", -1), ("pca_x", np.nan), ("pca_y", np.nan), ("anomaly_score", np.nan),
                         ("is_anomaly", False), ("restless", False), ("label", None), ("predicted_label", None)]:
        w[col] = default
    out = Analysis(windows=w)
    if w.empty:
        out.notes.append("No dial events yet.")
        return out

    mask = np.ones(len(w), bool) if include_stray else ~w["likely_stray"].to_numpy(bool)
    sub = w[mask]
    if not include_stray and (~mask).any():
        out.notes.append(f"{int((~mask).sum())} likely-stray windows (≤ 2 events) excluded from modeling.")
    if len(sub) < MIN_WINDOWS_TO_CLUSTER:
        out.notes.append(f"Clustering needs at least {MIN_WINDOWS_TO_CLUSTER} active windows; have {len(sub)}.")
        _attach_labels(out, labels)
        return out

    X = StandardScaler().fit_transform(model_matrix(sub))
    best = None
    for k in range(2, min(max_k, len(sub) - 1) + 1):
        km = KMeans(n_clusters=k, n_init=10, random_state=seed).fit(X)
        if len(set(km.labels_)) < 2:
            continue
        s = silhouette_score(X, km.labels_)
        if best is None or s > best[0]:
            best = (s, k, km.labels_)
    if best:
        out.silhouette, out.k, lab = best
        w.loc[sub.index, "cluster"] = lab
    pcs = PCA(n_components=2, random_state=seed).fit_transform(X) if X.shape[1] >= 2 else np.zeros((len(sub), 2))
    w.loc[sub.index, "pca_x"], w.loc[sub.index, "pca_y"] = pcs[:, 0], pcs[:, 1]

    if len(sub) >= MIN_WINDOWS_FOR_ANOMALIES:
        iso = IsolationForest(n_estimators=200, contamination="auto", random_state=seed).fit(X)
        w.loc[sub.index, "anomaly_score"] = -iso.score_samples(X)
        w.loc[sub.index, "is_anomaly"] = iso.predict(X) == -1
        busy = sub["rotations_per_min"] > sub["rotations_per_min"].median()
        w.loc[sub.index, "restless"] = w.loc[sub.index, "is_anomaly"].to_numpy(bool) & busy.to_numpy(bool)
    else:
        out.notes.append(f"Anomaly detection needs at least {MIN_WINDOWS_FOR_ANOMALIES} active windows; have {len(sub)}.")

    if out.k:
        prof = w[w["cluster"] >= 0].groupby("cluster")[MODEL_FEATURES].mean()
        prof.insert(0, "windows", w[w["cluster"] >= 0].groupby("cluster").size())
        out.profiles = prof.round(2)

    out.windows = w
    _attach_labels(out, labels)
    return out


def _attach_labels(out: Analysis, labels: pd.DataFrame | None) -> None:
    w = out.windows
    if labels is None or labels.empty:
        return
    lab = labels.dropna(subset=["label"]).copy()
    lab["window_start"] = pd.to_datetime(lab["window_start"], utc=True)
    m = dict(zip(lab["window_start"], lab["label"]))
    w["label"] = w["window_start"].map(m)
    labeled = w[w["label"].notna()]
    classes = labeled["label"].value_counts()
    if len(labeled) < MIN_LABELS or len(classes) < 2:
        out.notes.append(f"Classifier needs ≥ {MIN_LABELS} labeled windows across ≥ 2 labels; have {len(labeled)} "
                         f"across {len(classes)}.")
        return
    X = model_matrix(w)
    y = labeled["label"]
    folds = int(min(5, classes.min()))
    clf = RandomForestClassifier(n_estimators=300, random_state=0, class_weight="balanced")
    if folds >= 2:
        scores = cross_val_score(clf, X.loc[labeled.index], y, cv=StratifiedKFold(folds, shuffle=True, random_state=0))
        out.classifier_accuracy, out.classifier_folds = float(scores.mean()), folds
    else:
        out.notes.append("Every label needs ≥ 2 examples for cross-validation; accuracy not estimated.")
    clf.fit(X.loc[labeled.index], y)
    unl = w.index[w["label"].isna()]
    if len(unl):
        w.loc[unl, "predicted_label"] = clf.predict(X.loc[unl])
