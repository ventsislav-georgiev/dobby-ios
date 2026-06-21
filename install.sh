#!/usr/bin/env bash
# Build + install Dobby (Release).
#   ./install.sh             build mac app, install to /Applications
#   ./install.sh device      build iOS app, install to the connected iPhone
#   ./install.sh testflight  archive iOS app, upload to App Store Connect (TestFlight)
#
# TestFlight prereqs (one-time):
#   1. App record for eu.illegible.dobbyios exists in App Store Connect.
#   2. App Store Connect API key created (Users and Access → Integrations → Keys).
#      Put the AuthKey_<KEYID>.p8 in ~/.appstoreconnect/private_keys/ and export:
#        export ASC_KEY_ID=<KEYID>
#        export ASC_ISSUER_ID=<ISSUER-UUID>
set -euo pipefail
cd "$(dirname "$0")"

TEAM=V5XV3994L8   # ventsislav.georgiev@live
TARGET="${1:-mac}"

xcodegen generate

if [ "$TARGET" = "testflight" ]; then
  : "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API key id)}"
  : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect issuer uuid)}"
  DD=build-ios
  ARCHIVE="$DD/Dobby.xcarchive"
  EXPORT="$DD/export"
  BUILD=$(date +%Y%m%d%H%M)   # monotonic, unique per upload

  # Resolve packages, then strip the illegal underscore from FFmpegKit's
  # libshaderc_combined CFBundleIdentifier — before archive, or ProcessXCFramework
  # extracts the unfixed slice and embed copies it (Xcode 26 rejects underscores).
  xcodebuild -project Dobby.xcodeproj -scheme Dobby \
    -derivedDataPath "$DD/DD" -resolvePackageDependencies
  find "$DD/DD/SourcePackages/checkouts/FFmpegKit" -name Info.plist -path '*.framework/*' | while IFS= read -r p; do
    id="$(plutil -extract CFBundleIdentifier raw "$p" 2>/dev/null)" || continue
    case "$id" in *_*) chmod u+w "$(dirname "$p")" "$p"; plutil -replace CFBundleIdentifier -string "${id//_/-}" "$p" ;; esac
  done

  xcodebuild archive -project Dobby.xcodeproj -scheme Dobby -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD/DD" -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates

  OPTS="${TMPDIR:-/tmp}/dobby-export.plist"
  cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST

  rm -rf "$EXPORT"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$OPTS" -allowProvisioningUpdates

  IPA=$(ls "$EXPORT"/*.ipa | head -1)
  echo "Uploading $IPA (build $BUILD) to TestFlight …"
  xcrun altool --upload-app --type ios --file "$IPA" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "Uploaded. Processing on App Store Connect takes a few minutes before it appears in TestFlight."

elif [ "$TARGET" = "device" ]; then
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
