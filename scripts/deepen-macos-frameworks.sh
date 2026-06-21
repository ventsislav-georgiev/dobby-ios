#!/bin/bash
# FFmpegKit ships its macOS .framework slices as shallow (iOS-style) bundles.
# Native macOS requires deep (versioned) bundles or the embed/sign phase fails with
# "expected Versions/Current/Resources/Info.plist". Convert in place. Idempotent;
# macOS builds only (iOS keeps shallow). Runs as a pre-build phase.
set -euo pipefail

[ "${PLATFORM_NAME:-macosx}" = "macosx" ] || { echo "deepen: skip ($PLATFORM_NAME)"; exit 0; }

SRC="${BUILD_DIR}/../../SourcePackages/checkouts/FFmpegKit/Sources"
[ -d "$SRC" ] || SRC="${SRCROOT}/build/SourcePackages/checkouts/FFmpegKit/Sources"
[ -d "$SRC" ] || { echo "deepen: no FFmpegKit at $SRC"; exit 0; }

deepen() {
  local fw="$1" name tmp
  name="$(basename "$fw" .framework)"
  [ -d "$fw/Versions" ] && return 0   # already deep
  [ -f "$fw/$name" ] || return 0      # no binary → skip
  tmp="$fw.deep.$$"
  rm -rf "$tmp"; mkdir -p "$tmp/Versions/A/Resources"
  mv "$fw/$name" "$tmp/Versions/A/$name"
  [ -d "$fw/Headers" ] && mv "$fw/Headers" "$tmp/Versions/A/Headers"
  [ -d "$fw/Modules" ] && mv "$fw/Modules" "$tmp/Versions/A/Modules"
  [ -f "$fw/Info.plist" ] && mv "$fw/Info.plist" "$tmp/Versions/A/Resources/Info.plist"
  [ -d "$fw/Resources" ] && { cp -R "$fw/Resources/." "$tmp/Versions/A/Resources/"; rm -rf "$fw/Resources"; }
  ln -s A "$tmp/Versions/Current"
  ln -s "Versions/Current/$name" "$tmp/$name"
  ln -s Versions/Current/Resources "$tmp/Resources"
  [ -d "$tmp/Versions/A/Headers" ] && ln -s Versions/Current/Headers "$tmp/Headers"
  [ -d "$tmp/Versions/A/Modules" ] && ln -s Versions/Current/Modules "$tmp/Modules"
  rm -rf "$fw"; mv "$tmp" "$fw"
  echo "deepen: $name"
}

for xc in "$SRC"/*.xcframework; do
  m="$xc/macos-arm64_x86_64"
  [ -d "$m" ] || continue
  for fw in "$m"/*.framework; do
    [ -d "$fw" ] && deepen "$fw"
  done
done

# Xcode stages each slice into BUILT_PRODUCTS_DIR via ProcessXCFramework (cached
# from earlier builds, so it may be stale-shallow). Deepen those staged copies too,
# since the Embed Frameworks phase copies from here.
for dir in "${BUILT_PRODUCTS_DIR:-}" "${CONFIGURATION_BUILD_DIR:-}"; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  for fw in "$dir"/*.framework; do
    [ -d "$fw" ] && deepen "$fw"
  done
done
echo "deepen: done"
