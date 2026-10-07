#!/usr/bin/env bash
set -euo pipefail
pkill -x MacRecorder 2>/dev/null || true
rm -rf /Applications/MacRecorder.app
rm -f "$HOME/Library/LaunchAgents/dev.macrecorder.app.plist"
tccutil reset All dev.macrecorder.app >/dev/null 2>&1 || true
echo "Mac Recorder removed. Your recordings in ~/Movies/Recordings are untouched."
