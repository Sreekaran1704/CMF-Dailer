# DialSniffer report

Generated from 1390 log lines. Burst gap: 350.0 ms. A path with zero events is reported as *inconclusive (CLI/permission context)*, never as "not working".

## Sessions

| platform | session | lines |
|---|---|---|
| mac | `2985E495-AA17-4CE5-B64A-86827EE1ABD9` | 1390 |

## Startup context

- mac `2985E495` ok: `{"device": "CMF Buds Pro 2", "transport": "blue", "volume_127": 24.000003814697266, "media_apps": [], "warnings": []}`

## Guided run

- Idle drift check (30 s, hands off): **drift**, 153 volume events, net -23.5/127.
- Step size measured live: 7.00/127 per click.
- Fast spins instructed at 7 clicks each.
- Operator heard restore blips: **Yes, blips**.
- Competing media app test: Ready.
- Run complete. Sections done: Idle drift check, Single press, Rotation, one click at a time, Double press, Triple press, Long press, Fast spins, Volume restore test, Now Playing variants, Latency markers, Keyboard media key control, Competing media app.
- **Design-blocking flags:** volume changed on its own during the idle check

| gesture | detected | timed out | skipped | what arrived |
|---|---|---|---|---|
| press_single | 5 | 0 | 0 | pause×3, play×2 |
| rotate_cw | 10 | 0 | 0 | VOLUME_SAME×60, VOLUME_UP×30 |
| rotate_ccw | 10 | 0 | 0 | VOLUME_SAME×60, VOLUME_DOWN×30 |
| press_double | 5 | 0 | 0 | nextTrack×5 |
| press_triple | 1 | 3 | 0 | nextTrack×1 |
| press_long | 0 | 2 | 0 | – |
| fast_cw | 3 | 0 | 0 | VOLUME_SAME×72, VOLUME_UP×33, VOLUME_DOWN×3 |
| fast_ccw | 3 | 0 | 0 | VOLUME_SAME×84, VOLUME_DOWN×42 |
| rotate_cw_restore | 5 | 0 | 0 | VOLUME_UP×5 |
| rotate_ccw_restore | 5 | 0 | 0 | VOLUME_DOWN×5 |
| fast_cw_restore | 2 | 0 | 0 | VOLUME_UP×3 |
| press_single_noaudio | 5 | 0 | 0 | play×3, pause×2 |
| press_single_nonp | 5 | 0 | 0 | play×3, pause×2 |
| keyboard_media_keys | 3 | 0 | 0 | togglePlayPause×3 |
| press_single_competing | 0 | 2 | 0 | – |

## mac / fast_ccw  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **15**, events per burst median 9.0 max 27. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 34 | 15 | 100% | VOLUME_DOWN×17, VOLUME_SAME×17 | 2.0 | 8×14, 7.5×3 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 34 | 15 | 100% | VOLUME_DOWN×17, VOLUME_SAME×17 | 2.0 | 8×14, 7.5×3 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 85 | 15 | 100% | VOLUME_SAME×68, VOLUME_DOWN×17 | 5.0 | 8×14, 7.5×3 | – / – | – / – | 0 |
| `remote_command` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / fast_cw  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **10**, events per burst median 9.0 max 18. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 24 | 10 | 100% | VOLUME_SAME×12, VOLUME_UP×11, VOLUME_DOWN×1 | 2.0 | 8×9, 7.5×3 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 24 | 10 | 100% | VOLUME_SAME×12, VOLUME_UP×11, VOLUME_DOWN×1 | 2.0 | 8×9, 7.5×3 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 60 | 10 | 100% | VOLUME_SAME×48, VOLUME_UP×11, VOLUME_DOWN×1 | 5.0 | 8×9, 7.5×3 | – / – | – / – | 0 |
| `remote_command` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / fast_cw_restore  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **9**, events per burst median 1.0 max 1. Markers: 0. Restores: 9, self-echo events: 144.  
Context: now_playing=playing, silent_audio=on, restore=off/on, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.virtual_main` | fired | 9 | 9 | 100% | VOLUME_UP×9 | 1.0 | 7.5×9 | – / – | – / – | 0 |
| `coreaudio.scalar_ch1` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |
| `remote_command` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `coreaudio.scalar_ch1`: listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127
- `coreaudio.scalar_ch2`: listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127
- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / idle_drift  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **17**, events per burst median 9.0 max 9. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 34 | 17 | 100% | VOLUME_SAME×17, VOLUME_DOWN×10, VOLUME_UP×7 | 2.0 | 8×15, 7.5×1, 7×1 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 34 | 17 | 100% | VOLUME_SAME×17, VOLUME_DOWN×10, VOLUME_UP×7 | 2.0 | 8×15, 7.5×1, 7×1 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 85 | 17 | 100% | VOLUME_SAME×68, VOLUME_DOWN×10, VOLUME_UP×7 | 5.0 | 8×15, 7.5×1, 7×1 | – / – | – / – | 0 |

## mac / keyboard_media_keys  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **3**, events per burst median 1.0 max 1. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `remote_command` | fired | 3 | 3 | 100% | togglePlayPause×3 | 1.0 | – | – / – | – / – | 0 |
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / press_double  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **5**, events per burst median 1.0 max 1. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `remote_command` | fired | 5 | 5 | 100% | nextTrack×5 | 1.0 | – | – / – | – / – | 0 |
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / press_long  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **0**, events per burst median – max –. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `remote_command` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `remote_command`: needs Now Playing ownership (now_playing=playing, silent_audio=on); another app may hold Now Playing, or a bare CLI binary launched from a terminal may not be eligible (retry from a .app bundle)
- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / press_single  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **5**, events per burst median 1.0 max 1. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `remote_command` | fired | 5 | 5 | 100% | pause×3, play×2 | 1.0 | – | – / – | – / – | 0 |
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / press_single_competing  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **0**, events per burst median – max –. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `remote_command` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `remote_command`: needs Now Playing ownership (now_playing=playing, silent_audio=on); another app may hold Now Playing, or a bare CLI binary launched from a terminal may not be eligible (retry from a .app bundle)
- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / press_single_noaudio  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **5**, events per burst median 1.0 max 1. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing/stopped, silent_audio=off/on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `remote_command` | fired | 5 | 5 | 100% | play×3, pause×2 | 1.0 | – | – / – | – / – | 0 |
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / press_single_nonp  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **5**, events per burst median 1.0 max 1. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing/stopped, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `remote_command` | fired | 5 | 5 | 100% | play×3, pause×2 | 1.0 | – | – / – | – / – | 0 |
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / press_triple  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **1**, events per burst median 1.0 max 1. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `remote_command` | fired | 1 | 1 | 100% | nextTrack×1 | 1.0 | – | – / – | – / – | 0 |
| `coreaudio.virtual_main` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch1` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / rotate_ccw  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **10**, events per burst median 9.0 max 9. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 20 | 10 | 100% | VOLUME_DOWN×10, VOLUME_SAME×10 | 2.0 | 7×10 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 20 | 10 | 100% | VOLUME_DOWN×10, VOLUME_SAME×10 | 2.0 | 7×10 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 50 | 10 | 100% | VOLUME_SAME×40, VOLUME_DOWN×10 | 5.0 | 7×10 | – / – | – / – | 0 |
| `remote_command` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / rotate_ccw_restore  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **5**, events per burst median 1.0 max 1. Markers: 0. Restores: 5, self-echo events: 80.  
Context: now_playing=playing, silent_audio=on, restore=on, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.virtual_main` | fired | 5 | 5 | 100% | VOLUME_DOWN×5 | 1.0 | 7.5×5 | – / – | – / – | 0 |
| `coreaudio.scalar_ch1` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |
| `remote_command` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `coreaudio.scalar_ch1`: listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127
- `coreaudio.scalar_ch2`: listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127
- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / rotate_cw  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **10**, events per burst median 9.0 max 9. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 20 | 10 | 100% | VOLUME_UP×10, VOLUME_SAME×10 | 2.0 | 7×9, 7.5×1 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 20 | 10 | 100% | VOLUME_UP×10, VOLUME_SAME×10 | 2.0 | 7×9, 7.5×1 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 50 | 10 | 100% | VOLUME_SAME×40, VOLUME_UP×10 | 5.0 | 7×9, 7.5×1 | – / – | – / – | 0 |
| `remote_command` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / rotate_cw_restore  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **5**, events per burst median 1.0 max 1. Markers: 0. Restores: 5, self-echo events: 80.  
Context: now_playing=playing, silent_audio=on, restore=on, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.virtual_main` | fired | 5 | 5 | 100% | VOLUME_UP×5 | 1.0 | 7.5×5 | – / – | – / – | 0 |
| `coreaudio.scalar_ch1` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |
| `coreaudio.scalar_ch2` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |
| `remote_command` | no events (not expected for this gesture) | 0 | – | – | – | – | – | – | – | – |
| `event_tap.sysdefined` | inconclusive (CLI/permission context) | 0 | – | – | – | – | – | – | – | – |

Possible explanations for the inconclusive paths:

- `coreaudio.scalar_ch1`: listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127
- `coreaudio.scalar_ch2`: listener was attached; check the buds were the default output, the dial was set to volume in Nothing X, multipoint didn't route the event to another device, and volume wasn't pinned at 0 or 127
- `event_tap.sysdefined`: Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran

## mac / unlabeled  
<sub>session `2985E495`</sub>

Bursts (≈ gestures): **11**, events per burst median 9.0 max 18. Markers: 0. Restores: 0, self-echo events: 0.  
Context: now_playing=playing, silent_audio=on, restore=off, event_tap=skipped_no_permission, input_monitoring=unknown.

| method | status | events | bursts hit | coverage | raw values | ev/burst med | Δ /127 steps | lat marker med / p95 | lat self-reported med / p95 | in self window |
|---|---|---|---|---|---|---|---|---|---|---|
| `coreaudio.scalar_ch1` | fired | 24 | 11 | 100% | VOLUME_SAME×12, VOLUME_UP×6, VOLUME_DOWN×6 | 2.0 | 8×12 | – / – | – / – | 0 |
| `coreaudio.scalar_ch2` | fired | 24 | 11 | 100% | VOLUME_SAME×12, VOLUME_UP×6, VOLUME_DOWN×6 | 2.0 | 8×12 | – / – | – / – | 0 |
| `coreaudio.virtual_main` | fired | 60 | 11 | 100% | VOLUME_SAME×48, VOLUME_UP×6, VOLUME_DOWN×6 | 5.0 | 8×12 | – / – | – / – | 0 |

## mac: volume step size (/127 units)

Primary path: `coreaudio.virtual_main`. Slow-rotate clicks measured: 20.

- Step per event (median): **7.00/127**, distribution: 7×19, 7.5×1
- Step per click (median burst total, one burst = one slow click): **7.00/127**
- Events per click (median): 1.0
- Steps that are whole /127 units: 95%

Fast spins (instructed click count is in the Guided run section, default 10):

| label | events in spin | total Δ /127 | clicks implied by Δ | events/click | steps seen | merged? |
|---|---|---|---|---|---|---|
| fast_cw | 2 | 15.50 | 2.2 | 0.90 | 7.5×1, 8×1 | no |
| fast_cw | 2 | 16.00 | 2.3 | 0.88 | 8×2 | yes |
| fast_cw | 1 | 7.50 | 1.1 | 0.93 | 7.5×1 | no |
| fast_cw | 1 | 7.50 | 1.1 | 0.93 | 7.5×1 | no |
| fast_cw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_cw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_cw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_cw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_cw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_cw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 3 | 23.50 | 3.4 | 0.89 | 8×2, 7.5×1 | yes |
| fast_ccw | 1 | 7.50 | 1.1 | 0.93 | 7.5×1 | no |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 7.50 | 1.1 | 0.93 | 7.5×1 | no |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |
| fast_ccw | 1 | 8.00 | 1.1 | 0.88 | 8×1 | yes |

*Merged = fewer events than clicks: one event carried several clicks' worth of Δ. If clicks implied by Δ is well under the instructed count, the OS dropped or coalesced clicks entirely.*

## Path summary (whole run)

| platform | method | result |
|---|---|---|
| mac | `coreaudio.virtual_main` | fired |
| mac | `coreaudio.scalar_ch1` | fired |
| mac | `coreaudio.scalar_ch2` | fired |
| mac | `remote_command` | fired |
| mac | `event_tap.sysdefined` | inconclusive (CLI/permission context): Input Monitoring not granted (to DialSniffer.app, or to the terminal that launched the CLI), so the tap never ran |

## Best method per gesture (highest coverage, then lowest marker latency)

| platform | label | method | coverage |
|---|---|---|---|
| mac | fast_ccw | `coreaudio.scalar_ch1` | 100% |
| mac | fast_cw | `coreaudio.scalar_ch1` | 100% |
| mac | fast_cw_restore | `coreaudio.virtual_main` | 100% |
| mac | idle_drift | `coreaudio.scalar_ch1` | 100% |
| mac | keyboard_media_keys | `remote_command` | 100% |
| mac | press_double | `remote_command` | 100% |
| mac | press_single | `remote_command` | 100% |
| mac | press_single_noaudio | `remote_command` | 100% |
| mac | press_single_nonp | `remote_command` | 100% |
| mac | press_triple | `remote_command` | 100% |
| mac | rotate_ccw | `coreaudio.scalar_ch1` | 100% |
| mac | rotate_ccw_restore | `coreaudio.virtual_main` | 100% |
| mac | rotate_cw | `coreaudio.scalar_ch1` | 100% |
| mac | rotate_cw_restore | `coreaudio.virtual_main` | 100% |
| mac | unlabeled | `coreaudio.scalar_ch1` | 100% |

