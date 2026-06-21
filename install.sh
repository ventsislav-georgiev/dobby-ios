#!/usr/bin/env bash
# Build + install Dobby (Release).
#   ./install.sh           build mac app, install to /Applications
#   ./install.sh device    build iOS app, install to the connected iPhone
set -euo pipefail
cd "$(dirname "$0")"

TEAM=V5XV3994L8   # ventsislav.georgiev@live
TARGET="${1:-mac}"

xcodegen generate

if [ "$TARGET" = "device" ]; then
  DD=build-ios
  APP="$DD/Build/Products/Release-iphoneos/Dobby.app"
  xcodebuild -project Dobby.xcodeproj -scheme Dobby -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
    DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build

  # Pick the first connected physical device.
  JSON="${TMPDIR:-/tmp}/dobby-devices.json"
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  UDID=$(jq -r '.result.devices[]
    | select(.connectionProperties.tunnelState != "unavailable")
    | .hardwareProperties.udid' "$JSON" | head -1)
  [ -n "$UDID" ] || { echo "No connected iPhone found (unlock + trust this Mac)."; exit 1; }

  echo "Installing to device $UDID …"
  xcrun devicectl device install app --device "$UDID" "$APP"
  echo "Installed. Launch Dobby from the home screen."
else
  DD=build-mac
  APP="$DD/Build/Products/Release/Dobby.app"
  # macOS Release needs explicit modules OFF (prebuilt FFmpeg headers break them).
  xcodebuild -project Dobby.xcodeproj -scheme Dobby -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO _EXPERIMENTAL_SWIFT_EXPLICIT_MODULES=NO CLANG_ENABLE_EXPLICIT_MODULES=NO \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

  pkill -f "Dobby.app/Contents/MacOS/Dobby" 2>/dev/null || true
  rm -rf /Applications/Dobby.app
  cp -R "$APP" /Applications/Dobby.app
  echo "Installed to /Applications/Dobby.app"
  open /Applications/Dobby.app
fi
