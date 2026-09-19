#!/usr/bin/env bash
# Build-time copy of the PWA app shell into Dobby/Shell — the iOS/macOS analogue of
# Android's `:app:copyAppShell` (dobby-android/app/build.gradle:263-294).
#
# A device that has never reached the Pi has no service-worker cache and so no app at
# all. These bytes are what `loadSimulatedRequest` then serves under the Pi's origin
# (BundledShell.swift), with the sub-resources answered by OfflineSchemeHandler on
# `dobby-offline://shell/…`.
#
# The copied set is read out of sw.js's APP_SHELL literal rather than globbed off disk,
# for the same reason Android reads it: globbing would quietly drift from what the
# service worker precaches, and the whole point of the bundle is that the two agree.
#
# Couples the build to a sibling checkout of the dobby repo — ../dobby, or
# DOBBY_PUBLIC_DIR pointing at its Public directory. Deliberate: the two repos ship as
# one app, and a vendored copy here is exactly the drift this exists to prevent.
#
# Output is gitignored (Dobby/Shell/* bar .gitkeep). Idempotent: wipes and rewrites.
#
# Absent sibling checkout: a WARNING and exit 0, not a failure — .github/workflows/testflight.yml
# checks out this repo alone, and failing there would break every release for a feature that
# degrades cleanly. Such a build carries no shell, `BundledShell.root` is nil, and
# `WebContainer.load` falls back to the plain load that "Continue offline" has always done —
# Android's `hasBundledShell()` returning false, one platform over. A Pi-less cold start is
# therefore a locally built app until that workflow gains a dobby checkout. Every OTHER
# failure — a Public dir that is there but wrong — is still fatal, because that one is drift.
set -euo pipefail
# SRCROOT when Xcode runs this as a build phase (xcodegen inlines the script, so $0 is
# a temp path there — same reason scripts/deepen-macos-frameworks.sh reads Xcode's env);
# the path next to the script when a human or Tests/run-checks.sh runs it.
cd "${SRCROOT:-$(dirname "$0")/..}"

PUBLIC_DIR="${DOBBY_PUBLIC_DIR:-$PWD/../dobby/Sources/BookPlayServer/Public}"
SHELL_DIR="$PWD/Dobby/Shell"

if [ ! -d "$PUBLIC_DIR" ]; then
  echo "warning: copy-app-shell: no dobby checkout at $PUBLIC_DIR; this build ships without an app shell and cannot cold-start Pi-less." >&2
  mkdir -p "$SHELL_DIR" && : > "$SHELL_DIR/.gitkeep"
  exit 0
fi

/usr/bin/python3 - "$PUBLIC_DIR" "$SHELL_DIR" <<'PY'
import os, re, shutil, sys

public_dir, shell_dir = sys.argv[1], sys.argv[2]
sw_js = os.path.join(public_dir, "sw.js")
if not os.path.isfile(sw_js):
    sys.exit(f"copy-app-shell: no sw.js at {sw_js} — point DOBBY_PUBLIC_DIR at the dobby repo's Public directory.")

text = open(sw_js, encoding="utf-8").read()
open_at = text.find("const APP_SHELL = [")
close_at = text.find("];", open_at) if open_at >= 0 else -1
if close_at < 0:
    sys.exit(f"copy-app-shell: APP_SHELL literal not found in {sw_js}; this parser needs updating.")

paths = []
for line in text[open_at:close_at].splitlines():
    # Comments inside the array quote real paths (`import('/playsvideo/…')`), so they
    # go before the string literals are read, not after.
    code = re.sub(r"//.*", "", line)
    paths += re.findall(r"['\"]([^'\"]*)['\"]", code)
# library-metadata.json is the one APP_SHELL entry the wrapper must not carry: it is a
# snapshot of the Pi's library, and a stale bundled copy would be worse than none.
seen, shell = set(), []
for p in paths:
    if p.startswith("/") and p != "/library-metadata.json" and p not in seen:
        seen.add(p)
        shell.append(p)
if len(shell) < 10:
    sys.exit(f"copy-app-shell: APP_SHELL parsed as only {len(shell)} entries from {sw_js}; refusing to ship a half-empty shell.")

def source_for(path):
    """APP_SHELL path -> the file under Public that serves it. Two entries are routes
    rather than files on the Pi, resolved the way StaticRoutes.swift resolves them:
    `/` is index.html, and `/playsvideo/assets/bundle.js` is a stable alias for
    whichever hashed `bundle-*.js` is there (StaticRoutes.swift:150)."""
    relative = "index.html" if path == "/" else path[1:]
    source = os.path.join(public_dir, relative)
    if path == "/playsvideo/assets/bundle.js" and not os.path.isfile(source):
        assets = os.path.join(public_dir, "playsvideo/assets")
        hashed = sorted(n for n in os.listdir(assets) if n.startswith("bundle-") and n.endswith(".js"))
        if len(hashed) != 1:
            sys.exit(f"copy-app-shell: expected exactly one playsvideo/assets/bundle-*.js, found {hashed}.")
        source = os.path.join(assets, hashed[0])
    return relative, source

resolved = [(path,) + source_for(path) for path in shell]
# Every miss, not just the first: a shell that boots without one of these is a blank
# page, and the point of reading sw.js is to hear about drift.
missing = [path for path, _, source in resolved if not os.path.isfile(source)]
if missing:
    sys.exit(f"copy-app-shell: sw.js precaches {', '.join(missing)} but {public_dir} has no such file(s) — the shell would boot broken.")

shutil.rmtree(shell_dir, ignore_errors=True)
os.makedirs(shell_dir, exist_ok=True)
open(os.path.join(shell_dir, ".gitkeep"), "w").close()
for _, relative, source in resolved:
    target = os.path.join(shell_dir, relative)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(source, target)
print(f"copy-app-shell: {len(resolved)} APP_SHELL files from {public_dir} -> {shell_dir}")
PY
