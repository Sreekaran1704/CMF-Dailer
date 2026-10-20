# DialSniffer report

Generated from 50 log lines. Burst gap: 350.0 ms. A path with zero events is reported as *inconclusive (CLI/permission context)*, never as "not working".

## Sessions

| platform | session | lines |
|---|---|---|
| mac | `2A0C1412-0D50-4059-9CCE-8DB769B1A421` | 50 |

## Startup context

- mac `2A0C1412` ok: `{"device": "CMF Buds Pro 2", "transport": "blue", "volume_127": 39.6875, "media_apps": [], "warnings": []}`

## Guided run

- Run complete. Sections done: Press-and-hold retest.

| gesture | detected | timed out | skipped | what arrived |
|---|---|---|---|---|
| press_hold | 4 | 6 | 0 | pause×2, play×2 |

## mac / press_hold  
<sub>session `2A0C1412`</sub>

Bursts (≈ gestures): **5**, events per burst median 1.0 max 1. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=disabled_by_flag, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `remote_command` | fired | 5 | 5 | 100% | pause×3, play×2 | 1.0 | – | – / – | – / – | 0 |
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: disabled with --no-tap

## mac: volume step size (/127 units)

No volume events with step data. Volume paths: inconclusive (CLI/permission context).

## Path summary (whole run)

| platform | method | result |
|---|---|---|
| mac | `coreaudio.virtual_main` | inconclusive (CLI/permission context): listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127 |
| mac | `coreaudio.scalar_ch1` | inconclusive (CLI/permission context): listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127 |
| mac | `coreaudio.scalar_ch2` | inconclusive (CLI/permission context): listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127 |
| mac | `remote_command` | fired |
| mac | `event_tap.sysdefined` | inconclusive (CLI/permission context): disabled with --no-tap |

## Best method per gesture (highest coverage, then lowest marker latency)

| platform | label | method | coverage |
|---|---|---|---|
| mac | press_hold | `remote_command` | 100% |

