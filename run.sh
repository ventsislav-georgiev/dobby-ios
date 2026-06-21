#!/usr/bin/env bash
# Build + run Dobby (macOS). Pass a stream URL to fire the selftest playback path.
#   ./run.sh                 build + launch
#   ./run.sh <stream-url>    build + launch + auto-play <stream-url>, tail selftest log
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Build/Products/Debug/Dobby.app

xcodegen generate
xcodebuild -project Dobby.xcodeproj -scheme Dobby -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

pkill -f "Dobby.app/Contents/MacOS/Dobby" 2>/dev/null || true

if [ "${1:-}" ]; then
  LOG="${TMPDIR:-/tmp}/dobby-selftest.log"; : > "$LOG"
  open --env DOBBY_SELFTEST_URL="$1" --env DOBBY_SELFTEST_LOG="$LOG" "$APP"
  echo "selftest log: $LOG"; tail -f "$LOG"
else
  open "$APP"
fi
