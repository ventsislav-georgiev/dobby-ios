#!/bin/bash
# FFmpegKit ships its macOS .framework slices as shallow (iOS-style) bundles.
# Native macOS requires deep (versioned) bundles or the embed/sign phase fails with
# "expected Versions/Current/Resources/Info.plist". Convert in place. Idempotent;
# macOS builds only (iOS keeps shallow). Runs as a pre-build phase.
set -euo pipefail

[ "${PLATFORM_NAME:-macosx}" = "macosx" ] || { echo "deepen: skip ($PLATFORM_NAME)"; exit 0; }

SRC="${BUILD_DIR}/../../SourcePackages/checkouts/FFmpegKit/Sources"
[ -d "$SRC" ] || SRC="${SRCROOT}/build/SourcePackages/checkouts/FFmpegKit/Sources"

deepen() {
  local fw="$1" name tmp
  name="$(basename "$fw" .framework)"
  [ -d "$fw/Versions" ] && return 0   # already deep
  [ -f "$fw/$name" ] || { echo "deepen: skip $name (no $name binary)"; return 0; }
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

# Missing checkout only takes out pass 1 (nothing to deepen at its source) —
# passes 2 and 3 still run below, since a populated products/app-bundle dir with no
# checkout is the exact Validate failure state, not a reason to deepen nothing.
if [ -d "$SRC" ]; then
  for xc in "$SRC"/*.xcframework; do
    m="$xc/macos-arm64_x86_64"
    [ -d "$m" ] || continue
    for fw in "$m"/*.framework; do
      [ -d "$fw" ] && deepen "$fw"
    done
  done
else
  echo "deepen: no FFmpegKit at $SRC"
fi

# Xcode stages each slice into BUILT_PRODUCTS_DIR via ProcessXCFramework (cached
# from earlier builds, so it may be stale-shallow). Deepen those staged copies too,
# since the Embed Frameworks phase copies from here.
# TARGET_BUILD_DIR/BUILT_PRODUCTS_DIR/CONFIGURATION_BUILD_DIR commonly resolve to
# the same directory across both passes below — visit each real path once, so one
# shallow framework doesn't get the "no binary" skip logged twice or three times.
# seen is newline-bounded (starts and ends in a newline) so a real path that is an
# exact prefix of another can't false-match the way a space-separated list would.
seen=$'\n'
for dir in "${BUILT_PRODUCTS_DIR:-}" "${CONFIGURATION_BUILD_DIR:-}"; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  real="$(cd "$dir" && pwd -P)"
  case "$seen" in *$'\n'"$real"$'\n'*) continue ;; esac
  seen="$seen$real"$'\n'
  for fw in "$dir"/*.framework; do
    [ -d "$fw" ] && deepen "$fw"
  done
done

# This script has no declared outputs, so the new build system doesn't gate the
# app target's synthesized SPM "Embed Frameworks" copy on it — on a clean build
# that copy can run first, embedding a still-shallow framework straight from $SRC
# above. Whichever way it lands, fix the copy actually inside the app bundle too,
# since that's what Validate inspects.
for dir in "${TARGET_BUILD_DIR:-}" "${BUILT_PRODUCTS_DIR:-}" "${CONFIGURATION_BUILD_DIR:-}"; do
  [ -n "$dir" ] && [ -n "${FRAMEWORKS_FOLDER_PATH:-}" ] || continue
  fdir="$dir/${FRAMEWORKS_FOLDER_PATH:-}"
  [ -d "$fdir" ] || continue
  real="$(cd "$fdir" && pwd -P)"
  case "$seen" in *$'\n'"$real"$'\n'*) continue ;; esac
  seen="$seen$real"$'\n'
  for fw in "$fdir"/*.framework; do
    [ -d "$fw" ] && deepen "$fw"
  done
done
echo "deepen: done"
