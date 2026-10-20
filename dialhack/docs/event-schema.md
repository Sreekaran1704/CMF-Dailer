# Event schemas

## Phase 1+ event log (both platforms, JSON Lines)

```json
{"ts": "2026-10-18T14:03:22.481Z", "platform": "mac|android", "source": "volume|media_key",
 "raw": "VOLUME_UP|PLAY_PAUSE|NEXT|PREV|...", "event": "ROTATE_CW|ROTATE_CCW|PRESS_1|PRESS_2|PRESS_3",
 "mode": "scrub", "action": "scroll_down", "latency_ms": 42, "session_id": "uuid"}
```

Storage: macOS `~/Library/Application Support/DialHack/events.jsonl`; Android Room/SQLite with JSONL export.

Notes:
- `event` may also be `MODE_PICKER` (double press followed by a turn opened the mode picker).
- `raw` on macOS is one of `VOLUME_UP`, `VOLUME_DOWN`, `PLAY`, `PAUSE`, `TOGGLEPLAYPAUSE`, `NEXT`, `PREV`.
- `latency_ms` is the time from capture to dispatch inside the app. For `PRESS_2`, it includes the 1 s mode-picker hold.
- `steps` appears only when one volume change carried more than one click.
- `mode` is the mode the input happened in (before any mode change it caused).
- `action: picker_turn` is the turn that completed "double press, then turn"; it opens the picker instead of acting.

## Self-report labels (macOS `labels.jsonl`)

```json
{"ts": "...", "platform": "mac", "label": "distracted|focused|stressed|bored",
 "source": "focus_timer_tag|focus_session_end", "focus_session_id": "uuid",
 "start": "...", "end": "...", "session_id": "uuid"}
```
`start`/`end` appear only on `focus_session_end` (the span the rating covers).

## Phase 0 sniffer log

Separate file (`sniffer.jsonl`) so test runs never mix with real telemetry.

| field | type | notes |
|---|---|---|
| `ts` | ISO-8601 UTC | wall clock |
| `platform` | `mac` \| `android` | |
| `kind` | `capture` \| `self` \| `marker` \| `control` | `capture` = candidate dial signal; `self` = echo of our own restore; `marker` = latency reference |
| `method` | string | capture path, e.g. `coreaudio.virtual_main`, `remote_command`, `event_tap.sysdefined`, `broadcast.volume_changed`, `session.onMediaButtonEvent`, `a11y.onKeyEvent` |
| `raw` | string | `VOLUME_UP`, `togglePlayPause`, `MEDIA_NEXT`, `PLAY`, ... |
| `label` | string | gesture being tested, set by the operator |
| `session_id` | uuid | one per sniffer process |
| `mono_ms` | number | monotonic ms (mac: CLOCK_UPTIME_RAW; android: SystemClock.uptimeMillis) |

Optional, by method: `value`, `prev`, `delta`, `self_window`, `at_baseline` (volume); `key_code`, `action`, `repeat`, `event_time`, `latency_ms`, `device` (Android keys); `subtype`, `data1`, `nx_key`, `state`, `cg_ts`, `mach_now` (mac event tap); `event_uptime_s`, `latency_ms` (mac remote commands).
