#!/usr/bin/env bash
# Builds Mac Recorder, installs it to /Applications and starts it at login.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null; then
  echo "Swift is missing. Run: xcode-select --install" >&2
  exit 1
fi

./build.sh

APP_NAME="MacRecorder.app"
DEST="/Applications/$APP_NAME"
AGENT="$HOME/Library/LaunchAgents/dev.macrecorder.app.plist"

pkill -x MacRecorder 2>/dev/null || true
rm -rf "$DEST"
cp -R "build/$APP_NAME" "$DEST"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.macrecorder.app</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>$DEST</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

open "$DEST"
echo "Installed. Press Cmd+Shift+9 and allow Screen Recording, Microphone and Camera when asked."
