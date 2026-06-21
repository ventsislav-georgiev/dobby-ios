#!/bin/bash
# FFmpegKit's libshaderc_combined.framework ships a CFBundleIdentifier with an
# underscore (com.kintan.ksplayer.libshaderc_combined). Underscores are illegal
# in CFBundleIdentifier; macOS embed skips validation but iOS embed rejects it:
# "had an invalid CFBundleIdentifier in its Info.plist". Rewrite _ -> - in every
# framework Info.plist (source slices + staged copies). Idempotent. All platforms.
set -euo pipefail

fix() {
  local plist="$1" id new
  [ -f "$plist" ] || return 0
  id="$(plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null)" || return 0
  case "$id" in *_*) ;; *) return 0 ;; esac
  new="${id//_/-}"
  chmod u+w "$plist" 2>/dev/null || true
  if plutil -replace CFBundleIdentifier -string "$new" "$plist" 2>/dev/null; then
    echo "fix-bundle-ids: $id -> $new"
  else
    echo "fix-bundle-ids: SKIP (unwritable) $plist"
  fi
}

# Source xcframework slices (ProcessXCFramework stages from here).
SRC="${BUILD_DIR}/../../SourcePackages/checkouts/FFmpegKit/Sources"
[ -d "$SRC" ] || SRC="${SRCROOT}/build/SourcePackages/checkouts/FFmpegKit/Sources"
if [ -d "$SRC" ]; then
  find "$SRC" -name Info.plist -path '*.framework/*' | while IFS= read -r p; do fix "$p"; done
fi

# Staged copies the Embed Frameworks phase copies from (may be cached-stale).
for dir in "${BUILT_PRODUCTS_DIR:-}" "${CONFIGURATION_BUILD_DIR:-}"; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  find "$dir" -name Info.plist -path '*.framework/*' | while IFS= read -r p; do fix "$p"; done
done
echo "fix-bundle-ids: done"
