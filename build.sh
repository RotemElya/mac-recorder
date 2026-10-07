#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/MacRecorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/MacRecorder" \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework Carbon
# The fixed designated requirement keeps the macOS permissions across rebuilds.
codesign --force --sign - -r='designated => identifier "dev.macrecorder.app"' "$APP"
echo "Built $APP"
