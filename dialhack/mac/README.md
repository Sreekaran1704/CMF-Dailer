# DialHack: macOS

## Phase 1 app (`DialHack/`)

A menu bar app (no Dock icon) that turns the dial into an input device.

```bash
./DialHack/build.sh           # runs the Core tests, then builds .build/DialHack.app
./DialHack/build.sh install   # also copies it to /Applications (needed for launch at login)
./DialHack/build.sh test      # Core tests only
```

**Using it**
- **Switch modes:** double-press the dial, then turn it within 1 s. A mode picker appears on screen; turn to choose, press once to confirm, double-press to cancel. The menu bar menu works too.
- **Modes:**

  | Mode | Turn | Press | Double press |
  |---|---|---|---|
  | Passthrough | volume (normal) | play/pause | next track |
  | Scroll | scroll | page down | top |
  | Scrub | ←/→ | space | L (+10 s) |
  | Combo Lock | pick digit | enter digit | reset |
  | Macro | choose macro | run | cancel |

- **Volume:** in every mode except Passthrough, the volume is parked at 50% and restored lazily: after 1.5 s of dial idle, or right away near either end. When you leave the mode or quit, your own volume comes back.
- **Feedback:** an on-screen HUD and a system sound on every mode change.
- **Safety:** after 5 minutes without dial input, any mode drops back to Passthrough (adjustable in Settings). This guards against in-ear-detection pauses and dial nudges in a pocket.
- **Status:** `~/Library/Application Support/DialHack/status.json` shows the current mode, output device, and whether Accessibility is granted.
- **Logs:** every recognized input goes to `~/Library/Application Support/DialHack/events.jsonl`, in the schema in `docs/event-schema.md`.
- **Settings:** in the menu (Settings…) or `config.json` in the same folder. Macros are edited there: `shortcut`, `openApp` or `shell`.

**Permissions**
- **Accessibility:** required for any action that posts scroll or key events. Grant it from the menu ("Allow Accessibility…"). The grant survives rebuilds, because the app is signed with an identifier-based requirement.
- Nothing else. Capture uses CoreAudio and MPRemoteCommandCenter, which need no permission.

**Limits (from Phase 0, `docs/findings.md`)**
- Turning is capped at about 3 clicks per second by the buds. Faster spins drop clicks.
- While another app (Spotify, Music, a video tab) is playing, it gets the dial presses, not DialHack. Pause it or use the menu.
- The volume hijack only applies when the output's name contains "CMF" (configurable). Keyboard volume keys still count as dial turns while the buds are the output.

**Layout**
```
Sources/Core/      pure logic, unit tested: Events, GestureRecognizer (normalizer), ModeEngine, VolumeTracker, Config
Sources/App/Capture/  VolumeCapture (CoreAudio + lazy restore), MediaKeyCapture (MPRemoteCommandCenter)
Sources/App/Output/   ActionExecutor (CGEvent), HUD, EventLogger
Sources/App/          Coordinator (wiring), DialHackApp (menu bar + settings)
Tests/main.swift      headless Core tests
```

## Phase 0 sniffer (`sniffer/`)

A command-line logger that runs every macOS capture candidate at once:

- **CoreAudio** listeners on the default output device: `VirtualMainVolume` (`vmvc`), `VolumeScalar` on elements 0/1/2, and mute. It follows default-device changes.
- **MPRemoteCommandCenter**: play, pause, togglePlayPause, stop, next, previous, seek. The sniffer runs as a real `NSApplication` (`.accessory` policy, so no Dock icon) with a live main run loop. It plays looping digital silence through `AVAudioEngine` and sets `MPNowPlayingInfoCenter.playbackState = .playing`, so it holds Now Playing.
- **CGEventTap** (listen-only) for `NX_SYSDEFINED` media-key events. From the keyboard, only Right Shift is observed (it's the latency marker).

### Build

Needs only the Xcode Command Line Tools (macOS 14+).

```bash
./sniffer/build.sh
```

### Guided test (recommended)

```bash
./sniffer/run-guided.sh
```

This opens a floating window that walks you through the whole protocol, ordered by priority: a 30 s idle drift check, single press, one-click rotations, multi-presses, fast spins, the restore test, Now Playing variants, latency markers, a keyboard control run, and an optional competing-app test. Each gesture is detected automatically. The runner switches labels and audio/Now Playing/restore settings itself, resets volume to 50% (tagged as `self`) before each rotation block, and gives up on a gesture after a few misses. Closing the window ends the run early and keeps the results so far. At the end it writes `docs/sniffer-report.md` for this session only.

The `.app` bundle has its own Input Monitoring entry ("DialSniffer"). If permission is missing, the window asks for it and relaunches itself. Rebuilding changes the ad-hoc signature, so macOS may ask again.

Dry run (no window, no gestures, no prompts): `DIALSNIFFER_LOG=/tmp/x.jsonl .build/DialSniffer.app/Contents/MacOS/DialSniffer --guided --headless --fast --no-tap --report /tmp/r.md`

### Interactive run

Run it from a terminal, because it reads commands from stdin:

```bash
./sniffer/.build/DialSniffer
```

Flags: `--no-remote`, `--no-tap` (skips the event tap and its permission prompt), `--no-audio` (no silent audio), `--restore` (start with baseline restore on).

At startup it prints a check: the default output device and its transport, the starting volume in /127 units (with a warning within 10/127 of either end), any running media apps, and a reminder to quit media apps and turn off your phone's Bluetooth.

Type `help` for commands. The main ones: `1`..`8` set the gesture label, `m` or **Right Shift** drops a latency marker, `np on|off`, `audio on|off`, `restore on|off`, `status`, `q`.

Log: `~/Library/Application Support/DialHack/sniffer.jsonl` (override with `DIALSNIFFER_LOG=/path`).

### Permissions

- **Input Monitoring** for the event tap. macOS gives it to the app that launched the binary (Terminal, iTerm, or the Claude app), not to DialSniffer itself. Without `--no-tap`, the sniffer asks for it on first run and logs `event_tap create_failed` if it's missing. The report then marks that path *inconclusive*, not "not working". Grant it in System Settings → Privacy & Security → Input Monitoring, then quit and reopen that terminal app.
- Accessibility is **not** needed for Phase 0 because the tap only listens. Phase 1 needs it to swallow events and post `CGEvent`s.
- CoreAudio and MediaPlayer need no permission.

### Notes

- The binary embeds an `Info.plist` (bundle id `dev.dialhack.sniffer`) and is ad-hoc signed.
- `build.sh` calls `swiftc` directly because SwiftPM's manifest API in this Command Line Tools install (Swift 6.4-dev) fails to link. Phase 1's menu bar app will need a proper `.app` bundle (Xcode, or a script that assembles one).
