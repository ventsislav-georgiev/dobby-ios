set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/api-scheme-check"
xcrun swiftc -o "$OUT" \
  Dobby/AppConfig.swift Dobby/Web/ApiSchemeHandler.swift Tests/ApiSchemeHandlerCheck.swift
"$OUT"

OUT0="$(mktemp -d)/app-config-check"
xcrun swiftc -o "$OUT0" Dobby/AppConfig.swift Tests/AppConfigCheck.swift
"$OUT0"

# ServerAddresses.swift is compiled twice: OUT2 without -D DEBUG so the file still compiles
# clean in release configuration (the noServerSeamActive() predicate itself is unconditional,
# only its call site in probe(_:) is #if DEBUG-gated), and OUT3 with -D DEBUG so the
# --expect-no-server run below can actually exercise the guarded call site.
OUT2="$(mktemp -d)/server-addresses-check"
xcrun swiftc -o "$OUT2" \
  Dobby/ServerAddresses.swift Dobby/AppConfig.swift Tests/ServerAddressesCheck.swift
"$OUT2"

OUT3="$(mktemp -d)/server-addresses-check-debug"
xcrun swiftc -D DEBUG -o "$OUT3" \
  Dobby/ServerAddresses.swift Dobby/AppConfig.swift Tests/ServerAddressesCheck.swift
DOBBY_NO_SERVER=1 "$OUT3" --expect-no-server

# Compile-time property with no runtime observable: resolve() reports the same "absent" verdict
# whether the seam call is #if DEBUG-gated or unconditional, and the reason string only reaches
# OSLog, so no assertion above this line can distinguish a shipped guard from a shipped hole.
# A textual check over the source is the only tool that can catch the call site losing its
# DEBUG gate (or a second, ungated call being added elsewhere).
python3 - <<'PY'
import glob
import re
import sys

def assert_gated(call_regex, label, expected_calls=1):
    hits = []
    files = {}
    for path in sorted(glob.glob("Dobby/**/*.swift", recursive=True)):
        with open(path) as f:
            lines = f.readlines()
        files[path] = lines
        for i, l in enumerate(lines):
            stripped = l.strip()
            if stripped.startswith("//"):
                continue
            if re.search(rf"func\s+{label}\b", l):
                continue
            if re.search(call_regex, l):
                hits.append((path, i))

    if len(hits) != expected_calls:
        where = ", ".join(f"{p}:{i + 1}" for p, i in hits)
        sys.stderr.write(f"FAIL: expected {expected_calls} call(s) to {label}() in Dobby/, "
                         f"found {len(hits)} ({where})\n")
        sys.exit(1)

    for path, call_idx in hits:
        lines = files[path]

        def nearest_nonblank_noncomment(idx, step):
            i = idx + step
            while 0 <= i < len(lines):
                stripped = lines[i].strip()
                if stripped and not stripped.startswith("//"):
                    return stripped
                i += step
            return None

        above = nearest_nonblank_noncomment(call_idx, -1)
        if above != "#if DEBUG":
            sys.stderr.write(f"FAIL: {label}() call site is not #if DEBUG-gated ({path}:{call_idx + 1})\n")
            sys.exit(1)

        # Walk to the end of the call line's statement/block (brace-balance), so a
        # call sitting inside a multi-line guarded block (e.g. an `if ... { }`)
        # checks for #endif after the block closes, not right after the call line.
        balance = lines[call_idx].count("{") - lines[call_idx].count("}")
        end_idx = call_idx
        while balance > 0 and end_idx + 1 < len(lines):
            end_idx += 1
            balance += lines[end_idx].count("{") - lines[end_idx].count("}")

        below = nearest_nonblank_noncomment(end_idx, 1)
        if below != "#endif":
            sys.stderr.write(f"FAIL: {label}() call site is not #if DEBUG-gated ({path}:{call_idx + 1})\n")
            sys.exit(1)

        print(f"PASS: {label}() call site is #if DEBUG-gated ({path}:{call_idx + 1})")

assert_gated(r"noServerSeamActive\(\)", "noServerSeamActive")
assert_gated(r"autoOfflineSeamActive\(\)", "autoOfflineSeamActive")
assert_gated(r"AppConfig\.startURL\(origin:", "startURL")
assert_gated(r"self\.logApi\(", "logApi", expected_calls=2)
PY

# #115: the progress-bar scrub state (Dobby/Playback/ScrubState.swift) as a pure value
# type - the Slider knob binds to it the instant a drag starts, and seeding it with the
# live position is the whole fix.
OUT5="$(mktemp -d)/scrub-state-check"
xcrun swiftc -o "$OUT5" \
  Dobby/Playback/ScrubState.swift Tests/ScrubStateCheck.swift
"$OUT5"

# The seed only exists if PlayerView actually calls it. Deleting `scrub.begin(at:)` from
# the Slider onEditingChanged leaves ScrubStateCheck green while the app is broken again -
# the same mutant shape as the two textual checks below, and the only tool that catches it.
python3 - <<'SCRUBPY'
import sys

path = "Dobby/Playback/PlayerView.swift"
with open(path) as f:
    src = f.read()

if "scrub.begin(at: current)" not in src:
    sys.stderr.write("FAIL: PlayerView Slider does not seed the scrub from the displayed position (#115)\n")
    sys.exit(1)
if "scrub.end()" not in src:
    sys.stderr.write("FAIL: PlayerView Slider does not seek to the scrub end value (#115)\n")
    sys.exit(1)
if "scrubValue" in src or "@State private var scrubbing" in src:
    sys.stderr.write("FAIL: PlayerView still carries the pre-#115 loose scrub state\n")
    sys.exit(1)
if "Binding(get: { current }" not in src or "let current = scrub.displayed(live:" not in src:
    sys.stderr.write("FAIL: PlayerView Slider does not read the scrub for its displayed value (#115)\n")
    sys.exit(1)
if "if editing { scrub.begin(at: current) }" not in src or "else { playback.seek(to: scrub.end()) }" not in src:
    sys.stderr.write("FAIL: PlayerView Slider seeds/seeks in the wrong branch (#115)\n")
    sys.exit(1)

print("PASS: PlayerView Slider seeds the scrub from the displayed position and seeks to its end value")
SCRUBPY

# #112: a clean macOS build is the only thing that catches deepen-macos-frameworks.sh
# losing one of its three passes (SPM checkout, staged products dir, or the app
# bundle's own Contents/Frameworks) - every incremental build stays green regardless,
# since the earlier pass's mutation persists on disk from a prior build. This is a
# textual proxy standing in for that clean build.
python3 - <<'PY'
import sys
src = open("scripts/deepen-macos-frameworks.sh").read()
for needle, what in [("FRAMEWORKS_FOLDER_PATH", "the app bundle's Frameworks directory"),
                     ("BUILT_PRODUCTS_DIR", "the built products directory"),
                     ("SourcePackages/checkouts", "the SPM checkout")]:
    if needle not in src:
        sys.stderr.write(f"FAIL: deepen-macos-frameworks.sh no longer deepens {what} (#112)\n")
        sys.exit(1)
print("PASS: deepen-macos-frameworks.sh deepens the checkout, the products dir and the app bundle")
PY

# #067: the only check that puts the handler behind a real WKWebView on the real
# server origin, which is where the Mac bug lived — `dobby-api:` refused as mixed
# content from the https page, before any of the logic above ran. macOS only:
# it needs AppKit and a host that can start a web content process.
if [ "$(uname -s)" = "Darwin" ]; then
  OUT4="$(mktemp -d)/api-scheme-webview-check"
  # Embed a minimal Info.plist carrying the same WKAppBoundDomains entry the app
  # ships (Dobby/Info.plist), so isAppBound(server) in the check evaluates true
  # exactly as it does for the Mac app — App-Bound Domains is the one thing that
  # changes what WebKit permits, and a check that ran with it off could be green
  # while the app stayed broken (reviewer Mutant F).
  PLIST4="$(mktemp -d)/webview-check-info.plist"
  cat > "$PLIST4" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WKAppBoundDomains</key>
	<array>
		<string>solarflare-tarpon.ts.net</string>
	</array>
</dict>
</plist>
PLIST
  xcrun swiftc -o "$OUT4" -framework WebKit -framework AppKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST4" \
    Dobby/AppConfig.swift Dobby/Web/ApiSchemeHandler.swift Tests/ApiSchemeWebViewCheck.swift
  "$OUT4"
fi

# #067 follow-up: ApiSchemeWebViewCheck proves the primitive works, but it builds its
# own WKWebViewConfiguration — nothing above observes whether the app itself ever
# calls registerAsSecureScheme. Deleting the call from WebContainer.makeWebView left
# the whole suite green (reviewer's Mutant B). Same shape as the #if DEBUG check
# above: a textual check over the source is the only tool that can catch the call
# site being dropped.
python3 - <<'PY'
import sys

path = "Dobby/Web/WebContainer.swift"
with open(path) as f:
    lines = f.readlines()

calls = [i for i, l in enumerate(lines)
         if "registerAsSecureScheme(in:" in l and "//" not in l.split("registerAsSecureScheme")[0]]
webviews = [i for i, l in enumerate(lines) if "WKWebView(frame:" in l]

if len(calls) != 1:
    sys.stderr.write(f"FAIL: expected exactly one non-comment call to registerAsSecureScheme(in:), found {len(calls)}\n")
    sys.exit(1)
if len(webviews) != 1:
    sys.stderr.write(f"FAIL: expected exactly one WKWebView(frame: construction, found {len(webviews)}\n")
    sys.exit(1)
if calls[0] >= webviews[0]:
    sys.stderr.write("FAIL: registerAsSecureScheme(in:) must be called before WKWebView(frame:\n")
    sys.exit(1)

print("PASS: WebContainer calls registerAsSecureScheme(in:) before constructing its WKWebView")
PY
