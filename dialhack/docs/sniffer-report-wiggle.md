# DialSniffer report

Generated from 683 log lines. Burst gap: 350.0 ms. A path with zero events is reported as *inconclusive (CLI/permission context)*, never as "not working".

## Sessions

| platform | session | lines |
|---|---|---|
| mac | `8C0E7B0E-9187-4A32-9834-008D14EF3BCC` | 683 |

## Startup context

- mac `8C0E7B0E` ok: `{"device": "CMF Buds Pro 2", "transport": "blue", "volume_127": 55.880001068115234, "media_apps": [], "warnings": []}`

## Guided run

- Wiggle retest (400 ms window): detected **6 of 10**, false triggers **0** in 30 s of normal adjusting (38 clicks): **fail**.
- Run complete. Sections done: Wiggle retest.

| gesture | detected | timed out | skipped | what arrived |
|---|---|---|---|---|
| wiggle | 9 | 1 | 0 | VOLUME_SAME×90, VOLUME_DOWN×24, VOLUME_UP×21 |

## Wiggle retest

- Intentional wiggle attempts: 10; first reversal gap per attempt (ms): 301, 345, 347, 347, 371, 372, 1019, 1064
- Gap median 359 ms, min 301, max 1064.
- Normal-adjusting segment: 38 clicks.

| window | detected (of 10) | false triggers (normal adjusting) | passes 8/10 and ≤ 1 |
|---|---|---|---|
| 300 ms | 0 | 0 | no |
| 400 ms (default) | 6 | 0 | no |
| 500 ms | 6 | 0 | no |
| 600 ms | 6 | 1 | no |
| 800 ms | 6 | 2 | no |

## mac / guided_pause  
<sub>session `8C0E7B0E`</sub>

Bursts (≈ gestures): **1**, events per burst median 9.0 max 9. Markers: 0. Restores: 3, self-echo events: 24.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=disabled_by_flag, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 2 | 1 | 100% | VOLUME_UP×1, VOLUME_SAME×1 | 2.0 | 7×1 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 2 | 1 | 100% | VOLUME_UP×1, VOLUME_SAME×1 | 2.0 | 7×1 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 5 | 1 | 100% | VOLUME_SAME×4, VOLUME_UP×1 | 5.0 | 7×1 | – / – | – / – | 0 |

## mac / unlabeled  
<sub>session `8C0E7B0E`</sub>

Bursts (≈ gestures): **1**, events per burst median 1.0 max 1. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=disabled_by_flag, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `remote_command` | fired | 1 | 1 | 100% | togglePlayPause×1 | 1.0 | – | – / – | – / – | 0 |

## mac / wiggle  
<sub>session `8C0E7B0E`</sub>

Bursts (≈ gestures): **13**, events per burst median 9.0 max 18. Markers: 0. Restores: 9, self-echo events: 72.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=disabled_by_flag, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 34 | 13 | 100% | VOLUME_SAME×17, VOLUME_UP×9, VOLUME_DOWN×8 | 2.0 | 7.5×9, 8×8 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 34 | 13 | 100% | VOLUME_SAME×17, VOLUME_UP×9, VOLUME_DOWN×8 | 2.0 | 7.5×9, 8×8 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 85 | 13 | 100% | VOLUME_SAME×68, VOLUME_UP×9, VOLUME_DOWN×8 | 5.0 | 7.5×9, 8×8 | – / – | – / – | 0 |

## mac / wiggle_free  
<sub>session `8C0E7B0E`</sub>

Bursts (≈ gestures): **26**, events per burst median 9.0 max 36. Markers: 0. Restores: 1, self-echo events: 8.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=disabled_by_flag, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 76 | 26 | 100% | VOLUME_SAME×38, VOLUME_DOWN×19, VOLUME_UP×19 | 2.0 | 8×33, 7×3, 7.5×2 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 76 | 26 | 100% | VOLUME_SAME×38, VOLUME_DOWN×19, VOLUME_UP×19 | 2.0 | 8×33, 7×3, 7.5×2 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 190 | 26 | 100% | VOLUME_SAME×152, VOLUME_DOWN×19, VOLUME_UP×19 | 5.0 | 8×33, 7×3, 7.5×2 | – / – | – / – | 0 |

## mac: volume step size (/127 units)

Primary path: `coreaudio.virtual_main`. Slow-rotate clicks measured: 0.

- Step per event (median): **–/127**, distribution: –
- Step per click (median burst total, one burst = one slow click): **–/127**
- Events per click (median): –

No fast-spin data (label `fast_cw`). Merging: inconclusive (CLI/permission context).

## Path summary (whole run)

| platform | method | result |
|---|---|---|
| mac | `coreaudio.virtual_main` | fired |
| mac | `coreaudio.scalar_ch1` | fired |
| mac | `coreaudio.scalar_ch2` | fired |
| mac | `remote_command` | fired |
| mac | `event_tap.sysdefined` | inconclusive (CLI/permission context): disabled with --no-tap |

## Best method per gesture (highest coverage, then lowest marker latency)

| platform | label | method | coverage |
|---|---|---|---|
| mac | guided_pause | `coreaudio.scalar_ch1` | 100% |
| mac | unlabeled | `remote_command` | 100% |
| mac | wiggle | `coreaudio.scalar_ch1` | 100% |
| mac | wiggle_free | `coreaudio.scalar_ch1` | 100% |

