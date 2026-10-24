#!/usr/bin/env bash
# #326: the one font scan. Prints every font file under <dir>, relative to it, one per
# line, sorted; extensions matched case-insensitively. Prints nothing when there is none.
# Exits non-zero only when <dir> is not a directory; what a font MEANS is the caller's call:
#   - Tests/run-checks.sh fails on any font in the copied Dobby/Shell (empty allowlist),
#     and runs this on a fixture shell to pin the scan itself;
#   - .github/workflows/testflight.yml warns, per file, on the archived Dobby.app and
#     never fails the upload for it.
# App Store Connect rejects an embedded Apple font (ITMS-91182) from 2027-10-01.
# A symlinked font is not listed (find -type f), but its target inside the app is.
set -euo pipefail
cd "${1:?usage: list-font-files.sh <dir>}"
/usr/bin/find . -type f \( -iname '*.woff' -o -iname '*.woff2' -o -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) \
  | /usr/bin/sed 's|^\./||' | LC_ALL=C /usr/bin/sort
