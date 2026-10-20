#!/bin/sh
# Builds DialSniffer with plain swiftc (works with Command Line Tools only, no Xcode needed).
#   .build/DialSniffer       CLI binary (interactive mode, reads commands on stdin)
#   .build/DialSniffer.app   same binary as an app bundle (guided mode, own TCC identity)
# Signed ad-hoc with an identifier-based designated requirement (not the default cdhash one),
# so an Input Monitoring grant survives rebuilds.
set -e
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  Sources/DialSniffer/*.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist \
  -o .build/DialSniffer
REQ='designated => identifier "dev.dialhack.sniffer"'
codesign --force --sign - --identifier dev.dialhack.sniffer -r="$REQ" .build/DialSniffer

APP=.build/DialSniffer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/DialSniffer "$APP/Contents/MacOS/DialSniffer"
codesign --force --sign - --identifier dev.dialhack.sniffer -r="$REQ" "$APP"
echo "Built $(pwd)/.build/DialSniffer and $(pwd)/$APP"
