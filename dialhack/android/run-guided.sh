#!/bin/sh
# One-command guided dial test on Android.
# Waits for a phone with USB debugging, installs DialSniffer, opens guided mode, waits for the run to
# finish, pulls the log and writes docs/sniffer-report-android.md.
set -e
cd "$(dirname "$0")"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"
ADB="$ANDROID_HOME/platform-tools/adb"
PKG=dev.dialhack.sniffer
LOG=/sdcard/Android/data/$PKG/files/sniffer.jsonl
OUT="$(pwd)/../docs"

./gradlew -q :sniffer:assembleDebug
echo "Waiting for the phone (plug in USB, allow USB debugging)..."
"$ADB" wait-for-device
echo "Phone connected: $("$ADB" shell getprop ro.product.model | tr -d '\r')"
"$ADB" install -r -t sniffer/build/outputs/apk/debug/sniffer-debug.apk >/dev/null
"$ADB" logcat -c
"$ADB" shell am start -n $PKG/.MainActivity --ez guided true >/dev/null
echo "Guided test is open on the phone. Waiting for it to finish..."
"$ADB" logcat -v raw -s DialSniffer:D | grep -m1 -E '"method":"guided","raw":"(complete|ended_early)"' >/dev/null || true
sleep 2
"$ADB" pull "$LOG" "$OUT/sniffer-android.jsonl" >/dev/null 2>&1 \
  || "$ADB" exec-out run-as $PKG cat "$LOG" > "$OUT/sniffer-android.jsonl"
SESSION=$(grep '"method":"guided","raw":"start"' "$OUT/sniffer-android.jsonl" | tail -1 | sed -E 's/.*"session_id":"([^"]+)".*/\1/')
python3 ../analytics/sniffer_report.py "$OUT/sniffer-android.jsonl" --session "$SESSION" > "$OUT/sniffer-report-android.md"
echo "Report: $OUT/sniffer-report-android.md"
