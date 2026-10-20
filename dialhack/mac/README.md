# DialHack: macOS

## Phase 1 app (`DialHack/`)

A Mac app with a window (Dock icon, can be hidden in Settings) plus a menu bar item, that turns the dial into an input device.

**Design:** a comic book. The window is a cover (yellow sunburst, halftone dots, the "DIALHACK" logo, an issue box, and a starburst showing the current mode), chapter tabs, and a live strip that shows every dial input as a sound effect (TIK! TAK! CLIK!). Pages are chapters with splash headers and speech bubbles. Content sits in panels with thick ink borders and hard shadows, with yellow narration boxes and stickers. The HUD pops up as a comic panel. Fonts are Bangers and Comic Neue, bundled in `Resources/Fonts` (SIL OFL). Tokens and components live in `Sources/App/UI/Comic.swift`. Both themes are printed on textured paper (seeded grain, fibres and mottling tiled from `PaperTexture`, plus a soft vignette). Dark mode is warm, lamp-lit dark paper with cream lettering and near-black ink lines, and big colour fills are knocked back so they don't glow. Chart colours were checked with the data-viz validator in both modes: clusters use blue, orange and magenta, and the timeline uses blue and red. The app icon is drawn by `swift Tools/make_icon.swift Resources/AppIcon.icns Resources/Fonts/Bangers-Regular.ttf`. `DialHack --snapshot <dir> [--data-dir <dir>]` captures every page in both themes, scrolling down each page.

**The window** (menu bar → Open DialHack…, or click the Dock icon):
- **Dial:** the current mode, a mode switcher, an on-screen dial that turns with yours, live input, and status. Status covers the output device, **where your presses go right now**, Accessibility, and a "Check my presses…" test.
- **Focus:** the Focus Timer with buttons (start, pause, "I got distracted", rate), plus recent sessions.
- **The Log (Activity):** today's counts and a searchable log of every dial event.
- **Insights:** native charts and models. Turning intensity, time-of-day heatmap, clusters, restless windows, labels by source, the classifier vs a majority baseline (time-ordered folds; "not enough data" below 30 labels), and labeling windows yourself. It's a Swift port of `analytics/` with identical window features (`Tests/parity.py` checks this); the classifier is k-NN instead of a random forest.
- **Settings:** everything, plus Show in Dock, Launch at login, and the data folder.

**Presses and "Now Playing":** macOS sends dial presses to the app that most recently played media. In dial modes DialHack plays silence to hold that spot. That audio now restarts itself if the route changes (it used to die silently, so presses went to the browser). If another app is actively playing, the window says so and names it.

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
  | Focus Timer | set minutes (idle); just logged while running | start / pause | "I got distracted" tag (paused: end early) |

- **Focus Timer:** the menu bar shows the countdown. At the end, a rating list appears (focused / distracted / stressed / bored): turn to pick, press to save, double-press to skip. Tags and ratings go to `labels.jsonl` and become analytics labels. Auto-return to Passthrough never interrupts a running session.

- **Volume:** macOS changes the volume before DialHack sees a click, so it can't block the change, only undo it. In every mode except Passthrough, DialHack keeps the volume at **your own level** (nudged at most 3 clicks away from silent or max, so the dial can turn both ways) and, by default, **puts it back right after every click**. You may hear a brief blip. Settings → "Put the volume back" → "When the dial stops" instead lets the volume drift while you turn and restores it after 1.5 s idle; that never loses clicks on very fast spins. Leaving the mode or quitting restores your exact volume.
- **Feedback:** an on-screen HUD and a system sound on every mode change.
- **Passthrough** really passes through: DialHack lets go of play/pause entirely, so your keyboard's media keys and the dial's presses control your music or video. That also means double press + turn can't open the picker from Passthrough; switch modes from the menu bar or the window (details in `docs/findings.md`).

- **Safety:** after 5 minutes without dial input, any mode drops back to Passthrough (adjustable in Settings). This guards against in-ear-detection pauses and dial nudges in a pocket.
- **Status:** `~/Library/Application Support/DialHack/status.json` shows the current mode, output device, and whether Accessibility is granted.
- **Logs:** every recognized dial input goes to `~/Library/Application Support/DialHack/events.jsonl` (schema in `docs/event-schema.md`), in every mode including Passthrough, under the mode it happened in. The turn that opens the mode picker is logged too (`action: picker_turn`). DialHack can't see presses that go to another playing app, and it can't tell keyboard volume/media keys from the dial while the buds are the output.
- **Visual check without permissions:** `.build/DialHack.app/Contents/MacOS/DialHack --snapshot <dir> [--data-dir <dir>]` captures the app's own window for every section, light and dark, then quits. Translucent sidebars and the window background don't appear in these captures.
- **Testing without the dial:** launch with `--accept-simulated-input`, then post a `dev.dialhack.simulate` distributed notification with `PLAY`, `NEXT`, `VOLUME_UP` and so on. This is off unless that flag is given.
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
Sources/Core/Insights/  native analytics (log reading, features, labels, k-means, PCA, isolation forest, k-NN)
Sources/App/UI/       the window: Dial, Focus, Activity, Insights, Settings; Snapshot (self-capture check)
Sources/App/          Coordinator (wiring), DialHackApp (window + menu bar scenes)
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
