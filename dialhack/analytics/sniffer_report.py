#!/usr/bin/env python3
"""Summarize DialSniffer JSONL logs (mac and/or android) into the tables docs/findings.md needs.

Usage:
    python3 analytics/sniffer_report.py LOG.jsonl [LOG2.jsonl ...] [--session ID] [--burst-gap 350] > docs/sniffer-report.md

Standard library only. Reads local files, writes markdown to stdout.

How it counts:
  * Only kind == "capture" events are dial candidates. Key "up" events are counted separately so
    a press isn't double-counted.
  * Within each (platform, session, label) segment, capture events from all methods are grouped
    into bursts: a gap longer than --burst-gap ms starts a new burst. One burst ~= one physical
    gesture (or one continuous fast spin). Coverage = share of bursts in which a method fired.
  * Latency uses markers (Right Shift / stdin `m` on mac, MARK button on android): for each marker,
    the first event from each method within [-100, +1500] ms.
  * A capture path with zero events is never reported as "not working": it is
    "inconclusive (CLI/permission context)", with the permission or context that could explain it.
  * Volume step size is measured in /127 units (AVRCP absolute volume) on the primary volume path.
    Slow rotate labels give the step per click; fast_cw tells whether fast spins merge clicks.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter, defaultdict

MARKER_WINDOW = (-100.0, 1500.0)
INCONCLUSIVE = "inconclusive (CLI/permission context)"

# Every capture path each sniffer runs, and which gestures it could plausibly see.
EXPECTED = {
    "mac": {
        "coreaudio.virtual_main": "rotate",
        "coreaudio.scalar_ch1": "rotate",
        "coreaudio.scalar_ch2": "rotate",
        "remote_command": "press",
        "event_tap.sysdefined": "any",
    },
    "android": {
        "broadcast.volume_changed": "rotate",
        "settings_observer": "rotate",
        "session.volumeProvider.onAdjustVolume": "rotate",
        "session.onMediaButtonEvent": "press",
        "session.callback": "press",
        "media_button_receiver.intent": "press",
        "a11y.onKeyEvent": "any",
        "activity.dispatchKeyEvent": "any",
    },
}
PRIMARY_VOLUME = {
    "mac": ["coreaudio.virtual_main", "coreaudio.scalar_ch1", "coreaudio.scalar_main"],
    "android": ["broadcast.volume_changed", "settings_observer"],
}
SLOW_ROTATE = ("rotate_cw", "rotate_ccw")
FAST_ROTATE = ("fast_cw", "fast_ccw")


def gesture_kind(label):
    if label.startswith(("rotate", "fast")):
        return "rotate"
    if label.startswith("press") or label == "keyboard_media_keys":
        return "press"
    return None  # idle / unlabeled / custom: zero events are expected


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def med(values):
    return statistics.median(values) if values else None


def fmt(v, nd=0):
    if v is None:
        return "–"
    return f"{v:.{nd}f}"


def is_noise(e):
    """NX_SYSDEFINED subtype 7 is mouse-button bookkeeping, not media keys."""
    return e.get("method") == "event_tap.sysdefined" and e.get("subtype") == 7


def is_release(e):
    return e.get("action") == "up" or e.get("state") == "up"


# --------------------------------------------------------------------------- loading + context


def load(paths, session=None):
    events = []
    for path in paths:
        with open(path) as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    print(f"warning: {path}:{n} is not valid JSON, skipped", file=sys.stderr)
                    continue
                if session and e.get("session_id") != session:
                    continue
                if is_noise(e):
                    continue
                events.append(e)
    events.sort(key=lambda e: (e.get("platform", ""), e.get("session_id", ""), float(e.get("mono_ms", 0))))
    attach_context(events)
    return events


def attach_context(events):
    """Replay control events and stamp each event with the sniffer state at that moment (`_ctx`)."""
    ctx, key = {}, None
    for e in events:
        k = (e.get("platform"), e.get("session_id"))
        if k != key:
            ctx, key = {}, k
        m, raw = e.get("method"), e.get("raw")
        if e.get("kind") == "control":
            if m == "coreaudio.device":
                ctx["listening"] = tuple(e.get("listening") or ())
                ctx["transport"] = e.get("transport")
            elif m == "event_tap.permissions":
                ctx["input_monitoring"] = e.get("input_monitoring")
            elif m == "event_tap" and raw in ("started", "create_failed", "disabled_by_flag", "skipped_no_permission"):
                ctx["event_tap"] = raw
            elif m == "remote_command":
                ctx["remote_command"] = raw
            elif m == "now_playing":
                ctx["now_playing"] = e.get("state") or raw
            elif m == "silent_audio":
                ctx["silent_audio"] = raw
            elif m == "restore":
                ctx["restore"] = raw
            elif m == "a11y":
                ctx["a11y"] = raw
            elif m == "volume_mode":
                ctx["volume_mode"] = raw
            elif m == "service":
                ctx["service"] = raw
            elif m == "startup_check":
                ctx["media_apps"] = tuple(e.get("media_apps") or ())
        e["_ctx"] = dict(ctx)


def segments(events):
    seg = defaultdict(list)
    for e in events:
        seg[(e.get("platform", "?"), e.get("session_id", "?"), e.get("label", "unlabeled"))].append(e)
    return seg


def ctx_sets(evts):
    out = defaultdict(set)
    for e in evts:
        for k, v in e["_ctx"].items():
            out[k].add(v)
    return out


def show(s, key, default="unknown"):
    vals = s.get(key)
    return "/".join(sorted(str(v) for v in vals)) if vals else default


def why_no_events(platform, method, s):
    """Best-guess permission/context explanations for a path that recorded nothing."""
    if platform == "mac":
        if method.startswith("coreaudio."):
            prop = method.split(".", 1)[1]
            listening = set().union(*s["listening"]) if s.get("listening") else set()
            if listening and prop not in listening:
                return "property doesn't exist on this output device, so there was nothing to listen to"
            if s.get("transport") and "blue" not in s["transport"]:
                return f"default output wasn't Bluetooth (transport {show(s, 'transport')}); buds not the active output"
            return ("listener was attached; check the buds were the default output, the dial was set to volume in "
                    "Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127")
        if method == "remote_command":
            if "disabled_by_flag" in s.get("remote_command", ()):
                return "disabled with --no-remote"
            apps = set().union(*s["media_apps"]) if s.get("media_apps") else set()
            hint = f"; media apps running at start: {', '.join(sorted(apps))}" if apps else ""
            return (f"needs Now Playing ownership (now_playing={show(s, 'now_playing')}, silent_audio={show(s, 'silent_audio')}); "
                    "another app may hold Now Playing, or a bare CLI binary launched from a terminal may not be eligible "
                    f"(retry from a .app bundle){hint}")
        if method == "event_tap.sysdefined":
            if "disabled_by_flag" in s.get("event_tap", ()):
                return "disabled with --no-tap"
            if not s.get("event_tap"):
                return "the tap was never started in this session"
            if s.get("event_tap", set()) & {"create_failed", "skipped_no_permission"} or False in s.get("input_monitoring", ()):
                return "Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran"
            return ("tap was running; Bluetooth AVRCP keys may go straight to the Now Playing system and never enter the "
                    "HID event stream. Compare with the keyboard_media_keys control run")
    if platform == "android":
        if "start" not in s.get("service", ()):
            base = "sniffer service may not have been running; "
        else:
            base = ""
        if method == "broadcast.volume_changed":
            return base + "hidden system broadcast; some OEM builds don't deliver it to third-party receivers"
        if method == "settings_observer":
            return base + "volume settings are persisted lazily, so the observer can fire late or not at all"
        if method == "session.volumeProvider.onAdjustVolume":
            if "remote_provider" not in s.get("volume_mode", ()):
                return "the Remote VolumeProvider toggle was off during this segment"
            return base + ("buds probably use AVRCP absolute volume (the Bluetooth stack sets STREAM_MUSIC directly), "
                           "so there's no volume key to route to the session")
        if method in ("session.onMediaButtonEvent", "session.callback"):
            return base + (f"session must be the preferred media-button session (silent_audio={show(s, 'silent_audio')}); "
                           "another app playing media takes priority")
        if method == "a11y.onKeyEvent":
            if "connected" not in s.get("a11y", ()):
                return "accessibility service wasn't enabled in Settings during this segment"
            return "service was connected; AVRCP keys may bypass the input pipeline that accessibility filters see"
        if method == "media_button_receiver.intent":
            return base + "only used when the session is inactive and the system restarts the service via the media button receiver"
        if method == "activity.dispatchKeyEvent":
            return "only sees keys while the sniffer app is in the foreground"
    return "unknown context"


# --------------------------------------------------------------------------- analysis


def bursts(caps, gap):
    out, cur, last = [], [], None
    for e in caps:
        t = float(e["mono_ms"])
        if last is not None and t - last > gap:
            out.append(cur)
            cur = []
        cur.append(e)
        last = t
    if cur:
        out.append(cur)
    return out


def step127(e):
    if isinstance(e.get("step_127"), (int, float)):
        return float(e["step_127"])
    if e.get("platform") == "mac" and isinstance(e.get("delta"), (int, float)):
        return float(e["delta"]) * 127  # logs from before step_127 existed
    return None


def analyze_segment(evts, gap):
    caps = [e for e in evts if e.get("kind") == "capture" and not is_release(e)]
    releases = Counter(e["method"] for e in evts if e.get("kind") == "capture" and is_release(e))
    markers = [float(e["mono_ms"]) for e in evts if e.get("kind") == "marker"]
    bs = bursts(caps, gap)

    methods = defaultdict(lambda: {"events": 0, "bursts": 0, "raw": Counter(), "per_burst": [],
                                   "steps": Counter(), "self_lat": [], "marker_lat": [], "in_self_window": 0})
    for b in bs:
        for m, c in Counter(e["method"] for e in b).items():
            methods[m]["bursts"] += 1
            methods[m]["per_burst"].append(c)
    for e in caps:
        m = methods[e["method"]]
        m["events"] += 1
        m["raw"][e.get("raw", "?")] += 1
        st = step127(e)
        if st:
            m["steps"][round(abs(st), 2)] += 1
        # Only trust self-reported latency in a plausible range (MPRemoteCommandEvent.timestamp
        # turned out not to share ProcessInfo.systemUptime's clock).
        if isinstance(e.get("latency_ms"), (int, float)) and 0 <= e["latency_ms"] < 10_000:
            m["self_lat"].append(float(e["latency_ms"]))
        if e.get("self_window"):
            m["in_self_window"] += 1

    for t in markers:
        seen = set()
        for e in caps:
            dt = float(e["mono_ms"]) - t
            if dt < MARKER_WINDOW[0]:
                continue
            if dt > MARKER_WINDOW[1]:
                break
            if e["method"] not in seen:
                seen.add(e["method"])
                methods[e["method"]]["marker_lat"].append(dt)

    return {
        "caps": caps,
        "bursts": len(bs),
        "burst_sizes": [len(b) for b in bs],
        "markers": len(markers),
        "methods": methods,
        "releases": releases,
        "self_events": sum(1 for e in evts if e.get("kind") == "self"),
        "restores": sum(1 for e in evts if e.get("method") == "restore.set"),
        "ctx": ctx_sets(evts),
    }


def volume_steps(platform, by_label, gap):
    """Step size per click from slow rotations, then merge analysis for fast spins."""
    primary = None
    for cand in PRIMARY_VOLUME.get(platform, []):
        if any(e["method"] == cand and step127(e) for evts in by_label.values() for e in evts):
            primary = cand
            break
    if not primary:
        return None

    def prim(label):
        return [e for e in by_label.get(label, []) if e["method"] == primary and step127(e)]

    slow_event_steps, slow_click_steps, slow_events_per_click, limit_hits = [], [], [], 0
    for label in SLOW_ROTATE:
        ev = prim(label)
        limit_hits += sum(1 for e in ev if e.get("at_limit"))
        slow_event_steps += [abs(step127(e)) for e in ev]
        for b in bursts(ev, gap):
            slow_click_steps.append(sum(abs(step127(e)) for e in b))
            slow_events_per_click.append(len(b))
    per_click = med(slow_click_steps)

    fast = []
    for label in FAST_ROTATE:
        ev = prim(label)
        limit_hits += sum(1 for e in ev if e.get("at_limit"))
        for b in bursts(ev, gap):
            total = sum(abs(step127(e)) for e in b)
            clicks = total / per_click if per_click else None
            fast.append({"label": label, "events": len(b), "total_127": total, "clicks_est": clicks,
                         "steps": Counter(round(abs(step127(e)), 2) for e in b)})

    def integerish(xs):
        return sum(1 for x in xs if abs(x - round(x)) <= 0.15) / len(xs) if xs else None

    return {
        "primary": primary,
        "slow_event_steps": slow_event_steps,
        "per_event": med(slow_event_steps),
        "per_click": per_click,
        "events_per_click": med(slow_events_per_click),
        "slow_clicks": len(slow_click_steps),
        "integerish": integerish(slow_event_steps),
        "fast": fast,
        "limit_hits": limit_hits,
    }


# --------------------------------------------------------------------------- output


def wiggle_triggers(clicks, window_ms):
    """DialHack's wiggle rule: consecutive opposite clicks within the window fire once, then reset."""
    last, triggers, gaps = None, 0, []
    for t, d in clicks:
        if last and last[1] != d:
            gaps.append(t - last[0])
            if t - last[0] <= window_ms:
                triggers += 1
                last = None
                continue
        last = (t, d)
    return triggers, gaps


def wiggle_summary(events, w):
    """Detection vs false triggers for the --only wiggle retest, replayed at several windows."""
    def clicks(label):
        return [(float(e["mono_ms"]), 1 if e["raw"] == "VOLUME_UP" else -1) for e in events
                if e.get("label") == label and e.get("kind") == "capture"
                and e.get("method") == "coreaudio.virtual_main" and e.get("raw") in ("VOLUME_UP", "VOLUME_DOWN")]
    trials = [e for e in events if e.get("method") == "guided.wiggle"]
    free = clicks("wiggle_free")
    if not trials and not free:
        return
    # Per-trial click lists, split by the trial boundaries the runner logged.
    starts = [float(e["mono_ms"]) for e in events if e.get("method") == "label" and e.get("raw") == "wiggle"]
    per_trial = []
    all_w = clicks("wiggle")
    for i, st in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else float("inf")
        per_trial.append([c for c in all_w if st <= c[0] < end])
    gaps = [g for t in per_trial for g in wiggle_triggers(t, 1e9)[1][:1]]
    w("## Wiggle retest\n")
    w(f"- Intentional wiggle attempts: {len(per_trial)}; first reversal gap per attempt (ms): "
      + (", ".join(f"{g:.0f}" for g in sorted(gaps)) or "–"))
    if gaps:
        w(f"- Gap median {statistics.median(gaps):.0f} ms, min {min(gaps):.0f}, max {max(gaps):.0f}.")
    w(f"- Normal-adjusting segment: {len(free)} clicks.\n")
    w("| window | detected (of 10) | false triggers (normal adjusting) | passes 8/10 and ≤ 1 |")
    w("|---|---|---|---|")
    for win in (300, 400, 500, 600, 800):
        det = sum(1 for t in per_trial if wiggle_triggers(t, win)[0] > 0)
        fp = wiggle_triggers(free, win)[0]
        w(f"| {win} ms{' (default)' if win == 400 else ''} | {det} | {fp} | {'yes' if det >= 8 and fp <= 1 else 'no'} |")
    w("")


def guided_summary(events, w):
    """Per-gesture trial outcomes and operator answers from a --guided run."""
    g = [e for e in events if e.get("kind") == "control" and str(e.get("method", "")).startswith("guided")]
    if not g:
        return
    w("## Guided run\n")
    for e in g:
        if e["method"] == "guided" and e["raw"] in ("complete", "ended_early"):
            w(f"- Run {e['raw'].replace('_', ' ')}. Sections done: {', '.join(e.get('sections_done') or []) or 'none'}.")
            if e.get("flags"):
                w(f"- **Design-blocking flags:** {'; '.join(e['flags'])}")
        elif e["method"] == "guided.idle_result":
            w(f"- Idle drift check ({e.get('seconds')} s, hands off): **{e['raw']}**, {e.get('events')} volume events, "
              f"net {fmt(e.get('step_127_total'), 1)}/127.")
        elif e["method"] == "guided.step_size":
            w(f"- Step size measured live: {fmt(e.get('step_127'), 2)}/127 per click.")
        elif e["method"] == "guided.fast_clicks":
            w(f"- Fast spins instructed at {e.get('clicks')} clicks each.")
        elif e["method"] == "guided.blips":
            w(f"- Operator heard restore blips: **{e['raw']}**.")
        elif e["method"] == "guided.hold_result":
            w(f"- Press-and-hold retest: previousTrack in **{e.get('previous_track')} of {e.get('of')}** holds ({e['raw']}).")
        elif e["method"] == "guided.wiggle_result":
            w(f"- Wiggle retest ({e.get('window_ms')} ms window): detected **{e.get('detected')} of {e.get('of')}**, "
              f"false triggers **{e.get('false_triggers')}** in {e.get('free_seconds')} s of normal adjusting "
              f"({e.get('free_clicks')} clicks): **{e['raw']}**.")
        elif e["method"] == "guided.competing_app":
            w(f"- Competing media app test: {e['raw']}.")
    trials = defaultdict(Counter)
    raws = defaultdict(Counter)
    for e in g:
        if e["method"] == "guided.trial":
            trials[e.get("label", "?")][e["raw"]] += 1
            for r in e.get("raws") or []:
                raws[e.get("label", "?")][r] += 1
    if trials:
        w("\n| gesture | detected | timed out | skipped | what arrived |")
        w("|---|---|---|---|---|")
        for label, c in trials.items():
            arrived = ", ".join(f"{k}×{v}" for k, v in raws[label].most_common(4)) or "–"
            w(f"| {label} | {c['detected']} | {c['timeout']} | {c['skipped']} | {arrived} |")
    w("")


def report(events, gap):
    out = []
    w = out.append
    w("# DialSniffer report\n")
    w(f"Generated from {len(events)} log lines. Burst gap: {gap} ms. "
      f"A path with zero events is reported as *{INCONCLUSIVE}*, never as \"not working\".\n")

    sessions = Counter((e.get("platform"), e.get("session_id")) for e in events)
    w("## Sessions\n")
    w("| platform | session | lines |")
    w("|---|---|---|")
    for (p, s), n in sorted(sessions.items()):
        w(f"| {p} | `{s}` | {n} |")
    w("")

    checks = [e for e in events if e.get("method") in ("startup_check", "service")]
    if checks:
        w("## Startup context\n")
        for e in checks:
            keep = {k: e[k] for k in ("device", "transport", "volume_127", "media_apps", "warnings", "music_volume",
                                      "music_max", "bt_outputs", "device_model", "sdk") if k in e}
            w(f"- {e['platform']} `{e['session_id'][:8]}` {e['raw']}: `{json.dumps(keep)}`")
        w("")

    guided_summary(events, w)
    wiggle_summary(events, w)

    segs = segments(events)
    best = defaultdict(dict)
    fired_anywhere = defaultdict(set)
    platform_ctx = defaultdict(lambda: defaultdict(set))

    for (platform, session, label), evts in sorted(segs.items()):
        a = analyze_segment(evts, gap)
        for k, v in a["ctx"].items():
            platform_ctx[platform][k] |= v
        kind = gesture_kind(label)
        if not a["methods"] and not a["markers"] and kind is None:
            continue
        for name in a["methods"]:
            fired_anywhere[platform].add(name)

        w(f"## {platform} / {label}  \n<sub>session `{session[:8]}`</sub>\n")
        sizes = a["burst_sizes"]
        c = a["ctx"]
        w(f"Bursts (≈ gestures): **{a['bursts']}**, events per burst median {fmt(med(sizes), 1)} "
          f"max {max(sizes) if sizes else '–'}. Markers: {a['markers']}. "
          f"Restores: {a['restores']}, self-echo events: {a['self_events']}.  ")
        if platform == "mac":
            w(f"Context: now_playing={show(c, 'now_playing')}, silent_audio={show(c, 'silent_audio')}, "
              f"restore={show(c, 'restore', 'off')}, event_tap={show(c, 'event_tap')}, "
              f"input_monitoring={show(c, 'input_monitoring')}.\n")
        else:
            w(f"Context: service={show(c, 'service')}, silent_audio={show(c, 'silent_audio')}, "
              f"volume_mode={show(c, 'volume_mode')}, a11y={show(c, 'a11y', 'off')}, restore={show(c, 'restore', 'off')}.\n")

        w("| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |")
        w("|---|---|---|---|---|---|---|---|---|---|---|")
        ranked = []
        for name, m in sorted(a["methods"].items()):
            cov = m["bursts"] / a["bursts"] if a["bursts"] else 0
            raw = ", ".join(f"{k}×{v}" for k, v in m["raw"].most_common(4))
            steps = ", ".join(f"{k:g}×{v}" for k, v in m["steps"].most_common(3)) or "–"
            med_ml = pct(m["marker_lat"], 50)
            w(f"| `{name}` | fired | {m['events']} | {m['bursts']} | {cov:.0%} | {raw} | "
              f"{fmt(med(m['per_burst']), 1)} | {steps} | "
              f"{fmt(med_ml)} / {fmt(pct(m['marker_lat'], 95))} | "
              f"{fmt(pct(m['self_lat'], 50))} / {fmt(pct(m['self_lat'], 95))} | {m['in_self_window']} |")
            ranked.append((-cov, med_ml if med_ml is not None else 1e9, name))

        silent = []
        for name, relevance in EXPECTED.get(platform, {}).items():
            if name in a["methods"] or kind is None:
                continue
            status = INCONCLUSIVE if relevance in ("any", kind) else "no events (not expected for this gesture)"
            w(f"| `{name}` | {status} | 0 | – | – | – | – | – | – | – | – |")
            if relevance in ("any", kind):
                silent.append(name)
        if a["releases"]:
            w("\nKey-up events (not counted above): " + ", ".join(f"`{k}`×{v}" for k, v in a["releases"].items()))
        if silent:
            w("\nPossible explanations for the inconclusive paths:\n")
            for name in silent:
                w(f"- `{name}`: {why_no_events(platform, name, c)}")
        w("")
        if ranked:
            ranked.sort()
            best[platform][label] = (ranked[0][2], -ranked[0][0])

    # Volume step size per platform
    by_platform = defaultdict(lambda: defaultdict(list))
    for (platform, _session, label), evts in segs.items():
        by_platform[platform][label] += [e for e in evts if e.get("kind") == "capture"]
    for platform, by_label in sorted(by_platform.items()):
        for evts in by_label.values():
            evts.sort(key=lambda e: float(e["mono_ms"]))
        v = volume_steps(platform, by_label, gap)
        w(f"## {platform}: volume step size (/127 units)\n")
        if not v:
            w(f"No volume events with step data. Volume paths: {INCONCLUSIVE}.\n")
            continue
        w(f"Primary path: `{v['primary']}`. Slow-rotate clicks measured: {v['slow_clicks']}.\n")
        w(f"- Step per event (median): **{fmt(v['per_event'], 2)}/127**, distribution: "
          + (", ".join(f"{k:g}×{n}" for k, n in Counter(round(x, 2) for x in v["slow_event_steps"]).most_common(5)) or "–"))
        w(f"- Step per click (median burst total, one burst = one slow click): **{fmt(v['per_click'], 2)}/127**")
        w(f"- Events per click (median): {fmt(v['events_per_click'], 1)}")
        if v["integerish"] is not None:
            w(f"- Steps that are whole /127 units: {v['integerish']:.0%}"
              + ("" if v["integerish"] >= 0.8 else " (low: the device may not use the 0–127 AVRCP scale)"))
        if v["limit_hits"]:
            w(f"- WARNING: {v['limit_hits']} events hit volume 0 or 127, so those steps were clamped. Re-run nearer 50%.")
        if v["fast"]:
            w("\nFast spins (instructed click count is in the Guided run section, default 10):\n")
            w("| label | events in spin | total Δ /127 | clicks implied by Δ | events/click | steps seen | merged? |")
            w("|---|---|---|---|---|---|---|")
            for f in v["fast"]:
                ratio = f["events"] / f["clicks_est"] if f["clicks_est"] else None
                merged = "–" if ratio is None else ("yes" if ratio < 0.9 else "no")
                steps = ", ".join(f"{k:g}×{n}" for k, n in f["steps"].most_common(3))
                w(f"| {f['label']} | {f['events']} | {f['total_127']:.2f} | {fmt(f['clicks_est'], 1)} | "
                  f"{fmt(ratio, 2)} | {steps} | {merged} |")
            w("\n*Merged = fewer events than clicks: one event carried several clicks' worth of Δ. "
              "If clicks implied by Δ is well under the instructed count, the OS dropped or coalesced clicks entirely.*")
        else:
            w(f"\nNo fast-spin data (label `fast_cw`). Merging: {INCONCLUSIVE}.")
        w("")

    # Path summary across the whole run
    w("## Path summary (whole run)\n")
    w("| platform | method | result |")
    w("|---|---|---|")
    for platform, exp in sorted(EXPECTED.items()):
        if platform not in by_platform:
            continue
        for name in exp:
            if name in fired_anywhere[platform]:
                w(f"| {platform} | `{name}` | fired |")
            else:
                w(f"| {platform} | `{name}` | {INCONCLUSIVE}: {why_no_events(platform, name, platform_ctx[platform])} |")
    w("")

    if best:
        w("## Best method per gesture (highest coverage, then lowest marker latency)\n")
        w("| platform | label | method | coverage |")
        w("|---|---|---|---|")
        for p, labels in sorted(best.items()):
            for label, (name, cov) in sorted(labels.items()):
                w(f"| {p} | {label} | `{name}` | {cov:.0%} |")
        w("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--session", help="only this session_id")
    ap.add_argument("--burst-gap", type=float, default=350.0, help="ms of silence that ends a burst (default 350)")
    args = ap.parse_args()
    events = load(args.logs, args.session)
    if not events:
        sys.exit("no events found")
    print(report(events, args.burst_gap))


if __name__ == "__main__":
    main()
