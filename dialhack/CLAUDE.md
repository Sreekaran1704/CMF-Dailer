# DialHack

Turn the Smart Dial on the CMF Buds Pro 2 charging case into a general-purpose input device on macOS and Android.

The full build brief (goals, hardware facts, phases, engineering rules) is in [docs/BRIEF.md](docs/BRIEF.md). Read it before changing anything.

## Current status

- **Phase 0 macOS: done** (`docs/findings.md`). Decisions: the idle "drift" was the dial being handled; mode switching is "double press, then turn".
- **Phase 1 macOS: built** (`mac/DialHack`). Core is unit tested (`./build.sh test`). The volume hijack is integration-tested by simulating clicks with `osascript set volume`.
- **Android: sniffer builds (SDK in ~/Library/Android/sdk), guided mode added.** `android/run-guided.sh` waits for a phone; the test hasn't run yet.
- **Phase 2 analytics: built** (`analytics/dialhack_analytics`, `analytics/dashboard.py`, venv at `analytics/.venv`). 11 pytest tests pass on synthetic data; real data is still about 30 mostly-stray events.
- The user does physical actions only and handles git. Never run git commands.

## Layout

```
mac/sniffer/        Phase 0 macOS sniffer (swiftc build.sh; run-guided.sh for the guided test)
mac/DialHack/       Phase 1 macOS menu bar app (swiftc build.sh; Core/ is pure and unit tested)
android/sniffer/    Phase 0 Android sniffer (Gradle module, open android/ in Android Studio)
analytics/          sniffer_report.py (Phase 0); dialhack_analytics/ + dashboard.py (Phase 2, DuckDB + Streamlit)
docs/               BRIEF.md, findings.md, event-schema.md
```

## Rules worth repeating

- No network calls without asking. Everything stays local.
- Self-generated volume/key changes are always tagged and ignored by capture.
- If a capture method can't work on a platform, findings.md says so plainly.

## Toolchain gotchas (this Mac)

- Command Line Tools only (Swift 6.4-dev). SwiftPM's manifest API fails to link, so build with `swiftc` scripts.
- SwiftUI's `@State` (and other SwiftUI macros) won't compile, because the macro plugin is missing. Use `@ObservedObject`/`@Published` or computed `Binding`s.
- Sign ad-hoc with `-r='designated => identifier "<bundle id>"'`, or TCC grants (Input Monitoring, Accessibility) break on every rebuild.
- An `.app` launched via `open` can't write to `~/Documents` (TCC). Write to Application Support instead.
