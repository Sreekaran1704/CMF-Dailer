# DialHack: Build Brief

## Goal

Build **DialHack**: apps for **macOS** and **Android** that turn the Smart Dial on the **CMF Buds Pro 2** charging case into a general-purpose input device. The dial normally controls volume and media playback. DialHack intercepts those Bluetooth media events and remaps them to custom actions, and logs every interaction for a "fidget telemetry" analytics layer.

## Hardware facts (verified, do not re-research)

- The case dial is configured in the Nothing X app. It is disabled by default.
- Assignable dial functions: volume control (rotate), play/pause, skip forward, skip back, voice assistant, answer/hang up call, mic mute, ANC mode switch, Low Lag Mode.
- Only these reach the host device as standard Bluetooth (AVRCP) events: **volume up/down, play/pause, next track, previous track**. ANC and Low Lag are handled inside the buds and are invisible to the host. Do not rely on them.
- Dial configuration: **rotate = volume**, and **play/pause, skip forward, skip back** assigned to the available press gestures (single, double, triple press or similar).
- The buds support multipoint. Media/volume events go to whichever device is currently the active audio source. Test with only one device connected at a time first.

## Core technique

1. **Volume hijack (infinite encoder):** when a volume change is detected, compute direction (+1/-1), emit a `ROTATE_CW` / `ROTATE_CCW` event, then restore volume to a fixed baseline (about 50%, mid-range so it never gets stuck at min or max). Debounce so our own restore does not register as a user rotation. Include a "passthrough" mode where volume behaves normally.
2. **Media key capture:** intercept play/pause, next, previous and remap them to `PRESS_1`, `PRESS_2`, `PRESS_3` (or whatever mapping the sniffer reveals).
3. **Mode system:** a configurable gesture (e.g., previous-track press) cycles through modes. Each mode maps the 5 inputs to actions.

## Repo layout

```
dialhack/
  mac/          Swift, SwiftUI menu bar app (macOS 14+)
  android/      Kotlin, Jetpack Compose app (minSdk 29)
  analytics/    Python: ingest event logs, fidget analysis, dashboard
  docs/         findings.md (sniffer results), event-schema.md
```

## Shared event schema (both platforms log this, JSON Lines)

```json
{"ts": "2026-10-18T14:03:22.481Z", "platform": "mac|android", "source": "volume|media_key",
 "raw": "VOLUME_UP|PLAY_PAUSE|NEXT|PREV|...", "event": "ROTATE_CW|ROTATE_CCW|PRESS_1|PRESS_2|PRESS_3",
 "mode": "scrub", "action": "scroll_down", "latency_ms": 42, "session_id": "uuid"}
```

Store locally (macOS: `~/Library/Application Support/DialHack/events.jsonl`; Android: Room/SQLite with JSONL export).

---

## Phase 0: Dial Sniffer (do this first, then STOP and report)

Learn exactly what each platform receives. Build a minimal logger on each platform that tries **every** capture method below in parallel and records which ones fire for each dial gesture, with timestamps.

### macOS candidates
- **Volume:** CoreAudio property listener on the default output device (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` / `kAudioDevicePropertyVolumeScalar`, both master and per-channel). Also listen for default-device changes.
- **Media keys path A:** `MPRemoteCommandCenter` handlers (play, pause, togglePlayPause, nextTrack, previousTrack) with `MPNowPlayingInfoCenter` set so the app becomes the Now Playing app. Test whether this requires actually playing (silent) audio.
- **Media keys path B:** `CGEventTap` for `NX_SYSDEFINED` events (subtype 8, media key codes). Requires Accessibility permission. Test whether Bluetooth headset presses arrive here or only keyboard media keys.

### Android candidates
- **Volume path A:** `ContentObserver` on `Settings.System` plus a receiver for `android.media.VOLUME_CHANGED_ACTION`, reading `STREAM_MUSIC` via `AudioManager`.
- **Volume path B:** an active `MediaSessionCompat` with a `VolumeProviderCompat` (remote volume). Test whether headset-originated volume changes are routed to `onAdjustVolume` (ideal: direction without changing actual volume).
- **Media keys path A:** `MediaSessionCompat.Callback.onMediaButtonEvent` from a foreground service holding an active session (play a looping silent track to stay the preferred media session).
- **Media keys path B:** `AccessibilityService` with `FLAG_REQUEST_FILTER_KEY_EVENTS`. Test whether Bluetooth AVRCP keys are visible here (they may not be).

### Sniffer test protocol
For each platform, perform each gesture 10 times: rotate CW, rotate CCW, fast spin CW, and each press gesture. Log raw events. Then produce `docs/findings.md` with:
- Which capture method worked for each gesture, per platform
- Volume step granularity per detent (does one click = one event, or do fast spins merge?)
- Median and p95 latency from physical action to event (rough reference: press a keyboard key at the same time)
- Any side effects (audio blips during restore, conflicts with Spotify/YouTube, feedback loops from the restore)
- Recommended capture method per platform

**Stop after Phase 0 and show findings.md before building further.**

---

## Phase 1: Remapping engine

Using the winning capture methods:
- Implement the volume hijack with baseline restore, debounce, and passthrough mode.
- Implement the mode system and a settings UI (menu bar on Mac, Compose screen on Android).
- Haptic or audio feedback on mode change (Android vibration; macOS short system sound or HUD overlay).
- Background operation: Mac menu bar app with launch-at-login; Android foreground service with persistent notification.

### Starter modes
| Mode | Rotate CW / CCW | Press 1 | Press 2 |
|---|---|---|---|
| Passthrough | volume (normal) | play/pause | next |
| Scroll | scroll down/up in active window | page down | jump to top |
| Scrub | arrow right/left (video seek) | space | J/L style 10s jump |
| Combo Lock | enter digit sequence | submit | reset |
| Macro | select from a list of shortcuts (shown in HUD) | run selected | cancel |

Mac actions via `CGEvent` posting (needs Accessibility permission). Android actions via `AccessibilityService.dispatchGesture` for scroll, and intents for app launches.

## Phase 2: Fidget Telemetry (analytics/)

- Python ingest of JSONL from both platforms into a single DuckDB or SQLite table.
- Feature engineering per session window (e.g., 5 min): rotations per minute, direction reversals, burst counts, inter-event time distribution, idle gaps, press ratios.
- Unsupervised analysis first (clustering of fidget sessions, anomaly detection for unusually restless windows), then optional labels ("focused" / "stressed" / "bored") for a simple classifier.
- Streamlit dashboard: timeline of fidget intensity, time-of-day heatmap, session clusters.

## Engineering rules

- Phase 0 code can be scrappy; Phase 1+ must have clean module boundaries (capture layer, event normalizer, mode engine, action executor, logger).
- Never post synthetic key or volume events in a way that could loop back into our own capture. Tag self-generated changes and ignore them.
- Write a short README per platform with setup steps and required permissions.
- Ask before adding any network calls. Everything stays local.
- If a capture method is impossible on a platform, say so plainly in findings.md rather than faking it.
