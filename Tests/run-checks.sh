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
import re
import sys

path = "Dobby/ServerAddresses.swift"
with open(path) as f:
    lines = f.readlines()

calls = [i for i, l in enumerate(lines) if "noServerSeamActive()" in l and "func noServerSeamActive" not in l]
if len(calls) != 1:
    sys.stderr.write(f"FAIL: expected exactly one call to noServerSeamActive() outside its declaration, found {len(calls)}\n")
    sys.exit(1)

call_idx = calls[0]

def nearest_nonblank(idx, step):
    i = idx + step
    while 0 <= i < len(lines):
        stripped = lines[i].strip()
        if stripped:
            return stripped
        i += step
    return None

above = nearest_nonblank(call_idx, -1)
below = nearest_nonblank(call_idx, 1)

if above != "#if DEBUG" or below != "#endif":
    sys.stderr.write("FAIL: noServerSeamActive() call site is not #if DEBUG-gated\n")
    sys.exit(1)

print("PASS: noServerSeamActive() call site is #if DEBUG-gated")
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
