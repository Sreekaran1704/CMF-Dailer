#!/bin/sh
# One-command guided dial test. Opens a floating window that walks you through every gesture,
# then writes docs/sniffer-report.md. Extra arguments are passed to DialSniffer.
set -e
cd "$(dirname "$0")"
[ -d .build/DialSniffer.app ] || ./build.sh
APP="$(pwd)/.build/DialSniffer.app"
DIR="$HOME/Library/Application Support/DialHack"
mkdir -p "$DIR"
MARK="$DIR/.relaunch"

# Saved so a relaunch by macOS itself ("Quit & Reopen" after granting a permission) resumes guided mode.
printf '%s\n' --guided "$@" > "$DIR/.guided-args"

while :; do
  rm -f "$MARK"
  touch "$DIR/.guided-args"
  open -W -n --env DIALSNIFFER_WRAPPED=1 --stdout "$DIR/guided-console.log" --stderr "$DIR/guided-console.log" \
    "$APP" --args --guided "$@"
  # macOS "Quit & Reopen" (after a permission grant) kills the app and restarts it outside of
  # `open -W`, a second or two later. Give it time to come back, then wait for that instance too.
  while :; do
    sleep 4
    pgrep -f "$APP/Contents/MacOS/DialSniffer" >/dev/null || break
    while pgrep -f "$APP/Contents/MacOS/DialSniffer" >/dev/null; do sleep 1; done
  done
  [ -f "$MARK" ] || break
  echo "Relaunching after permission change..."
done
rm -f "$DIR/.guided-args"

# The .app can't read or write ~/Documents (TCC), so the report is built here, for this session only.
ROOT="$(cd ../.. && pwd)"
ONLY=""
prev=""
for a in "$@"; do [ "$prev" = "--only" ] && ONLY="$a"; prev="$a"; done
REPORT="$ROOT/docs/sniffer-report${ONLY:+-$(echo "$ONLY" | tr ',' '-')}.md"
SESSION="$(cat "$DIR/.last-guided-session" 2>/dev/null || true)"
if [ -n "$SESSION" ]; then
  python3 "$ROOT/analytics/sniffer_report.py" "$DIR/sniffer.jsonl" --session "$SESSION" > "$REPORT"
  echo "Guided run finished. Report: $REPORT"
else
  echo "Guided run ended before it started; no report."
fi
