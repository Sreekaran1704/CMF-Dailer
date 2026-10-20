"""Unsupervised first, then optional supervised (brief, Phase 2).

- KMeans clustering of fidget windows (k chosen by silhouette), with a 2-D PCA projection for plotting.
- IsolationForest anomaly scores. "Unusually restless" = anomalous *and* above-median rotation rate.
- With enough labels (dashboard, Focus Timer tags, session ratings): a random forest evaluated on
  time-ordered folds against a majority-class baseline; "not enough data" below the minimums.

Every function degrades gracefully with little data instead of raising.
"""
from __future__ import annotations

import warnings
from dataclasses import dataclass, field

import numpy as np
import pandas as pd
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.ensemble import IsolationForest, RandomForestClassifier
from sklearn.dummy import DummyClassifier
from sklearn.metrics import accuracy_score, balanced_accuracy_score, silhouette_score
from sklearn.model_selection import TimeSeriesSplit
from sklearn.preprocessing import StandardScaler

from .features import MODEL_FEATURES, model_matrix

MIN_WINDOWS_TO_CLUSTER = 6
MIN_WINDOWS_FOR_ANOMALIES = 8
#: Below these the classifier reports "not enough data" instead of a score.
MIN_LABELED = 30
MIN_PER_CLASS = 5
MAX_FOLDS = 5
LABELS = ["focused", "distracted", "stressed", "bored"]


@dataclass
class ClassifierReport:
    status: str                       # "ok" | "not_enough_data"
    reason: str = ""
    n_labeled: int = 0
    class_counts: dict = field(default_factory=dict)
    classes_used: list = field(default_factory=list)
    folds: pd.DataFrame | None = None  # one row per time-ordered fold
    model_accuracy: float | None = None
    baseline_accuracy: float | None = None
    model_balanced: float | None = None
    baseline_balanced: float | None = None

    @property
    def beats_baseline(self) -> bool | None:
        if self.model_balanced is None or self.baseline_balanced is None:
            return None
        return self.model_balanced > self.baseline_balanced


@dataclass
class Analysis:
    windows: pd.DataFrame
    k: int | None = None
    silhouette: float | None = None
    profiles: pd.DataFrame | None = None
    classifier: ClassifierReport | None = None
    notes: list[str] = field(default_factory=list)


def analyze(windows: pd.DataFrame, include_stray: bool = False, max_k: int = 6, seed: int = 0) -> Analysis:
    """Adds: cluster, pca_x, pca_y, anomaly_score, is_anomaly, restless, predicted_label.
    Uses an optional `label` column (see labels.assign) for the classifier."""
    w = windows.copy()
    if "label" not in w:
        w["label"] = None
    for col, default in [("cluster", -1), ("pca_x", np.nan), ("pca_y", np.nan), ("anomaly_score", np.nan),
                         ("is_anomaly", False), ("restless", False), ("predicted_label", None)]:
        w[col] = default
    out = Analysis(windows=w)
    if w.empty:
        out.notes.append("No dial events yet.")
        out.classifier = ClassifierReport("not_enough_data", "No labeled windows yet.")
        return out

    mask = np.ones(len(w), bool) if include_stray else ~w["likely_stray"].to_numpy(bool)
    sub = w[mask]
    if not include_stray and (~mask).any():
        out.notes.append(f"{int((~mask).sum())} likely-stray windows (≤ 2 events) excluded from modeling.")
    if len(sub) < MIN_WINDOWS_TO_CLUSTER:
        out.notes.append(f"Clustering needs at least {MIN_WINDOWS_TO_CLUSTER} active windows; have {len(sub)}.")
        out.classifier = classify(w)
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
    out.classifier = classify(w)
    return out


def classify(w: pd.DataFrame, seed: int = 0) -> ClassifierReport:
    """Time-ordered evaluation: every fold trains only on windows *before* its test windows (with one
    window of gap, so neighbours don't leak), and is scored against a majority-class baseline fit on
    the same training part. Labeled windows are used whether or not they look stray.
    Writes `predicted_label` for unlabeled windows into `w` when there's enough data."""
    labeled = w[w["label"].notna()].sort_values("window_start")
    counts = labeled["label"].value_counts().to_dict()
    rep = ClassifierReport("not_enough_data", n_labeled=len(labeled), class_counts=counts)
    usable = [c for c, n in counts.items() if n >= MIN_PER_CLASS]
    if len(labeled) < MIN_LABELED or len(usable) < 2:
        need = []
        if len(labeled) < MIN_LABELED:
            need.append(f"{MIN_LABELED} labeled windows (have {len(labeled)})")
        if len(usable) < 2:
            need.append(f"at least 2 labels with ≥ {MIN_PER_CLASS} windows each (have {len(usable)})")
        rep.reason = "Not enough data: need " + " and ".join(need) + "."
        return rep

    data = labeled[labeled["label"].isin(usable)]
    X, y = model_matrix(data).to_numpy(), data["label"].to_numpy()
    times = data["window_start"].to_numpy()
    n_splits = int(min(MAX_FOLDS, max(2, len(data) // 10)))
    rows = []
    for i, (tr, te) in enumerate(TimeSeriesSplit(n_splits=n_splits, gap=1).split(X), 1):
        if len(set(y[tr])) < 2 or len(te) == 0:
            continue
        clf = RandomForestClassifier(n_estimators=300, random_state=seed, class_weight="balanced").fit(X[tr], y[tr])
        base = DummyClassifier(strategy="most_frequent").fit(X[tr], y[tr])
        pm, pb = clf.predict(X[te]), base.predict(X[te])
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")  # test folds may lack a class seen in training
            rows.append({"fold": i, "train_windows": len(tr), "test_windows": len(te),
                         "train_until": pd.Timestamp(times[tr].max()), "test_from": pd.Timestamp(times[te].min()),
                         "model_accuracy": accuracy_score(y[te], pm), "baseline_accuracy": accuracy_score(y[te], pb),
                         "model_balanced": balanced_accuracy_score(y[te], pm),
                         "baseline_balanced": balanced_accuracy_score(y[te], pb),
                         "baseline_predicts": str(pb[0])})
    if not rows:
        rep.reason = "Not enough data: no time-ordered fold had ≥ 2 labels in its training part yet."
        return rep

    folds = pd.DataFrame(rows)
    rep.status, rep.folds, rep.classes_used = "ok", folds, sorted(usable)
    rep.model_accuracy, rep.baseline_accuracy = folds["model_accuracy"].mean(), folds["baseline_accuracy"].mean()
    rep.model_balanced, rep.baseline_balanced = folds["model_balanced"].mean(), folds["baseline_balanced"].mean()
    dropped = sorted(set(counts) - set(usable))
    if dropped:
        rep.reason = f"Left out (fewer than {MIN_PER_CLASS} windows): {', '.join(dropped)}."

    final = RandomForestClassifier(n_estimators=300, random_state=seed, class_weight="balanced").fit(X, y)
    unl = w.index[w["label"].isna()]
    if len(unl):
        w.loc[unl, "predicted_label"] = final.predict(model_matrix(w.loc[unl]).to_numpy())
    return rep
