# Phase 0 Findings: Dial Sniffer

> **macOS: measured** (guided run 2026-10-18, session `2985E495`, full report in [sniffer-report.md](sniffer-report.md)).
> **Android: not run yet.**
> Decisions (2026-10-18): idle "drift" was the dial being handled, not real drift; mode switching uses **double press, then turn** (500 ms window). Press-and-hold (0/10) and wiggle (6/10) retests both failed the 8/10 bar.

## Test conditions (macOS)

- macOS 27.0.1, CMF Buds Pro 2 as the only Bluetooth output (CoreAudio transport `blue`), phone Bluetooth off.
- Sniffer run as `DialSniffer.app` (its own bundle, accessory policy, live main run loop), with silent audio playing and Now Playing set to `playing` by default.
- **Input Monitoring was not granted for this run**, so the CGEventTap path never ran and no latency markers were recorded.
- All 12 guided sections completed. Results per gesture:

| Gesture | Trials | Detected | What arrived |
|---|---|---|---|
| single press | 5 | 5 | `remote_command` play / pause (alternating) |
| one click right / left | 10 / 10 | 10 / 10 | CoreAudio volume, one change per click |
| double press | 5 | 5 | `remote_command` nextTrack |
| triple press | 4 | 1 | `remote_command` nextTrack (probably read as a double) |
| long press | 2 | 0 | nothing |
| fast spin right / left (7 clicks each) | 3 / 3 | 3 / 3 | CoreAudio volume, but clicks were dropped (see below) |
| keyboard F8 (control) | 3 | 3 | `remote_command` togglePlayPause |
| single press, silent audio off | 5 | 5 | `remote_command` play / pause |
| single press, Now Playing off | 5 | 5 | `remote_command` play / pause |
| single press, Spotify/Music playing | 2 | 0 | nothing reached DialSniffer |

## Which capture method fires (macOS)

| Gesture | CoreAudio `virtual_main` | CoreAudio `scalar_ch1/2` | MPRemoteCommandCenter | CGEventTap NX_SYSDEFINED |
|---|---|---|---|---|
| rotate | **fired, 100%** | fired, 100% | no events (not expected) | inconclusive (no Input Monitoring) |
| single press | – | – | **fired, 100%** (`play`/`pause`) | inconclusive (no Input Monitoring) |
| double press | – | – | **fired, 100%** (`nextTrack`) | inconclusive (no Input Monitoring) |
| triple press | – | – | 1 of 4 (`nextTrack`) | inconclusive |
| long press | – | – | inconclusive: nothing arrived | inconclusive |

- **`previousTrack` was never received** in any step. Either no dial gesture is mapped to "skip back" in Nothing X, or the buds don't send it.
- **Long press sends nothing to the Mac.** It's probably mapped to something the buds handle themselves (ANC / voice assistant).
- **Single press arrives as `play` or `pause`, not `togglePlayPause`.** The buds track their own play state and alternate, whatever state we advertise. Phase 1 must treat `play`, `pause` and `togglePlayPause` as the same input.
- **Now Playing ownership:** presses reached DialSniffer with silent audio off and with Now Playing cleared, as long as no other media app was playing. **When Spotify/Music was playing, DialSniffer got no presses**: the playing app wins. Rotation (volume) is unaffected.

## Volume step size and fast spins (macOS)

- **One click = exactly one volume change of 1/16 of the range** (7 or 8 /127 units; macOS rounds 127/16 = 7.94). 20 of 20 slow clicks produced exactly one change.
- The full range is therefore **16 clicks**. From a 50% baseline there are **8 clicks of headroom in each direction**.
- Each real change fires `virtual_main` **5 times** (1 change + 4 `VOLUME_SAME` repeats within about 10 ms), and `scalar_ch1/2` once each. Phase 1 must dedupe by value.
- **Fast spins don't merge into bigger steps. They drop clicks.** Changes never arrived closer than **about 300 ms** apart (median about 520 ms). Six fast spins of 7 clicks came through as 4, 3, 1, 5, 7 and 6 steps. The buds or the AVRCP link rate-limit the dial to roughly **2–3 steps per second**. Direction is always correct (the one spin with a negative total was most likely turned the wrong way).

## Volume restore (the infinite-encoder trick)

- Restore works mechanically: 19 restores, and all 304 echo callbacks were tagged `self`, with **zero leaking** into captures (the feedback-loop guard works).
- **Slow clicks with restore on:** 10 of 10 detected, one event each.
- **Fast spins with restore on collapse:** two spins of about 10 clicks gave only **1 and 2 steps**. Restoring after every click fights the rate limit; the next clicks are lost while the buds re-sync absolute volume.
- **You heard blips** during restore.

**Design consequence:** don't restore after every click. Use a **lazy restore**:
1. Count each change as one rotation step, and keep the real volume where it lands.
2. Restore to 50% only when (a) the dial has been idle for about 1.5 s, or (b) the volume is within 2 steps of 0 or 16.
3. Accept that rotation is limited to about 3 steps/second. Mode actions should be designed per step, not per spin speed.

## Wiggle gesture retest (experimental picker gesture)

`DialSniffer --guided --only wiggle`, 2026-10-18, under DialHack-style lazy restore. Report: [sniffer-report-wiggle.md](sniffer-report-wiggle.md).

- **Detection: 6 of 10** at the 400 ms window, so it **fails the 8/10 bar**. The default picker stays **double press, then turn**.
- **False triggers: 0** in 30 s of normal adjusting (38 clicks), so that part passes.
- Where the 4 misses came from:
  - **3 attempts never produced a reversal at all.** Only one direction arrived (1 trial timed out; 2 had only same-direction clicks). The buds seem to drop the return click when it follows the first one very quickly.
  - **2 attempts reversed too slowly** (1019 and 1064 ms).
- **The detected wiggles had gaps of 301–372 ms**, right on the buds' ~300 ms minimum between steps (Phase 0). So no window can catch a faster wiggle, and the 300 ms window caught 0.
- **Window sweep** (same clicks replayed):

  | window | detected | false triggers |
  |---|---|---|
  | 300 ms | 0 | 0 |
  | 400 ms | 6 | 0 |
  | 500 ms | 6 | 0 |
  | 600 ms | 6 | 1 |
  | 800 ms | 6 | 2 |

  No window reaches 8/10, because the 3 no-reversal attempts can't be recovered by any window.
- Wiggle stays an opt-in setting (Settings → "Open mode picker with"). If you use it, 500 ms gives the same detection as 400 ms with more margin above the ~300 ms floor and still 0 false triggers.

## Stray inputs in everyday use (DialHack log, 2026-10-18 → 2026-10-20)

With DialHack left running in Passthrough for about two days, it logged **22 `PAUSE` presses and 8 single volume-down steps** that weren't deliberate tests. They were spread out roughly once an hour, and were never `PLAY`.
- The `PAUSE`-only pattern fits the buds' **in-ear detection** (taking a bud out sends pause).
- The lone one-step volume changes fit the **dial being nudged** with the case in a pocket or bag. This is the same thing the Phase 0 idle check caught.

Neither is harmful in Passthrough, but in a dial mode a removed bud would act as `PRESS_1` (page down, space, enter digit) and a nudge as a turn. **Mitigation in DialHack:** any dial mode drops back to Passthrough after **5 minutes without dial input** (Settings, 0 = off). Integration-tested: Scroll → Passthrough after the timeout, with the user's volume restored. If ear-detection pauses are still a problem while actively using a mode, turn off in-ear detection in Nothing X.

## Latency

- **Inconclusive.** No markers could be recorded without Input Monitoring. MPRemoteCommandEvent's self-reported timestamp turned out to use a different clock, so it can't be used either.
- Guided reaction times (prompt → event) are dominated by human reaction, so they aren't latency numbers either.
- To measure: grant Input Monitoring and rerun the guided "Latency markers" step. This doesn't block Phase 1.

## Idle drift (the 48 → 40 → 24 question): resolved, not real drift

During the 30 s hands-off check, the volume changed **17 times** between 5 s and 18 s, then stayed put for the last 12 s:

- every change was **exactly one dial step** (1/16), spaced 400–1000 ms apart
- it **reversed direction three times** (up 2, down 6, up 5, down 3)
- **the same pattern appeared before you clicked Start** (11 one-step changes)

That looks like the dial being turned, not the system drifting. Automatic AVRCP volume sync would show up as a single jump to a stored value, not single steps that go back and forth. The earlier 48 → 40 → 24/127 changes between my launches are also whole 1/16 steps, which fits the dial being nudged while the case was handled. **Confirmed:** the case was probably being handled. Not a real drift, so it doesn't block the design. Lazy restore copes with stray turns either way.

## Event tap (media keys path B)

**Inconclusive.** Input Monitoring wasn't granted, so the tap never ran. It doesn't matter for Phase 1, because `MPRemoteCommandCenter` already gets every press that reaches the Mac. Phase 1 needs **Accessibility** instead (to post scroll and key events for mode actions), which is a different permission.

## Inputs available on macOS

| Input | Source | Reliability |
|---|---|---|
| `ROTATE_CW` / `ROTATE_CCW` | CoreAudio volume change, ±1/16 | 100% for slow clicks; fast spins capped at about 3 steps/s |
| `PRESS_1` (single) | `MPRemoteCommandCenter` play / pause / togglePlayPause | 100% while no other media app is playing |
| `PRESS_2` (double) | `MPRemoteCommandCenter` nextTrack | 100% while no other media app is playing |
| `PRESS_3` (previousTrack) | not observed | not available: triple press and press-and-hold both tried as "skip back" |
| long press | – | not available (0/10 as previousTrack; sometimes arrives as play/pause) |

## Recommended capture method

- **macOS rotation:** CoreAudio listener on `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` of the default output. Dedupe repeats, take direction from the sign of the change, and use lazy restore.
- **macOS presses:** `MPRemoteCommandCenter` (play, pause, togglePlayPause, nextTrack, previousTrack), from a real `.app` with Now Playing info set. Silent audio isn't required. In Phase 1 it stays an optional "keep Now Playing" setting for when other apps are idle.
- **macOS mode switching:** the brief's "previous-track press" didn't arrive, so only two press inputs exist. Options:
  - **(a)** Map triple press to "skip back" in Nothing X, if the app allows it. That gives a real `PRESS_3` for mode cycling. Needs a 1-minute retest.
  - **(b)** "Double press, then turn" opens a mode picker. A double press with no turn within about 1 s is `PRESS_2`. Costs about 1 s of delay on every `PRESS_2` action.
  - **(c)** Hold-free toggle: double press always cycles modes, and each mode gets only `PRESS_1`. That breaks the starter table's Press 2 column.
  - **Chosen: (b).**
  - **Retests:** triple press set to "skip back" didn't work (reported by you). Press-and-hold set to "skip back": `DialSniffer --guided --only hold`, session `2A0C1412`, 2026-10-18. **`previousTrack` arrived in 0 of 10 holds.** 6 holds sent nothing; 4 arrived as `play`/`pause`, the same as a single press. Hold is **not reliable** (the bar was 8 of 10), so (b) stays. Report: [sniffer-report-hold.md](sniffer-report-hold.md).
  - **Delay this adds to a plain double press:** DialHack holds every `nextTrack` for the picker window, **1000 ms** by default (adjustable 400–2500 ms in Settings), plus up to about 5 ms of timer slack. That part is exact, by design. The buds' own double-press recognition time comes on top of it and **wasn't measured**: the guided prompt-to-event times (double press median 1433 ms, single press 1475–2735 ms) are dominated by human reaction. A Right Shift marker run (needs Input Monitoring) would measure it.
- **Android:** pending.

## Known limits, stated up front

- ANC and Low Lag gestures never reach the host.
- While another app is actively playing media, presses go to that app, not DialHack. Rotation still works.
- About 3 rotation steps per second is the ceiling on macOS.
