#!/bin/sh
# Builds DialHack.app with plain swiftc (Command Line Tools only, no Xcode).
#   ./build.sh          build .build/DialHack.app
#   ./build.sh test     build and run the headless Core tests
#   ./build.sh install  build and copy to /Applications (needed for launch at login)
#   ./build.sh release  build and zip it as .build/DialHack.zip, ready to attach to a GitHub Release
# Signed ad-hoc with an identifier-based designated requirement, so Accessibility grants survive rebuilds.
set -e
cd "$(dirname "$0")"
mkdir -p .build
FLAGS="-swift-version 5 -target arm64-apple-macosx14.0"

swiftc $FLAGS $(find Sources/Core -name "*.swift") Tests/main.swift -o .build/CoreTests
.build/CoreTests
[ "$1" = "test" ] && exit 0

swiftc -O $FLAGS -parse-as-library $(find Sources/Core Sources/App -name "*.swift") -o .build/DialHack

APP=.build/DialHack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/DialHack "$APP/Contents/MacOS/DialHack"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
codesign --force --sign - --identifier dev.dialhack.app -r='designated => identifier "dev.dialhack.app"' "$APP"
echo "Built $(pwd)/$APP"

if [ "$1" = "install" ]; then
  pkill -x DialHack 2>/dev/null || true
  # Let the old instance finish quitting (it restores the user's volume) before replacing it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x DialHack >/dev/null || break; sleep 0.3; done
  rm -rf /Applications/DialHack.app
  cp -R "$APP" /Applications/DialHack.app
  echo "Installed /Applications/DialHack.app"
fi

if [ "$1" = "release" ]; then
  rm -f .build/DialHack.zip
  # ditto keeps the bundle's symlinks, permissions and signature intact (plain zip can break them).
  ditto -c -k --keepParent "$APP" .build/DialHack.zip
  echo "Release zip: $(pwd)/.build/DialHack.zip ($(du -h .build/DialHack.zip | cut -f1))"
  shasum -a 256 .build/DialHack.zip
fi
