#!/bin/bash
# #464: build the Mac app as a Developer ID signed, notarized DMG plus the Sparkle appcast that
# updates installed copies (Dobby/Updater.swift). Stops at a local out dir holding
#   Dobby-<build>.dmg   the first install for friends AND the update archive Sparkle fetches
#   appcast.xml         one item, EdDSA-signed, enclosure URL = the feed URL's directory + DMG name
# Uploading them to the update host is not this script's job (that host is configured outside
# this public repo). iOS and iPad stay on TestFlight; nothing here touches them.
#
#   scripts/mac-release.sh [--out <dir>]     the real release, from a clean main
#   scripts/mac-release.sh --unsigned [--out <dir>]
#                                            ad-hoc signed, no notarization, any branch: the
#                                            local check that the DMG and appcast pipeline works
#
# Environment (secrets never go on argv and are never printed):
#   DOBBY_MAC_FEED_URL   https URL of appcast.xml on the update host (required)
#   DOBBY_UPDATE_TOKEN   the update host's header token; read from the login Keychain item
#                        dobby_update_token (the one the APK build uses) when unset
#   ASC_KEY_ID, ASC_ISSUER_ID   App Store Connect API key, as install.sh testflight; the key file
#                        is ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (signed only)
#   SPARKLE_ED_KEY_FILE  private EdDSA key file; default is the login Keychain (generate_keys)
#   DOBBY_SPARKLE_ED_KEY overrides project.yml's committed public key (--unsigned tests only)
#   DOBBY_DEVELOPER_ID   codesign identity for the DMG (default "Developer ID Application")
#
# One-time owner setup:
#   1. Developer ID Application certificate (Account Holder only): Xcode > Settings > Accounts >
#      Manage Certificates > + > Developer ID Application. It lands in the login Keychain.
#   2. Sparkle key: run the generate_keys tool this script prints the path of on a failed run
#      (it stores the private key in the login Keychain and prints the public key), then commit
#      the PUBLIC key as DOBBY_SPARKLE_ED_KEY in project.yml.
#   3. The ASC API key file, as for ./install.sh testflight.
set -euo pipefail

REPO="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
DOBBY="$REPO/../dobby"
GIT=/usr/bin/git
PB=/usr/libexec/PlistBuddy
OPENSSL=/opt/homebrew/bin/openssl
XCODEGEN=/opt/homebrew/bin/xcodegen
TEAM=V5XV3994L8

die() { echo "mac-release: $*" >&2; exit 1; }

UNSIGNED=0 OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unsigned) UNSIGNED=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

# ---- 1. Preconditions ---------------------------------------------------------------------------
[ -x "$OPENSSL" ] || die "no $OPENSSL"
[ -x "$XCODEGEN" ] || die "no $XCODEGEN"
FEED="${DOBBY_MAC_FEED_URL:-}"
[[ $FEED =~ ^https://[^/]+/.+\.xml$ ]] || die "DOBBY_MAC_FEED_URL must be an https URL ending in .xml, with a non-empty host"
PREFIX="${FEED%/*}/"
if [ -z "${DOBBY_UPDATE_TOKEN:-}" ]; then
  DOBBY_UPDATE_TOKEN="$(/usr/bin/security find-generic-password -s dobby_update_token -w 2>/dev/null)" \
    || die "no DOBBY_UPDATE_TOKEN and no dobby_update_token in the Keychain"
fi
# The APK's token shape (43 characters of base64url); anything else locks every Mac out.
[[ $DOBBY_UPDATE_TOKEN =~ ^[A-Za-z0-9_-]{43}$ ]] || die "the update token is not 43 characters of [A-Za-z0-9_-]"
export DOBBY_MAC_FEED_URL="$FEED" DOBBY_UPDATE_TOKEN   # xcodebuild reads both from the environment
# Info.plist's WKAppBoundDomains expands $(DOBBY_PI_HOST); without it the app has no origin (#520).
[[ ${DOBBY_PI_HOST:-} =~ ^[A-Za-z0-9.-]+$ ]] || die "DOBBY_PI_HOST must be a bare host (no scheme, no slash)"
export DOBBY_PI_HOST

if [ "$UNSIGNED" = 0 ]; then
  [ -z "$("$GIT" -C "$REPO" status --porcelain)" ] || die "dobby-ios has uncommitted or untracked changes"
  [ "$("$GIT" -C "$REPO" symbolic-ref --short -q HEAD || true)" = main ] || die "dobby-ios is not on main"
  [ "$("$GIT" -C "$DOBBY" symbolic-ref --short -q HEAD || true)" = main ] || die "dobby (the bundled shell) is not on main"
  [ -z "$("$GIT" -C "$DOBBY" status --porcelain --untracked-files=no)" ] || die "dobby has uncommitted changes"
  : "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API key id)}"
  : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect issuer uuid)}"
  ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  [ -f "$ASC_KEY" ] || die "no App Store Connect key file for ASC_KEY_ID"
  [ -z "${DOBBY_SPARKLE_ED_KEY:-}" ] || die "DOBBY_SPARKLE_ED_KEY overrides the committed public key; unset it for a release"
fi
ED_OVERRIDE=()
[ -z "${DOBBY_SPARKLE_ED_KEY:-}" ] || ED_OVERRIDE=(DOBBY_SPARKLE_ED_KEY="$DOBBY_SPARKLE_ED_KEY")

# ---- 2. Archive and export ----------------------------------------------------------------------
BUILD=$(/bin/date -u +%Y%m%d%H%M)              # the TestFlight numbering: monotonic, minute-unique
MARKETING=$(/bin/date -u +%Y.%-m.%-d)          # what Sparkle's alert names
DD="$REPO/build-mac-release"
OUT="${OUT:-$DD/out/$BUILD}"
ARCHIVE="$DD/Dobby-$BUILD.xcarchive"
/bin/mkdir -p "$OUT"
[ -z "$(/bin/ls -A "$OUT")" ] || die "out dir $OUT is not empty"
echo "mac-release: build $BUILD ($MARKETING), $([ "$UNSIGNED" = 1 ] && echo unsigned || echo signed), out $OUT"

(cd "$REPO" && "$XCODEGEN" generate --quiet)
# macOS Release needs explicit modules off (prebuilt FFmpeg headers break them), as install.sh.
COMMON=(-project "$REPO/Dobby.xcodeproj" -scheme Dobby -configuration Release
  -destination 'generic/platform=macOS' -derivedDataPath "$DD/DD"
  SWIFT_ENABLE_EXPLICIT_MODULES=NO _EXPERIMENTAL_SWIFT_EXPLICIT_MODULES=NO CLANG_ENABLE_EXPLICIT_MODULES=NO
  CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$MARKETING")
if [ "$UNSIGNED" = 1 ]; then
  /usr/bin/xcodebuild archive "${COMMON[@]}" -archivePath "$ARCHIVE" ${ED_OVERRIDE[@]+"${ED_OVERRIDE[@]}"} \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -quiet
  APP="$DD/export/Dobby.app"
  /bin/rm -rf "$DD/export"; /bin/mkdir -p "$DD/export"
  /usr/bin/ditto "$ARCHIVE/Products/Applications/Dobby.app" "$APP"
  /usr/bin/codesign --force --deep --sign - "$APP"
else
  AUTH=(-authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    -allowProvisioningUpdates)
  /usr/bin/xcodebuild archive "${COMMON[@]}" -archivePath "$ARCHIVE" "${AUTH[@]}" DEVELOPMENT_TEAM="$TEAM" -quiet
  OPTS="$DD/export-options.plist"
  /bin/cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
  /bin/rm -rf "$DD/export"
  /usr/bin/xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$DD/export" -exportOptionsPlist "$OPTS" "${AUTH[@]}"
  APP="$DD/export/Dobby.app"
fi

# ---- 3. Assert the app --------------------------------------------------------------------------
[ -d "$APP" ] || die "no $APP"
INFO="$APP/Contents/Info.plist"
plist() { "$PB" -c "Print :$1" "$INFO" 2>/dev/null || true; }
[ "$(plist CFBundleIdentifier)" = eu.illegible.dobbyios ] || die "bundle id is not eu.illegible.dobbyios"
[ "$(plist CFBundleVersion)" = "$BUILD" ] || die "CFBundleVersion is not $BUILD"
[ "$(plist SUFeedURL)" = "$FEED" ] || die "SUFeedURL in the app is not DOBBY_MAC_FEED_URL"
[ "$(plist WKAppBoundDomains:0)" = "$DOBBY_PI_HOST" ] && [ -z "$(plist WKAppBoundDomains:1)" ] || die "WKAppBoundDomains in the app is not exactly DOBBY_PI_HOST"
[ "$(plist DobbyUpdateToken)" = "$DOBBY_UPDATE_TOKEN" ] || die "the app does not carry the update token"
ED_PUB="$(plist SUPublicEDKey)"
[ -n "$ED_PUB" ] || die "no SUPublicEDKey in the app: commit the Sparkle public key as DOBBY_SPARKLE_ED_KEY in project.yml"
[ -s "$APP/Contents/Resources/Shell/index.html" ] || die "no bundled app shell (Shell/index.html): check the ../dobby checkout"
[ "$(/usr/bin/lipo -archs "$APP/Contents/MacOS/Dobby")" = "x86_64 arm64" ] || die "Dobby is not universal (x86_64 arm64)"
/usr/bin/codesign --verify --deep --strict "$APP" || die "codesign --verify failed on the app"
if [ "$UNSIGNED" = 0 ]; then
  SIG="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
  [[ $SIG == *"Authority=Developer ID Application:"* ]] || die "the app is not signed with a Developer ID Application certificate"
  [[ $SIG == *"TeamIdentifier=$TEAM"* ]] || die "the app is not signed by team $TEAM"
  [[ $SIG == *"runtime"* ]] || die "the app is not built with the hardened runtime"
  ENT="$(/usr/bin/codesign -d --entitlements - "$APP" 2>/dev/null || true)"
  [[ $ENT != *get-task-allow* ]] || die "refused: the app carries get-task-allow (a debug signature)"
fi

# ---- 4. DMG: the app plus an Applications link, the standard drag-to-install window -------------
DMG="$OUT/Dobby-$BUILD.dmg"
STAGE="$DD/dmg-stage"
/bin/rm -rf "$STAGE"; /bin/mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/Dobby.app"
/bin/ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -quiet -volname Dobby -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
/bin/rm -rf "$STAGE"

if [ "$UNSIGNED" = 0 ]; then
  /usr/bin/codesign --sign "${DOBBY_DEVELOPER_ID:-Developer ID Application}" --timestamp "$DMG"
  echo "mac-release: notarizing (a few minutes)"
  RESULT="$(/usr/bin/xcrun notarytool submit "$DMG" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --output-format json)" || die "notarytool submit failed"
  STATUS="$(printf '%s' "$RESULT" | /usr/bin/plutil -extract status raw - 2>/dev/null || true)"
  if [ "$STATUS" != Accepted ]; then
    ID="$(printf '%s' "$RESULT" | /usr/bin/plutil -extract id raw - 2>/dev/null || true)"
    die "notarization status '$STATUS'; see: xcrun notarytool log $ID --key ... --key-id ... --issuer ..."
  fi
  /usr/bin/xcrun stapler staple "$DMG"
  /usr/bin/xcrun stapler validate "$DMG"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "$DMG" \
    || die "Gatekeeper refuses the DMG"
fi

# ---- 5. Appcast ---------------------------------------------------------------------------------
SPARKLE_BIN="$DD/DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "no Sparkle tools at $SPARKLE_BIN"
KEYARG=()
[ -z "${SPARKLE_ED_KEY_FILE:-}" ] || KEYARG=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
# One item, no deltas: a client only ever needs the newest build. A private key that does not
# match the app's SUPublicEDKey only gets a generate_appcast WARNING (measured), so the check
# below is what refuses it.
"$SPARKLE_BIN/generate_appcast" ${KEYARG[@]+"${KEYARG[@]}"} --download-url-prefix "$PREFIX" \
  --maximum-deltas 0 --maximum-versions 1 -o "$OUT/appcast.xml" "$OUT" \
  || die "generate_appcast failed (no key? run $SPARKLE_BIN/generate_keys once, see the header)"

# Independent check of what a client will verify: the enclosure is this DMG, its size, and an
# EdDSA signature over its bytes that verifies against the public key the app carries.
read -r A_VER A_URL A_LEN A_SIG < <(/usr/bin/python3 - "$OUT/appcast.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(sys.argv[1]).getroot().findall("./channel/item")
assert len(items) == 1, "expected one appcast item, found %d" % len(items)
e = items[0].find("enclosure")
print(items[0].findtext(S + "version"), e.get("url"), e.get("length"), e.get(S + "edSignature"))
EOF
)
[ "$A_VER" = "$BUILD" ] || die "appcast sparkle:version is '$A_VER', not $BUILD"
[ "$A_URL" = "${PREFIX}Dobby-$BUILD.dmg" ] || die "appcast enclosure URL is not the feed directory plus the DMG name"
[ "$A_LEN" = "$(/usr/bin/stat -f %z "$DMG")" ] || die "appcast length is not the DMG size"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$ED_PUB" | /usr/bin/base64 -D; } > "$TMP/pub.der"
printf '%s' "$A_SIG" | /usr/bin/base64 -D > "$TMP/sig"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/pub.der" -keyform DER -rawin -in "$DMG" -sigfile "$TMP/sig" >/dev/null \
  || die "the appcast's EdDSA signature does not verify against the app's SUPublicEDKey"

echo "mac-release: done, $OUT holds Dobby-$BUILD.dmg and appcast.xml (signature verified against the app's key)"
[ "$UNSIGNED" = 0 ] || echo "mac-release: UNSIGNED build, for local checks only; never publish it"
