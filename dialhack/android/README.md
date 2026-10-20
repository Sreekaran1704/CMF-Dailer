# DialHack: Android

## Phase 0 sniffer (`:sniffer` module)

A Compose app plus a foreground service that run every Android capture candidate at once:

- **Volume path A:** a `VOLUME_CHANGED_ACTION` receiver and a `Settings.System` `ContentObserver` (volume keys only), reading `STREAM_MUSIC`.
- **Volume path B:** a `MediaSessionCompat` with a relative `VolumeProviderCompat`, switched on with the "Remote VolumeProvider" toggle. Logs `onAdjustVolume`.
- **Media keys path A:** `MediaSessionCompat.Callback.onMediaButtonEvent` plus the callbacks it derives (`onPlay`, `onSkipToNext`, ...). It plays looping digital silence and takes audio focus to stay the preferred media session (toggleable).
- **Media keys path B:** `KeyAccessibilityService` with `flagRequestFilterKeyEvents`. Logs **only media/volume key codes**, observes without consuming, and logs nothing else.
- Bonus: `Activity.dispatchKeyEvent` while the app is in the foreground.

minSdk 29, targetSdk 35. Package `dev.dialhack.sniffer`.

### Build and install

This Mac has no Android SDK, so the project was written but **never compiled**. Expect to fix small things on the first sync.

1. Open `android/` in Android Studio (it downloads Gradle 8.11.1 and AGP 8.7.3 on first sync; accept any version-upgrade prompts).
2. Plug in the phone with USB debugging on, then Run `sniffer`.

There is no `gradlew` script yet. Android Studio doesn't need one; for command-line builds, run `gradle wrapper` once inside `android/`.

### Use

1. Grant notifications, tap **Start service**.
2. **Accessibility…** → DialSniffer → enable, to turn on path B.
3. Pick a label chip, do the gesture, and tap **MARK** at the same moment (it logs on touch-down).
4. **Export** shares `sniffer.jsonl`, or pull it over USB:
   ```bash
   adb pull /sdcard/Android/data/dev.dialhack.sniffer/files/sniffer.jsonl sniffer-android.jsonl
   ```
   Live view: `adb logcat -s DialSniffer`.

### Permissions

- Notifications (foreground service notification, Android 13+)
- Foreground service, media playback type
- Accessibility service (optional, for path B), granted by hand in Settings
