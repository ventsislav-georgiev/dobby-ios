#!/bin/bash
# #637: puts the core package at Vendor/YtCore.xcframework (gitignored), verified against the
# sha256 in core-package.lock. Sources, in order:
#   1. CORE_PKG_ZIP=<path to the asset zip>  (a local copy)
#   2. CORE_PKG_TOKEN                        (download the release asset by tag)
#   3. an already-verified Vendor copy       (its stamp matches the lock)
# Prints only neutral text: never the token, the source repository or release details.
set -euo pipefail
cd "$(dirname "$0")/.."

lock() { sed -n "s/^$1=//p" core-package.lock; }
REPO=$(lock repo) TAG=$(lock tag) ASSET=$(lock asset) SHA=$(lock sha256)
OUT=Vendor/YtCore.xcframework
STAMP="$OUT/.sha256"
die() { echo "fetch-core-package: $*" >&2; exit 1; }

zip="${CORE_PKG_ZIP:-}"
if [ -z "$zip" ] && [ -n "${CORE_PKG_TOKEN:-}" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:?}"' EXIT
  zip="$tmp/$ASSET"
  # gh's own error text names the repository, so it is dropped for a neutral line.
  GH_TOKEN="$CORE_PKG_TOKEN" gh release download "$TAG" --repo "$REPO" \
    --pattern "$ASSET" --output "$zip" >/dev/null 2>&1 \
    || die "download of the core package $TAG failed (token or release)"
fi

if [ -z "$zip" ]; then
  [ "$(cat "$STAMP" 2>/dev/null)" = "$SHA" ] && { echo "fetch-core-package: core package $TAG present"; exit 0; }
  die "no core package $TAG at $OUT. Set CORE_PKG_ZIP to the asset zip, or CORE_PKG_TOKEN to download it."
fi

[ -f "$zip" ] || die "CORE_PKG_ZIP does not point at a file"
got=$(shasum -a 256 "$zip" | awk '{print $1}')
[ "$got" = "$SHA" ] || die "core package sha256 $got does not match core-package.lock ($SHA)"
rm -rf "${OUT:?}"
mkdir -p Vendor
unzip -q "$zip" -d Vendor
find Vendor -name '._*' -delete  # the asset carries AppleDouble files
[ -f "$OUT/Info.plist" ] || die "the asset zip has no YtCore.xcframework at its root"
echo "$SHA" > "$STAMP"
echo "fetch-core-package: core package $TAG verified and unpacked"
