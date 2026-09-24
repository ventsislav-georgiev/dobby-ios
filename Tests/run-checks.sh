set -euo pipefail
cd "$(dirname "$0")/.."
# The Python blocks import Tests/swift_strip.py; keep them from writing Tests/__pycache__.
export PYTHONDONTWRITEBYTECODE=1

OUT="$(mktemp -d)/api-scheme-check"
xcrun swiftc -o "$OUT" \
  Dobby/AppConfig.swift Dobby/ServerAddresses.swift Dobby/Web/ApiSchemeHandler.swift Tests/ApiSchemeHandlerCheck.swift
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

# #190: every block that strips Swift comments imports Tests/swift_strip.py, one lexer for
# // and nested /* */ comments over "...", """...""" and #"..."# literals, whose probe runs on
# every import. Its standalone run below is the suite's PASS line for the stripper itself.
# #194: the JS the Swift literals carry is stripped by Tests/js_strip.py, the #158 strip_js
# moved out of BRIDGENAMESPY so PIGATEPY shares it; its standalone run is its PASS line.
python3 Tests/swift_strip.py
python3 Tests/js_strip.py
# The wiring: each Swift-stripping block imports the helper and strips through it at its read,
# reads nothing raw beside it, and no block grows its own stripper again (a // -only copy passes
# every pin).
python3 - <<'SWIFTSTRIPWIRINGPY'
import re
import sys

def fail(msg):
    sys.stderr.write("FAIL: %s (#190, #194)\n" % msg)
    sys.exit(1)

text = open("Tests/run-checks.sh").read()
blocks = {}
for name, body in re.findall(r"<<'(\w+)'\n(.*?)\n\1\n", text, re.S):
    blocks.setdefault(name, []).append(body)
SW, SWL, JS = "from swift_strip import strip_swift", "from swift_strip import strip_swift_lines", "from js_strip import strip_js"
# name: (import lines, strip-call lines, raw reads allowed beside them). Every line of the
# block that reads a file (open(, .read(, readlines(, or BRIDGENAMESPY's raw read( helper) must
# be one of the two lists, so a raw re-read after the strip is a named FAIL (#194).
reads = {
    "ASSERTGATEDPY": (["from swift_strip import strip_swift, strip_swift_lines"],
                      ["        lines = strip_swift_lines(open(path).read(), path)",
                       'selftest = strip_swift(open("Dobby/Web/SettingsSelfTest.swift").read(), "SettingsSelfTest.swift").splitlines()'], []),
    "SECURESCHEMEPY": ([SWL], ["lines = strip_swift_lines(open(path).read(), path)"], []),
    "PRESENCEPY": ([SW], ['src = strip_swift(open("Dobby/Web/ApiSchemeHandler.swift").read(), "ApiSchemeHandler.swift")',
                          "    server_src = strip_swift(open(routes).read(), routes)",
                          "    text = strip_swift(open(path).read(), path)"], []),
    "KEYCHAINSTATUSPY": ([SW], ['src = strip_swift(open("Dobby/Web/ApiSchemeHandler.swift").read(), "ApiSchemeHandler.swift")'],
                         ['check_src = open("Tests/ApiSchemeHandlerCheck.swift").read()',
                          r'    pm = re.findall(r"var retryStatuses = options\.retryStatuses \|\| \[([\d, ]+)\];", open(page).read())']),
    "TIMELABELWIDTHPY": ([SW], ["src = strip_swift(open(path).read(), path)"], []),
    "BRIDGENAMESPY": ([SW, JS], ['inject = strip_swift(read("Dobby/Web/BridgeInjection.swift"), "BridgeInjection.swift")',
                                 'webbridge = strip_swift(read("Dobby/Web/WebBridge.swift"), "WebBridge.swift")',
                                 "literal = strip_js(inject[start:end])",
                                 "    src = strip_swift(read(path), path)",
                                 "    text = strip_js(read(path))"],
                      ["def read(path):", '    with open(path, encoding="utf-8") as f:', "        return f.read()"]),
    "SCHEMEMAINPY": ([SWL], ["    lines = strip_swift_lines(open(path).read(), path)"], []),
    "PIGATEPY": ([SW, JS], ["        return strip_swift(f.read(), path)", "literal = strip_js(literal)"],
                 ['    with open(path, encoding="utf-8") as f:', '    with open(gate_file, encoding="utf-8") as f:',
                  "        js = f.read()"]),
}
raw = re.compile(r"\bopen\(|\.read\(|readlines\(")
for name, (imports, needles, allowed) in reads.items():
    if len(blocks.get(name, [])) != 1:
        fail("expected exactly one %s block in run-checks.sh" % name)
    body = blocks[name][0].split("\n")
    for imp in ['sys.path.insert(0, "Tests")'] + imports:
        if imp not in body:
            fail("%s no longer imports its stripper at top level: missing %r" % (name, imp))
    for n in needles:
        if body.count(n) != 1:
            fail("%s no longer strips its read through the shared helper exactly once: %r found %d time(s)"
                 % (name, n, body.count(n)))
    rx = re.compile(raw.pattern + r"|\bread\(") if "def read(path):" in allowed else raw
    for l in body:
        if not l.lstrip().startswith("#") and rx.search(l) and l not in needles and l not in allowed:
            fail("%s reads a file outside its pinned stripped reads: %r" % (name, l))
# ORDER: the JS strip sits between the literal's extraction and the member regex that reads it,
# and nothing re-assigns the literal after it.
for name, extract, strip, reader in [
        ("PIGATEPY", "literal = inject[locate(inject, anchor", "literal = strip_js(literal)", "for name, pattern in members.items():"),
        ("BRIDGENAMESPY", "end = inject.index(", "literal = strip_js(inject[start:end])", "for line in literal.splitlines():")]:
    body = blocks[name][0].split("\n")
    at = [next((i for i, l in enumerate(body) if l.startswith(s)), -1) for s in (extract, strip, reader)]
    if not 0 <= at[0] < at[1] < at[2]:
        fail("%s no longer strips the window.Dobby literal's JS comments after extracting it and before "
             "its member regex reads it" % name)
    if [i for i, l in enumerate(body) if re.match(r"literal\s*=", l) and i > at[1]]:
        fail("%s re-assigns the window.Dobby literal after its JS comments were stripped" % name)
for name, bodies in blocks.items():
    for body in bodies:
        if ".swift" in body and re.search(r"^\s*(def strip\w*\(|strip_\w+ = )", body, re.M):
            fail("%s reads Swift and defines its own stripper; import Tests/swift_strip.py or "
                 "Tests/js_strip.py instead" % name)
for mod in ("swift_strip", "js_strip"):
    first_use = text.find("from %s import" % mod)
    if not 0 <= text.find("\npython3 Tests/%s.py\n" % mod) < first_use:
        fail("the standalone probe run of Tests/%s.py is gone or no longer precedes its first import" % mod)
print("PASS: %s strip through the probed Tests/swift_strip.py and Tests/js_strip.py at their pinned "
      "reads and read nothing raw beside them, PIGATEPY and BRIDGENAMESPY strip the window.Dobby "
      "literal's JS before reading its members, and no Swift-reading block defines its own stripper "
      "(#190, #194)" % ", ".join(sorted(reads)))
SWIFTSTRIPWIRINGPY

# Compile-time property with no runtime observable: resolve() reports the same "absent" verdict
# whether the seam call is #if DEBUG-gated or unconditional, and the reason string only reaches
# OSLog, so no assertion above this line can distinguish a shipped guard from a shipped hole.
# A textual check over the source is the only tool that can catch the call site losing its
# DEBUG gate (or a second, ungated call being added elsewhere).
python3 - <<'ASSERTGATEDPY'
import glob
import re
import sys
sys.path.insert(0, "Tests")
from swift_strip import strip_swift, strip_swift_lines

def assert_gated(call_regex, label, expected_calls=1):
    hits = []
    files = {}
    for path in sorted(glob.glob("Dobby/**/*.swift", recursive=True)):
        # One entry per source line, comments gone: the hits report line numbers (#194).
        lines = strip_swift_lines(open(path).read(), path)
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

assert_gated(r"noServerSeamActive\(\)", "noServerSeamActive", expected_calls=3)
assert_gated(r"autoOfflineSeamActive\(\)", "autoOfflineSeamActive")
assert_gated(r"AppConfig\.startURL\(origin:", "startURL")
assert_gated(r"self\.logApi\(", "logApi", expected_calls=2)
# #149 device round: the settings self-test seam. Its call site is gated here, and the
# file that defines it must be DEBUG from its first line to its last, so no part of it
# (the page script included) can reach a Release build.
assert_gated(r"SettingsSelfTest\.run\(", "run")
selftest = strip_swift(open("Dobby/Web/SettingsSelfTest.swift").read(), "SettingsSelfTest.swift").splitlines()
if selftest[0] != "#if DEBUG" or selftest[-1] != "#endif":
    sys.stderr.write("FAIL: Dobby/Web/SettingsSelfTest.swift is not #if DEBUG end to end (#149)\n")
    sys.exit(1)
print("PASS: SettingsSelfTest.swift is #if DEBUG end to end (#149)")
ASSERTGATEDPY

# #115: the progress-bar scrub state (Dobby/Playback/ScrubState.swift) as a pure value
# type - the Slider knob binds to it the instant a drag starts, and seeding it with the
# live position is the whole fix.
OUT5="$(mktemp -d)/scrub-state-check"
xcrun swiftc -o "$OUT5" \
  Dobby/Playback/ScrubState.swift Tests/ScrubStateCheck.swift
"$OUT5"

OUT6="$(mktemp -d)/offline-store-path-check"
xcrun swiftc -o "$OUT6" \
  Dobby/Offline/OfflinePathAnchor.swift Tests/OfflineStorePathCheck.swift
"$OUT6"

# #125 review: anchorOfflinePath is correct only because OfflineStore.root ends in
# /Offline and the anchor splits on that same literal. Pin both ends so a reshaped
# root or a changed split marker goes red instead of silently doubling a segment.
python3 - <<'OFFLINEROOTPY'
import sys

store = open("Dobby/Offline/OfflineStore.swift").read()
anchor = open("Dobby/Offline/OfflinePathAnchor.swift").read()

if 'root = docs.appendingPathComponent("Offline", isDirectory: true)' not in store:
    sys.stderr.write("FAIL: OfflineStore.root no longer ends in /Offline, the path anchor contract is broken (#125)\n")
    sys.exit(1)
if 'stored.range(of: "/Offline/")' not in anchor:
    sys.stderr.write("FAIL: anchorOfflinePath no longer splits on the /Offline/ literal that OfflineStore.root ends in (#125)\n")
    sys.exit(1)

print("PASS: OfflineStore.root ends in /Offline and anchorOfflinePath splits on that literal (#125)")
OFFLINEROOTPY

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
# #131 changed the release branch from `else {` to `else if scrub.isScrubbing {`: the
# recovery path in sliderTouchEnded() commits the same drag when SwiftUI never delivers
# onEditingChanged(false), and `isScrubbing` (cleared by end()) is the interlock that
# stops whichever path runs second from seeking twice. The old needle described a branch
# that can no longer be correct unguarded, so it is replaced rather than dropped — and
# the replacement is strictly stronger: one literal now pins the release branch, the
# exactly-once guard AND the seek together, so a mutant deleting the guard goes red here
# instead of silently double-seeking.
if "if editing { scrub.begin(at: current) }" not in src or "else if scrub.isScrubbing { playback.seek(to: scrub.end()) }" not in src:
    sys.stderr.write("FAIL: PlayerView Slider seeds/seeks in the wrong branch (#115)\n")
    sys.exit(1)

# #117 review: a mutant moved the seek out of the release branch (both this
# and the seed check still passed, since both needles just had to appear
# somewhere in the file). Pin the seek to actually sit in the else of the
# editing-toggle, after the seed.
i = src.index("if editing { scrub.begin(at: current) }")
j = src.index("playback.seek(to: scrub.end())")
if not (i < j and "else if scrub.isScrubbing {" in src[i:j]):
    sys.stderr.write("FAIL: PlayerView Slider seeks outside the release branch (#115)\n")
    sys.exit(1)

print("PASS: PlayerView Slider seeds the scrub from the displayed position and seeks to its end value")
SCRUBPY

# #117: PlaybackCoordinator.seek(to:) used to call the completion-discarding
# KSPlayerLayer convenience seek(time:) (KSPlayerLayer.swift:540-543), so a
# dropped seek (KSPlayerLayer.swift:344-347, player ready but not seekable —
# or the shouldSeekTo>0-never-replayed target-0 exception at :383) was never
# noticed and never logged. Review HOLD on the first pass: surfacing it to
# the UI risked restoring a knob a deferred (CASE A) seek was about to
# correct anyway, so this only logs the genuine drop — nothing reads a
# completion Bool. Pin every load-bearing line: the non-finite guard (a
# non-returning completion(false) at KSPlayerLayer.swift:333-334 can double-
# fire if we ever pass it a NaN/inf), the exact autoPlay argument (a mutant
# swapping it back to layer.state.isPlaying breaks CASE A's replay silently,
# since KSPlayerLayer.readyToPlay only replays/autoplays when isAutoPlay —
# set from this argument — is true), the completion-taking call, the A/B
# classification, and the log line.
python3 - <<'SEEKPY'
import sys

path = "Dobby/Playback/PlaybackCoordinator.swift"
with open(path) as f:
    coordinator_src = f.read()

if "guard seconds.isFinite, let layer = player.playerLayer else {" not in coordinator_src:
    sys.stderr.write("FAIL: PlaybackCoordinator.seek(to:) does not guard a non-finite target (#117)\n")
    sys.exit(1)
# One needle, not two: pinning the whole call line (not just the autoPlay
# argument as a separate substring) proves both that autoPlay is the right
# property AND that it's still the completion-taking overload being called —
# a mutant could otherwise keep the standalone "autoPlay: ..." substring
# alive elsewhere (e.g. in a comment) while breaking the real call.
if "layer.seek(time: seconds, autoPlay: layer.options.isSeekedAutoPlay) { [weak self] finished in" not in coordinator_src:
    sys.stderr.write("FAIL: PlaybackCoordinator.seek(to:) does not call the completion-taking KSPlayerLayer.seek with layer.options.isSeekedAutoPlay (#117)\n")
    sys.exit(1)
if "let dropped = (wasReadyToPlay && !wasSeekable) || (!wasReadyToPlay && seconds == 0)" not in coordinator_src:
    sys.stderr.write("FAIL: PlaybackCoordinator.seek(to:) does not tell a deferred seek apart from a dropped one (#117)\n")
    sys.exit(1)
# A bare "Self.log.info(" substring is not enough on its own: this file now
# carries TWO log calls (the non-finite-target rejection above, and this
# one), so it survives deleting either one. Pin the case-B message text so
# only that specific log call keeps the check green.
if "Self.log.info(\"seek dropped" not in coordinator_src:
    sys.stderr.write("FAIL: PlaybackCoordinator.seek(to:) does not log the dropped seek (#117)\n")
    sys.exit(1)

print("PASS: PlaybackCoordinator guards non-finite targets, preserves autoplay semantics, and logs a dropped seek (#117)")
SEEKPY

# #112: a clean macOS build is the only thing that catches deepen-macos-frameworks.sh
# losing one of its three passes (SPM checkout, staged products dir, or the app
# bundle's own Contents/Frameworks) - every incremental build stays green regardless,
# since the earlier pass's mutation persists on disk from a prior build. This is a
# textual proxy standing in for that clean build.
python3 - <<'PY'
import sys
src = open("scripts/deepen-macos-frameworks.sh").read()
for needle, what in [('for dir in "${TARGET_BUILD_DIR:-}"', "the app bundle's Frameworks directory"),
                     ('for dir in "${BUILT_PRODUCTS_DIR:-}" "${CONFIGURATION_BUILD_DIR:-}"', "the built products directory"),
                     ('for xc in "$SRC"/*.xcframework', "the SPM checkout")]:
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
    Dobby/AppConfig.swift Dobby/ServerAddresses.swift Dobby/Web/ApiSchemeHandler.swift Tests/ApiSchemeWebViewCheck.swift
  "$OUT4"
fi

# #067 follow-up: ApiSchemeWebViewCheck proves the primitive works, but it builds its
# own WKWebViewConfiguration — nothing above observes whether the app itself ever
# calls registerAsSecureScheme. Deleting the call from WebContainer.makeWebView left
# the whole suite green (reviewer's Mutant B). Same shape as the #if DEBUG check
# above: a textual check over the source is the only tool that can catch the call
# site being dropped.
#
# #151 added the SECOND call, for OfflineSchemeHandler.scheme, with exactly the same
# property: BundledShellWebViewCheck builds its own configuration and marks the scheme
# secure itself, so deleting the app's call leaves that check green while every
# `<script src="dobby-offline://shell/...">` on the phone is refused as mixed content
# and the Pi-less cold start is a blank page. Both calls are pinned, by scheme, and
# both before the WKWebView.
python3 - <<'SECURESCHEMEPY'
import sys
sys.path.insert(0, "Tests")
from swift_strip import strip_swift_lines

path = "Dobby/Web/WebContainer.swift"
# One entry per source line, comments gone: order is compared by line index (#194).
lines = strip_swift_lines(open(path).read(), path)

calls = [i for i, l in enumerate(lines) if "registerAsSecureScheme(in:" in l]
webviews = [i for i, l in enumerate(lines) if "WKWebView(frame:" in l]

if len(calls) != 2:
    sys.stderr.write(f"FAIL: expected exactly two non-comment calls to registerAsSecureScheme(in:), found {len(calls)}\n")
    sys.exit(1)
if len(webviews) != 1:
    sys.stderr.write(f"FAIL: expected exactly one WKWebView(frame: construction, found {len(webviews)}\n")
    sys.exit(1)
for i in calls:
    if i >= webviews[0]:
        sys.stderr.write("FAIL: every registerAsSecureScheme(in:) call must come before WKWebView(frame:\n")
        sys.exit(1)

# The exact single-line constructs, argument order included. The default-argument call
# is the dobby-api: one (#067); the scheme-carrying call is #151's. A mutant that keeps
# two calls but points both at the same scheme loses one lane silently.
api = "ApiSchemeHandler.registerAsSecureScheme(in: config)"
offline = "ApiSchemeHandler.registerAsSecureScheme(in: config, scheme: OfflineSchemeHandler.scheme)"
stripped = [lines[i].strip() for i in calls]
if stripped != [api, offline]:
    sys.stderr.write("FAIL: expected exactly these two calls, in this order:\n  " + api + "\n  " + offline
                     + "\ngot:\n  " + "\n  ".join(stripped) + "\n")
    sys.exit(1)

print("PASS: WebContainer marks both dobby-api: and dobby-offline: secure before constructing its WKWebView (#067, #151)")
SECURESCHEMEPY

# #129: scheduleHide() re-armed the auto-hide timer on every isPlaying state change,
# including a rebuffer mid-drag, so a scrub longer than the 3s idle window lost the
# Slider under the finger. Pin both ends: the scrubbing guard in scheduleHide(), and
# the PlayerView Slider closure setting scrubbing true before it seeds the drag and
# false after it seeks, so a mutant dropping either write goes red.
python3 - <<'SCRUBBINGPY'
import sys

controls_path = "Dobby/Playback/PlayerControls.swift"
with open(controls_path) as f:
    controls_src = f.read()

if "guard menu == nil, !showInfo, isPlaying, !scrubbing else { return }" not in controls_src:
    sys.stderr.write("FAIL: PlayerControls.scheduleHide() no longer guards on scrubbing (#129)\n")
    sys.exit(1)

view_path = "Dobby/Playback/PlayerView.swift"
with open(view_path) as f:
    view_src = f.read()

if "controls.scrubbing = true" not in view_src:
    sys.stderr.write("FAIL: PlayerView Slider never sets controls.scrubbing = true on drag start (#129)\n")
    sys.exit(1)
if "controls.scrubbing = false" not in view_src:
    sys.stderr.write("FAIL: PlayerView Slider never sets controls.scrubbing = false on release (#129)\n")
    sys.exit(1)

begin_idx = view_src.index("scrub.begin(at: current)")
true_idx = view_src.index("controls.scrubbing = true")
if not (true_idx < begin_idx):
    sys.stderr.write("FAIL: controls.scrubbing = true is not set before the drag seeds scrub.begin (#129)\n")
    sys.exit(1)

seek_idx = view_src.index("playback.seek(to: scrub.end())")
false_idx = view_src.index("controls.scrubbing = false")
if not (false_idx > seek_idx):
    sys.stderr.write("FAIL: controls.scrubbing = false is not set after the release seek (#129)\n")
    sys.exit(1)

if "controls.scheduleHide()" not in view_src:
    sys.stderr.write("FAIL: PlayerView Slider does not re-arm the idle timer after the scrub ends (#129)\n")
    sys.exit(1)
hide_idx = view_src.index("controls.scheduleHide()")
if not (hide_idx > false_idx):
    sys.stderr.write("FAIL: PlayerView Slider does not re-arm the idle timer after the scrub ends (#129)\n")
    sys.exit(1)

if "func hide() { guard !scrubbing else { return };" not in controls_src:
    sys.stderr.write("FAIL: PlayerControls.hide() does not guard against scrubbing (#129)\n")
    sys.exit(1)

print("PASS: PlayerControls.scheduleHide() and the PlayerView Slider guard the OSD for the whole scrub (#129)")
SCRUBBINGPY

# #131: on device SwiftUI did not deliver one drag's onEditingChanged(false) at all
# (.claude-work/115-evidence/diag4-owner-drag.log, drag 3) — no seek ran and #129's
# scrubbing flag stayed set, freezing the OSD. The recovery hangs off a @GestureState,
# which SwiftUI resets when the gesture ends OR is cancelled, so it does not share the
# failure mode of the callback it backs up. Nothing runtime-observable distinguishes a
# shipped recovery from a deleted one (the healthy path never needs it), so pin every
# load-bearing line: the gesture state, the simultaneous gesture that drives it, the
# root-level onChange, and each statement in the handler — including that the flag clear
# and the re-arm sit at function-body level, not inside the recovery branch.
python3 - <<'RELEASEPY'
import sys

view_path = "Dobby/Playback/PlayerView.swift"
with open(view_path) as f:
    view_src = f.read()

def need(needle, message):
    if needle not in view_src:
        sys.stderr.write(f"FAIL: {message} (#131)\n")
        sys.exit(1)

need("@GestureState private var sliderTouch = false",
     "PlayerView no longer carries the @GestureState that SwiftUI resets on a cancelled drag")
need(".simultaneousGesture(DragGesture(minimumDistance: 0).updating($sliderTouch) { _, down, _ in down = true })",
     "the Slider no longer rides a simultaneous DragGesture that drives sliderTouch")
need(".onChange(of: sliderTouch) { down in if !down { sliderTouchEnded() } }",
     "PlayerView no longer recovers the lost Slider release from the gesture-state reset")

# Supervisor review addition: the needle above pins the line but not WHERE it hangs, and
# where is the whole point. On the Slider, the handler dies with the control bar the
# instant a hide tears it out mid-drag — exactly the case this recovers. On the root it
# outlives the bar. Pin the placement by position: the root modifier chain (anchored on
# .onDisappear) comes before the control bar's Slider in this file.
# Reviewer follow-up: the window between .onDisappear and Slider(value:) is not tight
# enough. `private var osd` opens inside that window, and osd is built only under
# `if controls.visible`, so an onChange re-attached there dies exactly when the OSD
# hides — the case the root placement exists to survive. Anchor it instead: nothing
# may DECLARE a new property or function between the root chain and this modifier,
# which pins it to the root body rather than merely to a range of the file.
anchor_idx = view_src.index(".onDisappear {")
change_idx = view_src.index(".onChange(of: sliderTouch)")
if not (anchor_idx < change_idx < view_src.index("Slider(value:")):
    sys.stderr.write("FAIL: the sliderTouch onChange moved off the root view onto the control bar, where it dies with the Slider it backs up (#131)\n")
    sys.exit(1)
between = view_src[anchor_idx:change_idx]
if "private var " in between or "private func " in between:
    sys.stderr.write("FAIL: the sliderTouch onChange moved into a nested view body (a declaration opens between it and the root chain); it must hang off the root so it outlives the OSD and the control bar (#131)\n")
    sys.exit(1)

if view_src.count("sliderTouchEnded()") != 2:   # the declaration and its single call site
    sys.stderr.write("FAIL: sliderTouchEnded() must have exactly one call site (#131)\n")
    sys.exit(1)

start = view_src.index("private func sliderTouchEnded() {")
body = view_src[start:view_src.index("\n    }\n", start)]

for needle, message in [
    ("if scrub.isScrubbing {", "the recovery does not gate on a live scrub, so a bare tap can seek to a stale value"),
    ("let target = scrub.end()", "the recovery does not clear the scrub through end(), losing the exactly-once interlock"),
    ("playback.seek(to: target)", "the recovery does not seek"),
    ("slider release recovered", "the recovery does not log a line of its own for the device round"),
    ("\n        controls.scrubbing = false", "the recovery clears controls.scrubbing conditionally instead of on every touch-up"),
    ("\n        controls.scheduleHide()", "the recovery re-arms the idle timer conditionally instead of on every touch-up"),
]:
    if needle not in body:
        sys.stderr.write(f"FAIL: sliderTouchEnded() — {message} (#131)\n")
        sys.exit(1)

if not (body.index("if scrub.isScrubbing {")
        < body.index("playback.seek(to: target)")
        < body.index("\n        controls.scrubbing = false")
        < body.index("\n        controls.scheduleHide()")):
    sys.stderr.write("FAIL: sliderTouchEnded() runs its steps out of order (#131)\n")
    sys.exit(1)

print("PASS: PlayerView recovers a Slider release SwiftUI never delivers and always clears the scrub hold (#131)")
RELEASEPY

# #130: project.yml pinned KSPlayer to a revision instead of `branch: main` so every
# checkout/CI run resolves the same commit (Dobby.xcodeproj and its Package.resolved
# are gitignored, so nothing else pins it). Catch a regression back to a branch ref.
python3 - <<'KSPLAYERPINPY'
import sys

path = "project.yml"
with open(path) as f:
    lines = f.readlines()

start = None
for i, l in enumerate(lines):
    if l.strip() == "KSPlayer:":
        start = i
        break
if start is None:
    sys.stderr.write("FAIL: project.yml has no KSPlayer: package entry (#130)\n")
    sys.exit(1)

indent = len(lines[start]) - len(lines[start].lstrip(" "))
end = len(lines)
for i in range(start + 1, len(lines)):
    line_indent = len(lines[i]) - len(lines[i].lstrip(" "))
    if lines[i].strip() and line_indent <= indent:
        end = i
        break

stanza = lines[start:end]
code_lines = [l for l in stanza if not l.strip().startswith("#")]
code_text = "".join(code_lines)

if "revision: 75e590e770f7f01d088ced2546deed9817b660ae" not in code_text:
    sys.stderr.write("FAIL: project.yml pins KSPlayer to revision 75e590e, never a branch (#130)\n")
    sys.exit(1)
if "branch:" in code_text:
    sys.stderr.write("FAIL: project.yml pins KSPlayer to revision 75e590e, never a branch (#130)\n")
    sys.exit(1)

print("PASS: project.yml pins KSPlayer to revision 75e590e, never a branch (#130)")
KSPLAYERPINPY

# #132: the KSPlayer pin only moves on the strength of a device round, and that round's
# gate is one log line. KSOptions.firstPlayerType is a REQUEST — KSPlayerLayer silently
# swaps to secondPlayerType (KSMEPlayer) when the first player cannot open the stream,
# so a direct-file MKV runs KSMEPlayer while isAdaptivePair is false. Every source change
# in the 6dda7cc..75e590e range except the M3U scanner is under MEPlayer/ or Subtitle/,
# which means a round that cannot READ the engine proves nothing about the move. Delete
# this line and the next round comes back green having tested the wrong player; nothing
# else in this file notices, which is why it is pinned here.
python3 - <<'ENGINELOGPY'
import re, sys

with open("Dobby/Playback/PlaybackCoordinator.swift") as f:
    src = f.read()

try:
    body_start = src.index("func onStateChanged(")
except ValueError:
    sys.stderr.write("FAIL: PlaybackCoordinator has no onStateChanged — the #132 engine-log check needs updating\n")
    sys.exit(1)
body = src[body_start:]

if 'mark("engine=' not in body:
    sys.stderr.write("FAIL: PlaybackCoordinator.onStateChanged no longer logs engine=, so a device round cannot tell which player opened the stream and the #132 gate is gone\n")
    sys.exit(1)

# It has to report the player that actually opened, not the lane that was requested:
# reading isAdaptivePair alone would print "KSMEPlayer" for a swap it never saw.
engine_idx = body.index('mark("engine=')
preceding = body[:engine_idx]
if "type(of:" not in preceding:
    sys.stderr.write("FAIL: the #132 engine= line no longer derives the engine from type(of:) on the live player, so it reports the requested lane rather than the player that opened\n")
    sys.exit(1)
if ".readyToPlay" not in preceding:
    sys.stderr.write("FAIL: the #132 engine= line is no longer under a .readyToPlay branch, so it can fire before a fallback swap has happened\n")
    sys.exit(1)

print("PASS: PlaybackCoordinator logs the engine that actually opened the stream, so a #132 device round can be gated on it")
ENGINELOGPY

# #128: the elapsed label used to format itself alone (d:dd under an hour, d:dd:dd at
# or above), so scrubbing across the 1:00:00 mark grew it by three characters mid-drag,
# reflowing the controlBar HStack and sliding the Slider under the tracking finger.
# Pin both ends: the call site passing `matching: total` (the label construct) and the
# `total >= 3600` term inside timeLabel (what actually gives it a stable width — a
# mutant that keeps the parameter but drops this term regresses silently).
python3 - <<'SETTINGSWRITEPY'
import sys

# #149 (M5-F) — the wiring around the settings write. The merge rule itself is
# pinned as values in ApiSchemeHandlerCheck.swift; what cannot be reached from a
# pure function is which methods serveSettings takes, that the write is actually
# stored before it is acknowledged, and that a stored write cannot then be pulled
# back over by a background refresh. Exact single-line constructs, and position
# where position is the meaning.

path = "Dobby/Web/ApiSchemeHandler.swift"
with open(path) as f:
    src = f.read()

def need(needle, message):
    if needle not in src:
        sys.stderr.write(f"FAIL: {message} (#149)\n")
        sys.exit(1)

# Without this the body never reaches serveSettings and every POST 400s — the
# write lane would be dead in a way no pure-function check can see.
need("        let body = task.request.httpBody",
     "webView(_:start:) no longer reads the POST body off the task request")

# ...and hands it on. Reading the body and then passing `nil` (or dropping the
# argument) leaves every check above green — the merge is pure and the 400 branch
# is textual — while every settings POST on the phone 400s and the write lane is
# dead. A helper is only as wired as its call site.
need('            case "settings": self.serveSettings(task, id, url, method, origin, body)',
     "webView(_:start:) no longer passes the POST body it read through to serveSettings, so every settings write would be refused with a 400")

# Both halves of the method gate: POST is taken, and everything else is still
# refused. Dropping either literal from this one line is a separate bug.
need('        guard method == "GET" || method == "POST" else {',
     "serveSettings no longer takes exactly GET and POST")
need('            fail(task, id, 405, "Settings mirror takes GET and POST", origin, secret: true); return',
     "serveSettings no longer 405s a method that is neither GET nor POST")

# An unmergeable body is refused, not stored: a partial or corrupt document read
# back later is indistinguishable from a complete one.
need('                fail(task, id, 400, "Settings write needs a JSON object body", origin, secret: true); return',
     "a settings POST with no body, or a body that is not a JSON object, is no longer refused with a 400")

need("            if stored == errSecSuccess || stored == errSecItemNotFound { stored = SettingsMirrorStore.save(merged) }",
     "the settings POST no longer stores the merged document")
need("                SettingsMirrorStore.markAheadOfServer()",
     "the settings POST no longer marks the mirror as ahead of the Pi, so the next background refresh can pull the pre-write body back over it")

# Order is the meaning: the write must be stored and marked before the page is
# told it succeeded, or a 200 can outlive a failed save.
save_idx = src.index("            if stored == errSecSuccess || stored == errSecItemNotFound { stored = SettingsMirrorStore.save(merged) }")
mark_idx = src.index("                SettingsMirrorStore.markAheadOfServer()")
# #185: the acknowledgement is now the one built from the Keychain status.
need("            respond(task, id, status: answer.status, contentType: \"application/json\",",
     "the settings POST no longer answers with the status settingsWriteAnswer built from the Keychain, so a refused save can read as done")
ack_idx = src.index("            respond(task, id, status: answer.status, contentType: \"application/json\",")
refuse_idx = src.index('fail(task, id, 400, "Settings write needs a JSON object body"')
if not (refuse_idx < save_idx < mark_idx < ack_idx):
    sys.stderr.write("FAIL: the settings POST acknowledges the write before storing and marking it, or refuses after storing (#149)\n")
    sys.exit(1)

# The guard has to be the FIRST thing refreshSettingsInBackground does. Below the
# lock, or below the fetch, it still lets the pull happen and overwrite.
body_start = src.index("private func refreshSettingsInBackground() {")
body = src[body_start:src.index("\n    }\n", body_start)]
if "if SettingsMirrorStore.isAheadOfServer { return }" not in body:
    sys.stderr.write("FAIL: refreshSettingsInBackground no longer refuses to pull over a locally-written document (#149)\n")
    sys.exit(1)
ahead_idx = body.index("if SettingsMirrorStore.isAheadOfServer { return }")
for later, what in [("refreshing.lock()", "the refresh lock"),
                    ("SettingsMirrorStore.save(fresh)", "the pull's own save")]:
    if later in body and body.index(later) < ahead_idx:
        sys.stderr.write(f"FAIL: the ahead-of-server guard sits after {what}, so a pull can still land (#149)\n")
        sys.exit(1)

print("PASS: dobby-api://settings takes a POST, stores the merge before acknowledging it, and a locally-written document is never pulled over (#149)")
SETTINGSWRITEPY

# #184: the has* flags the Configured badge reads. The rule itself is pinned as values in
# ApiSchemeHandlerCheck.presenceFlags; these pin where it runs (every 200 settings answer,
# inside the one function that builds it, before the page is handed the body) and that
# its key list is the server's. Comments are stripped first by the shared, probed stripper.
#
python3 - <<'PRESENCEPY'
import os
import re
import sys
sys.path.insert(0, "Tests")
from swift_strip import strip_swift

def fail(msg):
    sys.stderr.write("FAIL: %s (#184)\n" % msg)
    sys.exit(1)

def locate(scope, needle, what, start=0):
    # A missing anchor is a named FAIL, never a ValueError traceback (#190).
    try:
        return scope.index(needle, start)
    except ValueError:
        fail("%s: anchor %r is missing" % (what, needle))

src = strip_swift(open("Dobby/Web/ApiSchemeHandler.swift").read(), "ApiSchemeHandler.swift")

def body(start, what):
    if src.count(start) != 1:
        fail("%s: expected exactly one %r" % (what, start))
    a = locate(src, start, what)
    return src[a:locate(src, "\n    }\n", what + " end", a)]

outcome = body("static func settingsOutcome(mirror: Data?, fetch: () -> Data?)", "settingsOutcome")
answers = [l.strip() for l in outcome.split("\n") if "return (200" in l]
want = ["if let mirror, !mirror.isEmpty { return (200, withPresenceFlags(mirror), false) }",
        "if let fresh = fetch(), !fresh.isEmpty { return (200, withPresenceFlags(fresh), true) }"]
if answers != want:
    fail("settingsOutcome must answer both 200 bodies, mirror hit then Pi fetch, through "
         "withPresenceFlags; got %r" % answers)

serve = body("private func serveSettings(", "serveSettings")
responds = [m.start() for m in re.finditer(r"\brespond\(", serve)]
if len(responds) != 2:
    fail("serveSettings must answer through exactly two respond( calls (POST ack, GET), found %d" % len(responds))
ack = serve[responds[0]:locate(serve, "\n", "the POST ack", locate(serve, "\n", "the POST ack", responds[0]) + 1)]
# #185: the POST answer is settingsWriteAnswer's, whose only 200 body is {} (pinned as values
# in ApiSchemeHandlerCheck.settingsWriteAnswerRule and as a line in the #185 block below).
if "body: answer.body, origin: origin, secret: true," not in ack:
    fail("the POST leg now answers something other than settingsWriteAnswer's body; a settings document there needs withPresenceFlags too")
get_answer = 'respond(task, id, status: outcome.status, contentType: "application/json",\n                body: outcome.body, origin: origin, secret: true,'
if serve.count(get_answer) != 1 or serve.index(get_answer) != responds[1]:
    fail("the GET leg must answer outcome.body, as settingsOutcome built it, in its only respond(")
built = "let outcome = Self.settingsOutcome(mirror: mirror) {"
if serve.count(built) != 1 or serve.count("outcome =") != 1:
    fail("serveSettings must build its GET answer with exactly one settingsOutcome call")
if not serve.index(built) < responds[1]:
    fail("the GET answer is handed to the task before settingsOutcome derives its flags")
if "withPresenceFlags(" in serve:
    fail("serveSettings derives flags itself; the one derivation belongs inside settingsOutcome")
if src.count("static func withPresenceFlags(") != 1 or src.count("withPresenceFlags(") != 3:
    fail("withPresenceFlags must be defined once and called only from settingsOutcome's two answers")

m = re.search(r"static let presenceFlaggedKeys = \[(.*?)\]", src, re.S)
if not m:
    fail("presenceFlaggedKeys is gone")
swift_keys = re.findall(r'"(\w+)"', m.group(1))

routes = "../dobby/Sources/BookPlayServer/SettingsRoutes.swift"
if not os.path.isfile(routes):
    print("SKIP: no sibling dobby checkout, the has* key list is not compared with the server (#184)")
else:
    server_src = strip_swift(open(routes).read(), routes)
    get = server_src[locate(server_src, 'router.get("api/settings")', "SettingsRoutes"):locate(server_src, 'router.post("api/settings")', "SettingsRoutes")]
    server = dict(re.findall(r"(has\w+):\s*settings\.(\w+)\?\.isEmpty == false", get))
    if not server:
        fail("found no has* in the server's GET route; the pattern no longer matches the source")
    if len(server) != len(re.findall(r"\bhas[A-Z]\w*:", get)):
        fail("a has* line in the server's GET route is not one this guard understands")
    # The rule re-derives each flag from the raw field, so it is only right while the GET
    # sends that field unmasked: a server that masked a secret but kept computing its flag
    # from the real value would flip every Configured badge on the mirror path.
    for k in swift_keys:
        if get.count("%s: settings.%s," % (k, k)) != 1:
            fail("the server's GET no longer passes %s: settings.%s verbatim; re-deriving has* from a masked field would read Not configured" % (k, k))
    ours = {"has" + k[0].upper() + k[1:]: k for k in swift_keys}
    if len(ours) != len(swift_keys) or ours != server:
        fail("presenceFlaggedKeys %r is not the server's has* family %r" % (sorted(swift_keys), sorted(server.values())))
    print("PASS: presenceFlaggedKeys equals the %d has* flags the server's GET computes (#184)" % len(server))

# The simulator seam's byte-exact Keychain backup copies secrets into sibling items, so it
# must never exist in a Release build: both definitions sit inside one #if DEBUG block,
# and nothing outside a #if DEBUG block calls them.
def in_debug(text):
    """Per line: inside the #if DEBUG branch itself (not its #else/#elseif), at any depth."""
    stack, flags = [], []
    for line in text.split("\n"):
        t = line.strip()
        if t.startswith("#if "):
            stack.append(t == "#if DEBUG")
        elif t.startswith("#elseif") or t == "#else":
            if stack:
                stack[-1] = False
        elif t == "#endif":
            if stack:
                stack.pop()
        flags.append(any(stack))
    return flags

def line_of(text, offset):
    return text.count("\n", 0, offset)

src_debug = in_debug(src)
for name in ("static func selfTestBackup()", "static func selfTestRestore()"):
    if src.count(name) != 1:
        fail("expected exactly one %r in ApiSchemeHandler.swift" % name)
    if not src_debug[line_of(src, src.index(name))]:
        fail("%s is outside #if DEBUG; the seam's Keychain backup would ship in Release" % name)
for path in ("Dobby/Web/ApiSchemeHandler.swift", "Dobby/Web/SettingsSelfTest.swift"):
    text = strip_swift(open(path).read(), path)
    flags = in_debug(text)
    for m in re.finditer(r"\bselfTest(Backup|Restore)\(\)", text):
        if not flags[line_of(text, m.start())]:
            fail("%s reaches selfTest%s() outside #if DEBUG" % (path, m.group(1)))

print("PASS: every 200 dobby-api://settings answer, mirror hit and Pi fetch, has its has* flags derived inside settingsOutcome before serveSettings hands it to the task, and the seam's Keychain backup is DEBUG only (#184)")
PRESENCEPY

# #185: a settings save the Keychain refuses is not answered 200. The decision is pinned as
# values in ApiSchemeHandlerCheck.settingsWriteAnswerRule; these pin that every Keychain status
# reaches it (containment) and that it is decided before the page is answered (order), with
# comments stripped first and the stripper itself tested.
python3 - <<'KEYCHAINSTATUSPY'
import os
import re
import sys
sys.path.insert(0, "Tests")
from swift_strip import strip_swift

def fail(msg):
    sys.stderr.write("FAIL: %s (#185)\n" % msg)
    sys.exit(1)

def locate(scope, needle, what, start=0):
    # A missing anchor is a named FAIL, never a ValueError traceback (#190).
    try:
        return scope.index(needle, start)
    except ValueError:
        fail("%s: anchor %r is missing" % (what, needle))

src = strip_swift(open("Dobby/Web/ApiSchemeHandler.swift").read(), "ApiSchemeHandler.swift")

def body(scope, start, what):
    if scope.count(start) != 1:
        fail("%s: expected exactly one %r" % (what, start))
    a = locate(scope, start, what)
    return scope[a:locate(scope, "\n    }\n", what + " end", a)]

def lines(text):
    return [l.strip() for l in text.split("\n")]

store = src[locate(src, "enum SettingsMirrorStore {", "SettingsMirrorStore"):]

# 1. The one Keychain write: both calls captured, and the function answers with them.
for call in ("SecItemUpdate(", "SecItemAdd("):
    if src.count(call) != 1 or store.count(call) != 1:
        fail("expected exactly one %s, inside SettingsMirrorStore.write" % call)
write = body(store, "private static func write(_ base: [String: Any], _ body: Data) -> OSStatus {", "write")
wl = lines(write)
for need in ["let updated = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)",
             "if updated == errSecSuccess { return updated }",
             "let added = SecItemAdd(insert as CFDictionary, nil)"]:
    if need not in wl:
        fail("SettingsMirrorStore.write no longer captures its Keychain status: missing %r" % need)
returns = [l for l in wl if re.search(r"\breturn\b", l)]
if returns != ["guard !body.isEmpty else { return errSecParam }",
               "if updated == errSecSuccess { return updated }",
               "return updated",
               "return added"]:
    fail("SettingsMirrorStore.write must return errSecParam for an empty body, the update's status "
         "on success or on any refusal but not-found, and otherwise the add's, nothing else; got %r" % returns)
if locate(wl, "let updated = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)", "write") > locate(wl, "if updated == errSecSuccess { return updated }", "write") \
        or locate(wl, "let added = SecItemAdd(insert as CFDictionary, nil)", "write") > locate(wl, "return added", "write"):
    fail("SettingsMirrorStore.write returns a status before the call that produces it")
# Round 2: the add is reached only when the update found no item, and nothing is deleted first.
# Any other refusal leaves the item as it was: delete-then-add on, say, a locked device lost the
# whole mirror (or a queued patch answered 200 earlier) when the add was refused too.
if "SecItemDelete(" in write:
    fail("SettingsMirrorStore.write deletes the item: a refused add after it destroys the only good copy")
gate = ["let updated = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)",
        "if updated == errSecSuccess { return updated }",
        "guard updated == errSecItemNotFound else {",
        'log.error("keychain write failed: OSStatus \\(updated, privacy: .public)")',
        "return updated",
        "}",
        "var insert = base",
        "insert.merge(attributes) { _, new in new }",
        "let added = SecItemAdd(insert as CFDictionary, nil)",
        'if added != errSecSuccess { log.error("keychain write failed: OSStatus \\(added, privacy: .public)") }',
        "return added"]
at = locate(wl, gate[0], "write")
if wl[at:] != gate:
    fail("SettingsMirrorStore.write must be, from the update on, exactly: update, success return, "
         "the errSecItemNotFound guard returning (and logging) any other status, then the add; got %r" % wl[at:])

# 2. Every write's status is used. Only the two keep-going mirror saves may discard it, only the
#    DEBUG restore (verified by read-back) may discard write's, and the POST keeps both.
if re.search(r"^\s*write\(", store, re.M) or re.search(r"^\s*SettingsMirrorStore\.(save|queuePatch)\(", src, re.M):
    fail("a Keychain write is called as a bare statement, its status dropped")
if "static func save(_ body: Data) -> OSStatus { write(baseQuery, body) }" not in lines(store):
    fail("SettingsMirrorStore.save no longer returns write's status")
queue = body(store, "static func queuePatch(_ patch: Data) -> OSStatus {", "queuePatch")
ql = lines(queue)
if "let queued = write(pendingQuery, accumulated)" not in ql or ql[-1] != "return queued" \
        or [l for l in ql if re.search(r"\breturn\b", l)][-1] != "return queued":
    fail("queuePatch no longer returns the queue write's status")
discards = [l for l in lines(src) if l.startswith("_ = ") and ("write(" in l or "save(" in l or "queuePatch(" in l)]
if sorted(discards) != ["_ = write(baseQuery, previous)", "_ = write(live, held)"]:
    fail("only the DEBUG restore and the mirror put-back may discard write's status as a statement; got %r" % discards)
put_back = body(store, "static func restoreMirror(_ previous: Data?) {", "restoreMirror")
if lines(put_back)[1:] != [
        "guard let previous else {",
        "let removed = SecItemDelete(baseQuery as CFDictionary)",
        'if removed != errSecSuccess { log.error("keychain mirror put-back failed: OSStatus \\(removed, privacy: .public)") }',
        "return",
        "}",
        "_ = write(baseQuery, previous)"]:
    fail("restoreMirror must remove the mirror item when there was none, else write the previous bytes "
         "back to the mirror item, logging a refused delete; got %r" % lines(put_back)[1:])
if "_ = write(live, held)" not in lines(body(store, "static func selfTestRestore() -> String {", "selfTestRestore")):
    fail("the DEBUG restore's discarded write moved")
if "guard write(item, held) == errSecSuccess, read(item) == held else { return false }" not in lines(store):
    fail("the DEBUG backup no longer refuses the round on a refused write")
kept_going = ["if outcome.store && (mirrorRead == errSecSuccess || mirrorRead == errSecItemNotFound) { _ = SettingsMirrorStore.save(outcome.body) }",
              "if let fresh = Self.fetchSettings(from: self.server) { _ = SettingsMirrorStore.save(fresh) }"]
saves = [l for l in lines(src) if "SettingsMirrorStore.save(" in l]
if sorted(saves) != sorted(kept_going + ["if stored == errSecSuccess || stored == errSecItemNotFound { stored = SettingsMirrorStore.save(merged) }"]):
    fail("the mirror saves are not exactly the POST's checked one and the two keep-going ones: %r" % saves)
if [l for l in lines(src) if "SettingsMirrorStore.queuePatch(" in l] != ["stored = SettingsMirrorStore.queuePatch(patch)"]:
    fail("the queued patch's status no longer reaches the POST answer")

# 3. The POST leg: every status reaches settingsWriteAnswer, which decides before the respond.
serve = body(src, "private func serveSettings(", "serveSettings")
post = serve[locate(serve, '        if method == "POST" {', "the settings POST"):locate(serve, "        let (mirror, mirrorRead) = SettingsMirrorStore.loadWithStatus()", "the settings GET")]
seq = ["            var stored = mirrorRead",
       "            if stored == errSecSuccess || stored == errSecItemNotFound { stored = SettingsMirrorStore.save(merged) }",
       "            if stored == errSecSuccess {",
       "                SettingsMirrorStore.markAheadOfServer()",
       "                stored = SettingsMirrorStore.queuePatch(patch)",
       "                if stored != errSecSuccess { SettingsMirrorStore.restoreMirror(previous) }",
       "            }",
       "            let answer = Self.settingsWriteAnswer(stored)",
       "            status = answer.status",
       "            length = answer.body.count",
       '            respond(task, id, status: answer.status, contentType: "application/json",',
       "                    body: answer.body, origin: origin, secret: true,"]
at = post.find("\n".join(seq))
if at < 0:
    fail("the settings POST no longer starts from the mirror read's status, saves only when that read "
         "succeeded or found no item (#189), then (only on success) marks, queues and (only on a "
         "refused queue) puts the mirror back, then builds its answer from the status, then responds "
         "with that answer, as consecutive lines")
# Round 2: the put-back's bytes are read before the save overwrites them, once, and are the
# merge base too; the put-back runs once, only inside the refused-queue branch pinned above.
# #189: that one read carries its status, and the status is read before the merge and the save.
pl = post.split("\n")
loads = [i for i, l in enumerate(pl) if re.search(r"SettingsMirrorStore\.load(WithStatus)?\(\)", l)]
merge_at = [i for i, l in enumerate(pl) if l.strip() == "let merged = Self.mergedSettings(base: previous, patch: patch) else {"]
if [pl[i] for i in loads] != ["            let (previous, mirrorRead) = SettingsMirrorStore.loadWithStatus()"] \
        or len(merge_at) != 1 or not loads[0] < merge_at[0] < locate(pl, seq[0], "the settings POST"):
    fail("the settings POST must read the mirror exactly once, with its status, as let (previous, mirrorRead), "
         "before the merge onto those bytes and before save(merged)")
if post.count("mirrorRead") != 2:
    fail("the mirror read's status is used on the settings POST other than as the start of stored (#189)")
if src.count("restoreMirror(") != 2 or post.count("restoreMirror(") != 1 or post.count("previous") != 3:
    fail("the mirror put-back is reached other than once, from the settings POST's refused-queue branch")
if len(re.findall(r"\brespond\(", post)) != 1 or post.count("settingsWriteAnswer(") != 1 \
        or post.count("stored") != 8:
    fail("the settings POST answers other than once from settingsWriteAnswer(stored), or reads a "
         "status the answer never sees")
if re.search(r"status:\s*200|status = 200", post):
    fail("the settings POST answers a literal 200 again, so a refused save still reads as done")

# #189: the one Keychain read reports its status, read() is derived from it, and only the POST
# and (#193) the GET take the status-returning mirror read (imdbAuthToken keeps load()).
if src.count("SecItemCopyMatching(") != 1:
    fail("expected exactly one SecItemCopyMatching, inside SettingsMirrorStore.readWithStatus (#189)")
rws = body(store, "private static func readWithStatus(_ base: [String: Any]) -> (data: Data?, status: OSStatus) {", "readWithStatus")
if lines(rws)[-2:] != ["let status = SecItemCopyMatching(q as CFDictionary, &item)",
                       "return (status == errSecSuccess ? item as? Data : nil, status)"]:
    fail("readWithStatus no longer returns the bytes only on errSecSuccess, with the read's own status (#189): %r" % lines(rws)[-2:])
for need in ["private static func read(_ base: [String: Any]) -> Data? { readWithStatus(base).data }",
             "static func load() -> Data? { read(baseQuery) }"]:
    if need not in lines(store):
        fail("missing %r (#189)" % need)
lws = body(store, "static func loadWithStatus() -> (data: Data?, status: OSStatus) {", "loadWithStatus")
if lines(lws)[1:] != ["let (data, status) = readWithStatus(baseQuery)",
                      "if status != errSecSuccess && status != errSecItemNotFound {",
                      'log.error("keychain mirror read refused: OSStatus \\(status, privacy: .public)")',
                      "}",
                      "return (data, status)"]:
    fail("loadWithStatus must return the mirror read's bytes and status, logging a refusal as the number only (#189): %r" % lines(lws)[1:])
if src.count("loadWithStatus()") != 3:
    fail("loadWithStatus is reached other than from the settings POST and GET (#189, #193)")

# 4. The rule itself: only errSecSuccess is a 200, and its body is {}.
rule = body(src, "static func settingsWriteAnswer(_ stored: OSStatus) -> (status: Int, body: Data) {", "settingsWriteAnswer")
rl = lines(rule)
if 'if stored == errSecSuccess { return (200, Data("{}".utf8)) }' not in rl or rule.count("200") != 1:
    fail("settingsWriteAnswer no longer answers 200 {} for errSecSuccess and only for it")

# 5. Logs: the OSStatus number and nothing else, on every write path the store has.
logs = re.findall(r"\blog\.\w+\(.*\)", store)
want = ['log.error("keychain write failed: OSStatus \\(added, privacy: .public)")',
        'log.error("keychain queue clear failed: OSStatus \\(deleted, privacy: .public)")',
        'log.error("keychain write failed: OSStatus \\(updated, privacy: .public)")',
        'log.error("keychain mirror put-back failed: OSStatus \\(removed, privacy: .public)")',
        'log.error("keychain mirror read refused: OSStatus \\(status, privacy: .public)")',
        'log.error("keychain queue read refused: OSStatus \\(status, privacy: .public)")']
for l in logs:
    if [m for m in re.findall(r"\\\((.*?)\)", l)
            if m not in ("%s, privacy: .public" % v for v in ("added", "deleted", "updated", "removed", "status"))]:
        fail("a SettingsMirrorStore log line interpolates more than the OSStatus: %s" % l)
if sorted(logs) != sorted(want):
    fail("the store's log lines are not exactly the six OSStatus lines: %r" % logs)
if "if added != errSecSuccess { " + want[0] + " }" not in lines(write):
    fail("write no longer logs a refused add")
clear = body(store, "static func clearPending(ifStill pushed: Data) {", "clearPending")
if "let deleted = SecItemDelete(pendingQuery as CFDictionary)" not in lines(clear) \
        or "if deleted != errSecSuccess { " + want[1] + " }" not in lines(clear):
    fail("clearPending no longer captures and logs its delete status")

# #193: a refused read of the queue or the mirror is never "no item". The queue: queuePatch reads
# with status and returns a refusal before any merge or write (merging over that nil replaced
# every older queued field); the drain and releaseHold release the hold only on errSecItemNotFound.
# The GET: a refused mirror read is answered with the Pi body as before but does not seed.
if lines(queue)[1:] != ["pendingLock.lock(); defer { pendingLock.unlock() }",
                        "let (pending, pendingRead) = readPending()",
                        "guard pendingRead == errSecSuccess || pendingRead == errSecItemNotFound else { return pendingRead }",
                        "guard let accumulated = ApiSchemeHandler.mergedPatch(pending: pending, patch: patch) else { return errSecParam }",
                        "let queued = write(pendingQuery, accumulated)",
                        "UserDefaults.standard.set(true, forKey: aheadKey)",
                        "return queued"]:
    fail("queuePatch must read the queue with its status and return a refusal (anything but success "
         "or no item) before the merge and the write, merging only the bytes that read returned (#193): %r" % lines(queue)[1:])
rp = body(store, "private static func readPending() -> (data: Data?, status: OSStatus) {", "readPending")
if lines(rp)[1:] != ["let (data, status) = readWithStatus(pendingQuery)",
                     "if status != errSecSuccess && status != errSecItemNotFound {",
                     'log.error("keychain queue read refused: OSStatus \\(status, privacy: .public)")',
                     "}",
                     "return (data, status)"]:
    fail("readPending must return the queue read's bytes and status, logging a refusal as the number only (#193): %r" % lines(rp)[1:])
if src.count("readWithStatus(pendingQuery)") != 1 or src.count("readPending()") != 4:
    fail("the queue's status read is not exactly readPending, reached from its declaration, queuePatch, "
         "pendingPatch and releaseHold (#193)")
plain = sorted(l for l in lines(src) if re.search(r"(?<![\w.])read\(pendingQuery\)", l))
if plain != ["guard read(pendingQuery) == pushed else { return }",
             "let mirror = read(baseQuery), pending = read(pendingQuery)"]:
    fail("the queue is read through the nil-on-refusal read() outside clearPending's compare and the "
         "DEBUG backup (#193): %r" % plain)
if lines(body(store, "static func pendingPatch() -> (data: Data?, status: OSStatus) {", "pendingPatch"))[1:] != [
        "pendingLock.lock(); defer { pendingLock.unlock() }", "return readPending()"]:
    fail("pendingPatch must answer readPending's bytes and status under the queue lock (#193)")
rh = lines(body(store, "static func releaseHold() {", "releaseHold"))
if rh[1:] != ["pendingLock.lock(); defer { pendingLock.unlock() }",
              "guard readPending().status == errSecItemNotFound else { return }",
              "UserDefaults.standard.set(false, forKey: aheadKey)"]:
    fail("releaseHold must release the hold only when the queue read, under the lock, found no item (#193): %r" % rh[1:])
drain = body(src, "private func drainPendingSettings() {", "drainPendingSettings")
dl = lines(drain)
dseq = ["guard SettingsMirrorStore.isAheadOfServer else { return }",
        "let (queued, pendingRead) = SettingsMirrorStore.pendingPatch()",
        "guard let pending = queued else {",
        "if pendingRead == errSecItemNotFound { SettingsMirrorStore.releaseHold() }",
        "return",
        "}"]
if dl[1:1 + len(dseq)] != dseq or drain.count("pendingPatch(") != 1 or drain.count("releaseHold(") != 1 \
        or drain.count("pendingRead") != 2 or src.count("releaseHold()") != 2:
    fail("the drain must start from the hold, read the queue with its status, and with no bytes release "
         "the hold only on errSecItemNotFound and return, pushing nothing (#193): %r" % dl[1:1 + len(dseq)])
get = serve[locate(serve, "        let (mirror, mirrorRead) = SettingsMirrorStore.loadWithStatus()", "the settings GET"):]
gseq = ["        let (mirror, mirrorRead) = SettingsMirrorStore.loadWithStatus()",
        '        source = (mirror?.isEmpty == false) ? "mirror" : "network"',
        "        let outcome = Self.settingsOutcome(mirror: mirror) {",
        "            Self.fetchSettings(from: server)",
        "        }",
        "        if outcome.store && (mirrorRead == errSecSuccess || mirrorRead == errSecItemNotFound) { _ = SettingsMirrorStore.save(outcome.body) }",
        "        status = outcome.status",
        "        length = outcome.body.count",
        '        respond(task, id, status: outcome.status, contentType: "application/json",',
        "                body: outcome.body, origin: origin, secret: true,"]
if not get.startswith("\n".join(gseq)) or get.count("mirrorRead") != 3 or len(re.findall(r"\brespond\(", get)) != 1:
    fail("the settings GET must read the mirror with its status, answer from settingsOutcome alone, "
         "seed only when that read succeeded or found no item, and use the status nowhere else (#193)")

# 6. The consumer end: the page's retry list, transcribed in ApiSchemeHandlerCheck, is the page's.
check_src = open("Tests/ApiSchemeHandlerCheck.swift").read()
m = re.search(r"static let pageRetryStatuses = \[([\d, ]+)\]", check_src)
if not m:
    fail("ApiSchemeHandlerCheck.pageRetryStatuses is gone")
ours = [int(x) for x in m.group(1).split(",")]
page = "../dobby/Sources/BookPlayServer/Public/js/03-storage-net.js"
if not os.path.isfile(page):
    print("SKIP: no sibling dobby checkout, the page's retry list is not compared (#185)")
else:
    pm = re.findall(r"var retryStatuses = options\.retryStatuses \|\| \[([\d, ]+)\];", open(page).read())
    if len(pm) != 1:
        fail("found %d fetchWithRetry retry lists in the page, expected one" % len(pm))
    if [int(x) for x in pm[0].split(",")] != ours:
        fail("pageRetryStatuses %r is not the page's fetchWithRetry list %r" % (ours, pm[0]))
    print("PASS: the transcribed retry list equals the page's fetchWithRetry list (#185)")

print("PASS: every SettingsMirrorStore Keychain write reports its OSStatus, the settings POST answers "
      "from it before responding (a refused save is a 507, never 200), a refused queue write puts the mirror "
      "back, a refused update is never followed by a delete, a refused mirror read answers 507 before any save "
      "(no-item still merges over nil) (#189), a refused queue or mirror read is never no item: it queues, releases "
      "and seeds nothing (#193), and the logs carry the number only (#185)")
KEYCHAINSTATUSPY

python3 - <<'TIMELABELWIDTHPY'
import sys
sys.path.insert(0, "Tests")
from swift_strip import strip_swift

path = "Dobby/Playback/PlayerView.swift"
src = strip_swift(open(path).read(), path)

if "Text(timeLabel(current, matching: total))" not in src:
    sys.stderr.write("FAIL: PlayerView's elapsed-time label no longer formats at the total's field width (#128)\n")
    sys.exit(1)
if "let showHours = h > 0 || total >= 3600" not in src:
    sys.stderr.write("FAIL: timeLabel(_:matching:) no longer pins the hours field to the total's own duration (#128)\n")
    sys.exit(1)
if 'String(format: totalMinutes >= 10 ? "%02d:%02d" : "%d:%02d", m, sec)' not in src:
    sys.stderr.write("FAIL: timeLabel(_:matching:) no longer pins the minutes field, so the elapsed label still grows crossing 10:00 (#128)\n")
    sys.exit(1)
if "Text(timeLabel(total, matching: total))" not in src:
    sys.stderr.write("FAIL: PlayerView's duration label no longer passes its own total, so the two labels can disagree on field width (#128)\n")
    sys.exit(1)

print("PASS: PlayerView's elapsed-time label shares the total's field width so scrubbing past 1:00:00 cannot reflow the Slider (#128)")
TIMELABELWIDTHPY

# ---------------------------------------------------------------------------
# #151 (M5-H) — the iOS Pi-less cold start: a bundled app shell, served under the
# Pi's origin by loadSimulatedRequest, with its sub-resources on dobby-offline://shell.
#
# scripts/copy-app-shell.sh is run first, for two reasons: it is itself under test
# (it parses sw.js's APP_SHELL literal, and a parser that silently produced a
# half-empty shell would ship a blank page), and BundledShellCheck holds the rewrite
# rule against the REAL index.html it copies rather than a fixture that can drift.
# ---------------------------------------------------------------------------
DOBBY_PUBLIC_DIR="${DOBBY_PUBLIC_DIR:-$PWD/../dobby/Sources/BookPlayServer/Public}"
if [ -d "$DOBBY_PUBLIC_DIR" ]; then
  DOBBY_PUBLIC_DIR="$DOBBY_PUBLIC_DIR" ./scripts/copy-app-shell.sh

  OUT7="$(mktemp -d)/bundled-shell-check"
  xcrun swiftc -o "$OUT7" \
    Dobby/Offline/BundledShell.swift Dobby/Offline/OfflineSchemeHandler.swift Tests/BundledShellCheck.swift
  "$OUT7" Dobby/Shell

  # The measurement, not a proxy: a real WKWebView, a real dead app-bound origin, the
  # shipped rewrite and the shipped handler. macOS only, same as ApiSchemeWebViewCheck —
  # it needs AppKit and a host that can start a web content process. It reuses that
  # check's embedded-Info.plist trick so App-Bound Domains is on exactly as in the app.
  if [ "$(uname -s)" = "Darwin" ]; then
    OUT8="$(mktemp -d)/bundled-shell-webview-check"
    xcrun swiftc -o "$OUT8" -framework WebKit -framework AppKit \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST4" \
      Dobby/AppConfig.swift Dobby/ServerAddresses.swift Dobby/Web/ApiSchemeHandler.swift \
      Dobby/Offline/BundledShell.swift Dobby/Offline/OfflineSchemeHandler.swift \
      Tests/BundledShellWebViewCheck.swift
    "$OUT8"
  fi
else
  echo "SKIP: no dobby checkout at $DOBBY_PUBLIC_DIR — BundledShellCheck and BundledShellWebViewCheck need the PWA's Public dir (#151)"
fi

# #151 wiring. Everything above runs the shell's pieces in isolation: the rewrite as a
# pure function, the handler behind a WKWebView the CHECK configures. None of it observes
# whether the app ever takes the offline branch — the exact "helper pinned, call site
# not" shape this ledger keeps getting bitten by. Four things, each an exact single-line
# construct, and position where position is the meaning.
python3 - <<'SHELLWIRINGPY'
import sys

def read(path):
    with open(path) as f:
        return f.read()
web = read("Dobby/Web/WebContainer.swift")
content = read("Dobby/ContentView.swift")
project = read("project.yml")

def need(haystack, needle, why):
    if needle not in haystack:
        sys.stderr.write("FAIL: " + why + "\nexpected to find, verbatim:\n  " + needle + "\n")
        sys.exit(1)

# 1. makeWebView hands the load to the helper. Without this line the helper is dead code
#    and every offline start is the pre-#151 plain load — green everywhere else.
need(web, "        load(loadURL, in: webView)",
     "WebContainer.makeWebView must route its load through load(_:in:)")

# 2. Both branches of the helper, because the unpinned one is always the one that breaks
#    something else. The guard is what keeps loadSimulatedRequest OFF the Pi-backed path
#    (a mutant that drops `offlineShell,` synthesizes the shell even when the Pi answered,
#    which is a working-looking app that never talks to the Pi), and the fallback is what
#    a build with no bundled shell — every CI/TestFlight build today — still does.
need(web, "        guard offlineShell, let html = BundledShell.indexHTML() else {",
     "the simulated load must be guarded by BOTH offlineShell and a shell being present")
need(web, "            webView.load(URLRequest(url: loadURL))",
     "the no-shell / Pi-backed fallback must stay the ordinary load")
need(web, "        webView.loadSimulatedRequest(URLRequest(url: loadURL), responseHTML: html)",
     "the offline branch must synthesize the shell under loadURL, not load a file: or data: URL")

# 3. Position: the simulated load has to sit AFTER the guard's else-block, not before it.
#    A mutant hoisting it above the guard passes every `need` above while hijacking the
#    Pi-backed path, and nothing else in this suite runs WebContainer.
guard_at = web.index("guard offlineShell, let html = BundledShell.indexHTML() else {")
plain_at = web.index("webView.load(URLRequest(url: loadURL))")
simulated_at = web.index("webView.loadSimulatedRequest(")
if not guard_at < plain_at < simulated_at:
    sys.stderr.write("FAIL: in WebContainer.load, the guard must come first, then the plain-load fallback, then the simulated load\n")
    sys.exit(1)

# 4. ContentView: the flag reaches WebContainer at all (argument order included), and
#    "Continue offline" writes BOTH halves. Setting only serverURL is the pre-#151
#    behaviour — right for a paired box, a blank page for the never-paired one the shell
#    exists for — and no check above can see the difference.
need(content, "WebContainer(url: serverURL, offlineShell: offlineShell)",
     "ContentView must pass the offline-shell flag into WebContainer")
need(content, "    private func continueOffline() {\n        serverURL = ServerAddresses.candidates().first\n        offlineShell = true\n    }",
     "continueOffline() must set the origin AND the shell flag, in that order")
need(content, "                    offline: continueOffline", "the Continue offline button must call continueOffline")
need(content, "            continueOffline()", "the DOBBY_AUTO_OFFLINE seam must take the same action as the button")
# ...and a successful resolve must clear it, or a retry after an offline start keeps
# synthesizing the shell on a Pi that is now answering.
# #181 put the Pi-setting branch between the clear and the probe, so this is two
# needles in order rather than one contiguous one.
need(content, "        resolving = true\n        offlineShell = false\n",
     "resolve() must clear offlineShell before probing, so a Pi that came back is used")
if not content.index("        resolving = true\n        offlineShell = false\n") < content.index("serverURL = await ServerAddresses.resolve()"):
    sys.stderr.write("FAIL: resolve() must clear offlineShell before probing, so a Pi that came back is used\n")
    sys.exit(1)

# 5. project.yml: a folder REFERENCE. As a plain group Xcode's resource copy flattens
#    the tree, every file lands at the bundle root, and `dobby-offline://shell/js/...`
#    404s its own scripts — a blank page that builds clean.
need(project, "      - path: Dobby/Shell\n        type: folder",
     "Dobby/Shell must be a folder reference in project.yml, or the shell's paths are flattened")
need(project, "      - path: scripts/copy-app-shell.sh",
     "copy-app-shell.sh must run as a preBuildScript, or the bundled shell goes stale")
if project.index("- path: scripts/copy-app-shell.sh") < project.index("preBuildScripts:"):
    sys.stderr.write("FAIL: copy-app-shell.sh must be listed under preBuildScripts\n")
    sys.exit(1)
if "excludes:\n          - Shell" not in project:
    sys.stderr.write("FAIL: Dobby/Shell must be excluded from the Dobby source glob, or it is added twice\n")
    sys.exit(1)

print("PASS: the Pi-less cold start is wired — makeWebView calls load(_:in:), only the offline branch synthesizes the shell, ContentView sets both halves, and Dobby/Shell ships as a folder reference (#151)")
SHELLWIRINGPY

# ---------------------------------------------------------------------------
# #152 (M5 follow-up) — the iOS settings write-back: drain, then pull.
#
# ApiSchemeHandlerCheck pins the two pure rules as values: what the queue
# accumulates (patches, never the seed), and what a push status means for the hold.
# What no value-level check can reach is the wiring — that the drain runs at all,
# that it runs BEFORE the #149 ahead-guard rather than after the `return`, that what
# goes on the wire is the queued PATCH and never the mirrored document, and that the
# hold is released only by a push the Pi actually answered. Exact single-line
# constructs, and position where position is the meaning.
# ---------------------------------------------------------------------------
python3 - <<'SETTINGSWRITEBACKPY'
import sys

path = "Dobby/Web/ApiSchemeHandler.swift"
with open(path) as f:
    src = f.read()

def fail(message, needle=None):
    sys.stderr.write("FAIL: " + message + " (#152)\n")
    if needle is not None:
        sys.stderr.write("expected to find, verbatim:\n  " + needle + "\n")
    sys.exit(1)

def need(haystack, needle, message):
    if needle not in haystack:
        fail(message, needle)

def body_of(signature):
    if signature not in src:
        fail("no such declaration any more: " + signature, signature)
    start = src.index(signature)
    return src[start:src.index("\n    }\n", start)]

# 1. The POST leg keeps the PATCH BYTES. Without this line the merge is still stored
#    and the mirror still marked ahead — every #149 check stays green — while there
#    is nothing to push, so the hold never releases and the phone is exactly as
#    permanently stuck as before. The argument is the raw `patch`, not `merged`:
#    pushing the merged document would carry the seed's explicit nulls.
need(src, "                stored = SettingsMirrorStore.queuePatch(patch)",
     "the settings POST no longer queues the patch bytes, so a write made with the Pi off "
     "is never pushed and the ahead-of-server hold never releases")

# ...and it comes AFTER markAheadOfServer() and before the acknowledgement. Queue
# before mark leaves a window in which a drain can land, clear the queue and release
# the hold, and then markAheadOfServer() re-takes a hold with nothing queued behind
# it — held forever, the exact bug. queuePatch re-takes the hold itself, under the
# queue's own lock, which is what makes this order the safe one.
mark_idx = src.index("                SettingsMirrorStore.markAheadOfServer()")
queue_idx = src.index("                stored = SettingsMirrorStore.queuePatch(patch)")
ack_idx = src.index('            respond(task, id, status: answer.status, contentType: "application/json",')
if not mark_idx < queue_idx < ack_idx:
    fail("the settings POST queues the patch before it marks the mirror ahead, or after it has "
         "already acknowledged the write")

# 2. The drain is RUN, and it runs before the guard that returns. Below the guard it
#    is unreachable code in the only state it exists for, and nothing else in this
#    suite executes refreshSettingsInBackground.
refresh = body_of("private func refreshSettingsInBackground() {")
need(refresh, "        drainPendingSettings()",
     "refreshSettingsInBackground no longer drains the queued patch, so the #149 hold is "
     "still set once and never cleared")
guard_line = "if SettingsMirrorStore.isAheadOfServer { return }"
if refresh.index("        drainPendingSettings()") > refresh.index(guard_line):
    fail("the drain sits after the ahead-of-server guard, which returns — so it never runs")

# 3. The drain's own body. Both halves: the patch is read from the QUEUE, and the
#    legacy hold with nothing behind it is released rather than held forever (every
#    phone already running the #149 build is in that state after upgrading).
drain = body_of("private func drainPendingSettings() {")
for needle, message in [
    ("        guard SettingsMirrorStore.isAheadOfServer else { return }",
     "the drain no longer starts from the hold, so it pushes on every settings GET"),
    ("        let (queued, pendingRead) = SettingsMirrorStore.pendingPatch()\n        guard let pending = queued else {",
     "the drain no longer takes its bytes from the queue"),
    ("            if pendingRead == errSecItemNotFound { SettingsMirrorStore.releaseHold() }",
     "a hold with nothing queued behind it is no longer released, so a phone upgrading from "
     "the #149 build stays permanently stuck"),
    ("            switch Self.pushSettings(pending, to: self.server) {",
     "the drain no longer pushes the queued patch to the Pi"),
    ("            case .landed, .refused:", "the drain no longer distinguishes a push that ended the hold"),
    ("                SettingsMirrorStore.clearPending(ifStill: pending)",
     "the drain no longer releases the hold against the exact bytes it pushed"),
    ("            case .held:", "the drain no longer has a branch that keeps the patch queued"),
    ("        if drainInFlight { refreshing.unlock(); return }",
     "the drain lost its single-flight guard, so a boot that reads settings twice POSTs the "
     "user's secrets twice"),
]:
    need(drain, needle, message)

# THE trap, as an absence. Pushing the mirrored document in the queue's place is the
# naive fix that looks right and clears live values on the Pi: POST /api/settings
# applies preferredSubtitleLanguage and preferredAudioLanguage by body PRESENCE
# (SettingsRoutes.swift:86-90), so the seed's explicit nulls would blank both for a
# device that never touched either.
push = body_of("private static func pushSettings(_ patch: Data, to server: URL) -> PushOutcome {")
for scope, label in [(drain, "the drain"), (push, "the push")]:
    for forbidden in ["SettingsMirrorStore.load()", "mergedSettings", "seedSettingsJson", "settingsSeed"]:
        if forbidden in scope:
            fail(label + " reaches for the mirrored document (" + forbidden + "); only the queued "
                 "patch may be pushed, or the Pi's live language values are cleared by a stale "
                 "mirror's nulls")

# 4. The push sends the patch as the body, with the method the Pi's route takes.
for needle, message in [
    ('        request.httpMethod = "POST"', "the push no longer uses the method POST /api/settings takes"),
    ("        request.httpBody = patch", "the push no longer sends the queued patch as its body"),
    ("        return pushOutcome(status: http?.statusCode)",
     "the push no longer routes its status through the pinned outcome rule"),
]:
    need(push, needle, message)

# 5. Position inside the drain: the clear is INSIDE the landed/refused case and after
#    the push. Hoisted above the switch — or added to the .held branch — it releases
#    the hold for a change the Pi never took, which loses the user's key. That mutant
#    passes every `need` above.
push_at = drain.index("            switch Self.pushSettings(pending, to: self.server) {")
landed_at = drain.index("            case .landed, .refused:")
clear_at = drain.index("                SettingsMirrorStore.clearPending(ifStill: pending)")
held_at = drain.index("            case .held:")
if not push_at < landed_at < clear_at < held_at:
    fail("the queue is cleared outside the landed/refused case, or before the push — the hold "
         "must only be released by a push the Pi actually answered")
if drain.count("SettingsMirrorStore.clearPending(") != 1:
    fail("there is more than one path that releases the hold in the drain")

# 6. clearPending is a compare-and-delete, in that order. The compare is what stops a
#    save that landed mid-push from being thrown away with the confirmation of the
#    older one — that mutant loses the user's latest change AND releases the hold in
#    the same step. Clearing the bit before the delete leaves the mirror unprotected
#    with the patch still queued.
clear = body_of("static func clearPending(ifStill pushed: Data) {")
for needle, message in [
    ("        pendingLock.lock(); defer { pendingLock.unlock() }",
     "clearPending no longer takes the queue lock, so it can interleave with a page write"),
    ("        guard read(pendingQuery) == pushed else { return }",
     "clearPending no longer checks that what is queued is still what was pushed"),
    ("        let deleted = SecItemDelete(pendingQuery as CFDictionary)", "clearPending no longer removes the queued patch"),
    ("        UserDefaults.standard.set(false, forKey: aheadKey)", "clearPending no longer releases the hold"),
]:
    need(clear, needle, message)
if not (clear.index("pendingLock.lock()")
        < clear.index("guard read(pendingQuery) == pushed")
        < clear.index("SecItemDelete(pendingQuery")
        < clear.index("UserDefaults.standard.set(false, forKey: aheadKey)")):
    fail("clearPending releases the hold before it has checked the queued bytes and removed them")

# 7. queuePatch accumulates through mergedPatch, not mergedSettings. The helper is
#    pinned as values in ApiSchemeHandlerCheck; this is its call site, and swapping
#    it for the seeded merge is green everywhere else while it queues nine keys whose
#    nulls clear the Pi's two language fields.
queue_fn = body_of("static func queuePatch(_ patch: Data) -> OSStatus {")
for needle, message in [
    ("        pendingLock.lock(); defer { pendingLock.unlock() }",
     "queuePatch no longer takes the queue lock, so a drain can clear a patch mid-write"),
    ("        guard let accumulated = ApiSchemeHandler.mergedPatch(pending: pending, patch: patch) else { return errSecParam }",
     "queuePatch no longer accumulates through mergedPatch — the seeded merge would queue nine "
     "keys and clear the Pi's language fields, and replacing instead of accumulating would drop "
     "an earlier Pi-less save"),
    ("        let queued = write(pendingQuery, accumulated)", "queuePatch no longer stores the accumulated patch"),
    ("        UserDefaults.standard.set(true, forKey: aheadKey)",
     "queuePatch no longer re-takes the hold under the lock, so a drain landing in the sliver "
     "after markAheadOfServer() leaves a queued patch with the mirror unprotected"),
]:
    need(queue_fn, needle, message)
if queue_fn.index("write(pendingQuery, accumulated)") > queue_fn.index("UserDefaults.standard.set(true"):
    fail("queuePatch takes the hold before the patch is actually stored")

# 8. releaseHold re-checks under the lock. Without it, a patch queued between the
#    drain's look and this call is abandoned with the hold.
release = body_of("static func releaseHold() {")
need(release, "        guard readPending().status == errSecItemNotFound else { return }",
     "releaseHold no longer re-checks the queue under the lock, so it can release a hold that "
     "a patch queued meanwhile still needs")

# 9. The queued patch is a settings body: it carries every secret the user just typed,
#    so it lives in the Keychain beside the mirror, never in a plist a backup hands
#    over in the clear. The only UserDefaults line allowed near the patch is the bit.
need(src, '    private static let pendingAccount = "api/settings.pending"',
     "the queue is no longer its own Keychain item beside the mirror")
need(src, "    private static var pendingQuery: [String: Any] { query(pendingAccount) }",
     "the queue's Keychain query no longer uses its own account, so it would collide with the mirror")
for scope, label in [(queue_fn, "queuePatch"), (clear, "clearPending"),
                     (body_of("static func pendingPatch() -> (data: Data?, status: OSStatus) {"), "pendingPatch")]:
    for line in scope.splitlines():
        if "UserDefaults" in line and "aheadKey" not in line:
            fail(label + " puts something other than the hold bit in UserDefaults; the queued patch "
                 "carries secrets and belongs in the Keychain")

need(src, "    private var drainInFlight = false",
     "the drain lost its own single-flight flag")

print("PASS: the iOS settings write-back drains before it pulls, pushes only the queued patch, "
      "and releases the hold only against the exact bytes a push landed (#152)")
SETTINGSWRITEBACKPY

# ---------------------------------------------------------------------------
# #155 — the TestFlight release actually carries the #151 shell, and a build that
# doesn't gets said out loud somewhere a human sees it without a debugger.
# ---------------------------------------------------------------------------

# 1. copy-app-shell.sh's no-sibling branch must WIPE Dobby/Shell before bailing, not
#    just ensure the directory exists — otherwise a rebuild that LOSES the sibling
#    (a CI checkout step failing after an earlier one succeeded, a local sibling
#    removed between builds) keeps whatever shell an earlier build already copied
#    here, silently stale instead of correctly degrading to none. Proven live:
#    pre-seed Dobby/Shell with a stray file, run the script pointed at a sibling
#    that does not exist, and check the file is gone.
python3 - <<'SHELLWIPEPY'
import os
import subprocess
import sys
import tempfile

repo = os.getcwd()
shell_dir = os.path.join(repo, "Dobby/Shell")
os.makedirs(shell_dir, exist_ok=True)
stray = os.path.join(shell_dir, "stale-from-a-previous-build.txt")
with open(stray, "w") as f:
    f.write("leftover")

env = dict(os.environ)
env["DOBBY_PUBLIC_DIR"] = tempfile.mkdtemp() + "-does-not-exist"
result = subprocess.run(["./scripts/copy-app-shell.sh"], cwd=repo, env=env, capture_output=True, text=True)
if result.returncode != 0:
    sys.stderr.write(f"FAIL: copy-app-shell.sh must exit 0 with no sibling checkout, got {result.returncode}\n{result.stderr}\n")
    sys.exit(1)
if os.path.exists(stray):
    sys.stderr.write("FAIL: copy-app-shell.sh's no-sibling branch left a stale Dobby/Shell file in place instead of wiping it (#155)\n")
    sys.exit(1)
if not os.path.isfile(os.path.join(shell_dir, ".gitkeep")):
    sys.stderr.write("FAIL: copy-app-shell.sh's no-sibling branch must still leave Dobby/Shell/.gitkeep so the folder reference survives (#155)\n")
    sys.exit(1)

print("PASS: copy-app-shell.sh wipes a stale Dobby/Shell when the sibling checkout is gone, instead of shipping stale content (#155)")
SHELLWIPEPY

# This check's own fixture must not be the reason a human re-running checks locally
# right after sees an empty Dobby/Shell — put the real one back, same guard as the
# #151 block above uses to decide whether it has one to put back at all.
if [ -d "$DOBBY_PUBLIC_DIR" ]; then
  DOBBY_PUBLIC_DIR="$DOBBY_PUBLIC_DIR" ./scripts/copy-app-shell.sh
fi

# 2. ContentView: the screen a never-paired device actually lands on must say
#    whether THIS build can cold-start Pi-less at all, driven by the same
#    BundledShell.root the offline load itself branches on, or the two can disagree.
python3 - <<'CONTENTVIEWPY'
import sys

path = "Dobby/ContentView.swift"
with open(path) as f:
    src = f.read()

def need(needle, why):
    if needle not in src:
        sys.stderr.write("FAIL: " + why + "\nexpected to find, verbatim:\n  " + needle + "\n")
        sys.exit(1)

need("if BundledShell.root == nil {",
     "ServerUnreachableView must gate a signal on BundledShell.root, or a shell-less build says nothing on the screen a never-paired device lands on (#155)")
need('Text("This build has no offline shell — Continue offline will be blank.")',
     "the no-shell caption text changed or was removed (#155)")

# Position, scoped to ServerUnreachableView itself (ContentView's own top-level
# `} else {` sits earlier in the file, around its WebContainer/ServerUnreachableView
# switch, and would satisfy an unscoped ordering check without the caption existing
# in the right branch at all). The caption must sit in the not-resolving branch,
# after the "Continue offline" button — a mutant that hoists the BundledShell.root
# check above `if resolving` would show it on the "Finding Dobby…" screen too,
# before the app has even decided offline mode is in play.
view_at = src.index("struct ServerUnreachableView")
scoped = src[view_at:]
resolving_at = scoped.index("if resolving {")
else_at = scoped.index("} else {")
offline_button_at = scoped.index('Button("Continue offline", action: offline)')
guard_at = scoped.index("if BundledShell.root == nil {")
if not (resolving_at < else_at < offline_button_at < guard_at):
    sys.stderr.write("FAIL: the no-shell caption must sit after 'Continue offline', inside the not-resolving branch (#155)\n")
    sys.exit(1)

print("PASS: ServerUnreachableView tells a never-paired device whether this build has an offline shell before it taps Continue offline (#155)")
CONTENTVIEWPY

# 3. The workflow: a sibling checkout that lands where copy-app-shell.sh already
#    looks, and an archive-time guard that refuses to export/upload a shell-less
#    build rather than letting it through the way #151 review deliberately let the
#    SCRIPT do for an ordinary dobby-ios-only build. Textual only — run-checks.sh
#    does not invoke xcodebuild, so this cannot see whether GitHub Actions itself
#    accepts the YAML; that was checked separately with a real xcodebuild archive.
python3 - <<'WORKFLOWPY'
import sys

path = ".github/workflows/testflight.yml"
with open(path) as f:
    wf = f.read()

def need(needle, why):
    if needle not in wf:
        sys.stderr.write("FAIL: " + why + "\nexpected to find, verbatim:\n  " + needle + "\n")
        sys.exit(1)

need("repository: ventsislav-georgiev/bookplay",
     "testflight.yml must check out the PWA repo as a sibling, or scripts/copy-app-shell.sh finds no dobby checkout and every release still ships without the #151 shell (#155)")
need("token: ${{ secrets.DOBBY_PWA_CHECKOUT_TOKEN }}",
     "the sibling checkout needs a token wider than the default GITHUB_TOKEN to reach a private repo (#155)")
need("path: dobby-ios",
     "the dobby-ios checkout must get its own explicit path so the sibling checkout lands next to it, not inside it (#155)")
need("path: dobby\n",
     "the sibling checkout must land at a path literally named dobby, matching copy-app-shell.sh's default ../dobby (#155)")
need("working-directory: dobby-ios",
     "moving the checkout to its own path without pointing every run: step back at it would break the whole workflow (#155)")

need("name: Verify the app shell was bundled", "the archive-time shell guard step was removed or renamed (#155)")
need("build/Dobby.xcarchive/Products/Applications/Dobby.app/Shell/index.html",
     "the shell guard must check the shipped .app bundle's Shell/index.html, not a pre-archive path (#155)")
# The step name is quoted in a comment above the earlier checkout step too (it
# points forward at this one), so anchor on the actual "name:" key, not the bare
# phrase, or this passes on the comment alone with the real step missing.
verify_at = wf.index("name: Verify the app shell was bundled")
archive_at = wf.index("name: Archive")
export_at = wf.index("name: Export .ipa")
if not (archive_at < verify_at < export_at):
    sys.stderr.write("FAIL: the shell guard must run after Archive and before Export .ipa, or a shell-less build still gets exported and uploaded (#155)\n")
    sys.exit(1)
if "exit 1" not in wf[verify_at:export_at]:
    sys.stderr.write("FAIL: the shell guard must actually fail the job (exit 1) when the shell is missing, not just warn (#155)\n")
    sys.exit(1)

# -s and not -e, and pinned because the two halves are not the same guard. A
# shell that is MISSING and a shell that is PRESENT BUT EMPTY reach TestFlight
# the same way and blank the same never-paired phone, and an empty file is the
# likelier of the two: copy-app-shell.sh recreates the directory before it
# copies, so an interrupted or partial copy leaves exactly a zero-byte
# index.html. Measured: with -e in place of -s every check in this suite still
# passed (#155 review).
if "! -s " not in wf[verify_at:export_at]:
    sys.stderr.write("FAIL: the shell guard tests existence rather than content, so a zero-byte "
                     "index.html ships to TestFlight and blanks a never-paired phone (#155)\n")
    sys.exit(1)

print("PASS: the TestFlight workflow checks out the PWA shell source as a sibling and refuses to export/upload an archive that shipped without it (#155)")
WORKFLOWPY

# ---------------------------------------------------------------------------
# #167 — TestFlight could never build at all: the app shell manifest resolves
# /playsvideo/assets/bundle.js against Public/playsvideo/assets, which is
# gitignored in the PWA repo (build output, not source), so no checkout —
# CI's included — ever had it. The playsvideo repo now publishes that
# directory as a release asset; testflight.yml fetches it before Archive.
#
# Six separate assertions, not one combined check: a single check cannot
# tell WHICH of six ways this silently regresses, and this ledger already
# has eighteen recorded instances of exactly that failure mode.
#
# Comments are stripped before every textual pin below. A pin that reads raw
# source is satisfied by a comment quoting the literal with the real thing
# missing — a defect this ledger has already paid for once.
python3 - <<'BUNDLEFETCHPY'
import sys

def strip_comments(text):
    # Two shapes, and the second one is why: a trailing " #" comment is the
    # common case, but a WHOLE-LINE comment starting at column zero has no
    # space before its "#", so splitting on " #" leaves it intact and a pin
    # reading this text is satisfied by a comment quoting the literal with
    # the real line deleted. Measured: that mutant passed the six checks
    # below before this branch was added.
    kept = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        kept.append(line.split(" #", 1)[0])
    return "\n".join(kept)

wf_path = ".github/workflows/testflight.yml"
with open(wf_path) as f:
    wf = strip_comments(f.read())

sh_path = "scripts/copy-app-shell.sh"
with open(sh_path) as f:
    sh = strip_comments(f.read())

def need(haystack, needle, why):
    if needle not in haystack:
        sys.stderr.write("FAIL: " + why + "\nexpected to find, verbatim:\n  " + needle + "\n")
        sys.exit(1)

need(wf, "name: Fetch playsvideo bundle asset",
     "the step that fetches the playsvideo bundle release asset was removed or renamed (#167)")

# 1. Names the source repo the asset comes from.
need(wf, "--repo ventsislav-georgiev/playsvideo",
     "the download must name ventsislav-georgiev/playsvideo explicitly (#167)")

# 2. Pins the rolling tag. An untagged `gh release download` takes the newest
#    release by creation time, and this repo also cuts plain version-tag
#    releases carrying no bundle asset at all — silently downloading nothing.
need(wf, "gh release download bundle-latest",
     "the download must pin the bundle-latest tag explicitly, or it can silently resolve to a non-bundle release (#167)")

# 3. Extracts into the exact path copy-app-shell.sh reads — pinned on BOTH
#    ends so the workflow and the script cannot drift apart.
need(wf, 'dest="dobby/Sources/BookPlayServer/Public/playsvideo/assets"',
     "the extraction target must be dobby/Sources/BookPlayServer/Public/playsvideo/assets (#167)")
need(sh, 'os.path.join(public_dir, "playsvideo/assets")',
     "copy-app-shell.sh must still read playsvideo/assets under Public — if this literal moves, the workflow's extraction target has to move with it (#167)")

fetch_at = wf.index("name: Fetch playsvideo bundle asset")
install_xcodegen_at = wf.index("name: Install xcodegen")
fetch_step = wf[fetch_at:install_xcodegen_at]

# 4. The job's own default working-directory is dobby-ios (see the #155
#    checks above); without an override here, this step's relative paths
#    land inside the wrong checkout.
need(fetch_step, "working-directory: .",
     "the fetch step must set working-directory: . to escape the job's dobby-ios default, or it writes into the wrong checkout (#167)")

# 5. Position: before Archive. copy-app-shell.sh runs as a preBuildScript
#    DURING Archive, so after Archive the download is useless — the file
#    compiles and reads fine either way, which is exactly why position, not
#    presence, is the thing that has to be pinned here.
checkout_dobby_at = wf.index("name: Check out dobby (PWA app shell source)")
archive_at = wf.index("name: Archive")
if not (checkout_dobby_at < fetch_at < archive_at):
    sys.stderr.write("FAIL: the bundle fetch must run after checking out dobby and before Archive, or copy-app-shell.sh runs before the asset exists (#167)\n")
    sys.exit(1)

# 6. Asserts rather than continues on a miss.
if "exit 1" not in fetch_step:
    sys.stderr.write("FAIL: the fetch step must fail the job (exit 1) when the bundle didn't extract cleanly, not just warn (#167)\n")
    sys.exit(1)
need(fetch_step, "::error::",
     "the fetch step must report what it found with ::error:: when the extracted bundle count is wrong, not fail silently (#167)")

print("PASS: TestFlight fetches the playsvideo bundle-latest release asset into the exact path copy-app-shell.sh reads, before Archive, from the correct working directory (#167)")
BUNDLEFETCHPY

# ---------------------------------------------------------------------------
# #183 — TestFlight follows PWA main. An hourly schedule, a decide job that looks up
# the (dobby-ios, PWA) pair's record by exact artifact name, a release job gated on it,
# and the record written from what the archive carries after a successful upload. Every
# pin reads comment-stripped text, and every one is about containment or order, because
# each of these fails silently in CI: a schedule outside on:, an if: on a step instead of
# the job, a record uploaded before the upload it vouches for.
python3 - <<'FOLLOWPWAPY'
import subprocess, sys

def strip_comments(text):
    kept = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        kept.append(line.split(" #", 1)[0])
    return "\n".join(kept) + "\n"

# The stripper is load-bearing for every pin below (the comment block under on: itself
# says "schedule"), so it is checked first.
probe = "on:\n  # schedule:\n  push: # schedule\n#   - cron: x\n"
if strip_comments(probe) != "on:\n  push:\n":
    sys.stderr.write("FAIL: the #183 comment stripper keeps comments: %r\n" % strip_comments(probe))
    sys.exit(1)

wf = strip_comments(open(".github/workflows/testflight.yml").read())
sh = strip_comments(open("scripts/copy-app-shell.sh").read())

def fail(msg):
    sys.stderr.write("FAIL: " + msg + " (#183)\n")
    sys.exit(1)

def at(haystack, needle, what, start=0):
    i = haystack.find(needle, start)
    if i < 0:
        fail(what + "\nexpected to find, verbatim:\n  " + needle)
    return i

def section(start_needle, end_needle, what):
    a = at(wf, start_needle, what)
    b = at(wf, end_needle, what, a + len(start_needle))
    return wf[a:b]

# 1. The trigger, inside on: (on: runs up to the first top-level key after it).
on_block = section("\non:\n", "\nconcurrency:\n", "the on: block must be followed by the workflow-level concurrency:")
at(on_block, "\n  schedule:\n    - cron: '", "the hourly schedule: trigger must sit inside on:, or a PWA-only change never builds")
at(on_block, "\n  workflow_dispatch:\n", "workflow_dispatch must stay a trigger (the manual override of every skip)")
at(on_block, "\n  push:\n", "push to main must stay a trigger")
# Workflow-level, before jobs:: decide has to run after the build ahead of it recorded.
at(wf, "\nconcurrency:\n  group: testflight\n  cancel-in-progress: false\n", "concurrency must stay at workflow level, one group, no cancelling")
if "concurrency:" in wf[wf.index("\njobs:\n"):]:
    fail("concurrency moved under jobs:; a tick during a build would then find no record for the pair being built and queue a duplicate")
print("PASS: testflight.yml runs on an hourly schedule inside on:, alongside push and workflow_dispatch, under one workflow-level concurrency group (#183)")

# 2. The decision's wiring: job output <- step id decide <- the script <- GITHUB_OUTPUT.
decide = section("\n  decide:\n", "\n  release:\n", "a decide job must come before the release job")
at(decide, "\n      build: ${{ steps.decide.outputs.build }}\n", "decide's build output must read the decide step's output")
step_at = at(decide, "\n        id: decide\n", "the decide job needs a step with id: decide")
step_end = decide.find("\n      - ", step_at)
step = decide[step_at:step_end if step_end >= 0 else len(decide)]
at(step, 'scripts/testflight-decide.sh "$GITHUB_EVENT_NAME" "$GITHUB_SHA" "$pwa_sha" "$built" "$failed" >> "$GITHUB_OUTPUT"',
   "the id: decide step must feed the schedule case to testflight-decide.sh and append its answer to GITHUB_OUTPUT")
at(step, 'scripts/testflight-decide.sh "$GITHUB_EVENT_NAME" >> "$GITHUB_OUTPUT"',
   "the id: decide step must answer push and dispatch through the script too")
guard_at = at(step, 'if [ "$GITHUB_EVENT_NAME" != schedule ]; then', "decide must branch on the event before any API call")
api_at = at(step, "gh api", "decide must look the pair up with gh api")
if not guard_at < api_at:
    fail("decide calls an API before its non-schedule exit; a transient API error would then skip a push build")
# The two ends of each record name: the lookup here, the producers in release.
at(step, 'gh api repos/ventsislav-georgiev/bookplay/commits/main --jq .sha)',
   "decide must reduce the PWA commit lookup to its sha; the whole commit JSON carries the private message and author")
at(step, 'pair="$GITHUB_SHA-$pwa_sha"', "the lookup key must be the dobby-ios and PWA pair")
at(step, 'actions/artifacts?name=$1', "records must be looked up by exact name, not by listing")
at(step, 'live "testflight-$pair"', "decide must look up the success record by the pair")
at(step, 'live "testflight-failed-$pair"', "decide must look up the failure marker by the pair")
print("PASS: the decide job's build output comes from the id: decide step, which calls testflight-decide.sh into GITHUB_OUTPUT and reads the APIs only on schedule, by exact pair name (#183)")

# 3. The gate, at job level: needs and if between release: and that job's steps:.
rel_at = at(wf, "\n  release:\n", "the release job is missing")
rel_steps_at = at(wf, "\n    steps:\n", "the release job has no steps:", rel_at)
head = wf[rel_at:rel_steps_at]
at(head, "\n    needs: decide\n", "release must need decide at job level")
at(head, "\n    if: needs.decide.outputs.build == 'true'\n", "release must be gated on decide's build output at job level, not on a step")
release = wf[rel_at:]
print("PASS: the release job needs decide and is gated on its build output at job level, before steps: (#183)")

# 4. What the build ships, and in what order. The record after the upload is the
#    only-on-success property, so it is pinned by index, not by presence.
checkout = section("name: Check out dobby (PWA app shell source)", "\n      - name: ", "the PWA checkout step is missing")
if "ref:" in checkout:
    fail("the PWA checkout has a ref:; a sha ref detaches it and prints a private commit subject into this public log")
if "fetch-depth" in checkout:
    fail("the PWA checkout sets fetch-depth; history is never needed, and a deeper fetch only widens what a later step could print")
# The subject can leak through any step, not only through the checkout, and a deny-list
# of history readers never ends (rev-list --format, branch -v, checkout <sha>, reset
# --hard all print a subject). So an allow-list: every git in this public workflow is a
# bare rev-parse HEAD of this checkout or of the PWA checkout, a sha and nothing else.
# A new git command is a deliberate edit to this list, never a silent pass.
import re
allowed = re.compile(r"git (?:-C \.\./dobby )?rev-parse HEAD(?:\)| 2>/dev/null \|\| true\))")
for m in re.finditer(r"\bgit\b", wf):
    if not allowed.match(wf, m.start()):
        line = wf[m.start():wf.find("\n", m.start())]
        fail("the workflow runs a git command outside the allow-list (bare rev-parse HEAD only), which can print a private PWA commit subject into this public log; widen the list on purpose if it is needed: " + line[:80])
names = [
    ("name: Verify the app shell was bundled", "verify"),
    ("name: Export .ipa", "export"),
    ("name: Upload to TestFlight", "upload"),
    ("name: Record the pair this build shipped", "record"),
    ("name: ${{ steps.record.outputs.name }}", "record upload-artifact"),
    ("name: Revoke this run's certificate", "revoke"),
    ("name: Mark this pair failed", "failure marker"),
    ("name: ${{ steps.failed.outputs.name }}", "failure marker upload-artifact"),
]
idx = [at(release, n, "the release job lost its " + label + " step") for n, label in names]
for (_, la), (_, lb), ia, ib in zip(names, names[1:], idx, idx[1:]):
    if not ia < ib:
        fail("the %s step must come before the %s step in the release job" % (la, lb))
verify = release[idx[0]:idx[1]]
at(verify, "Shell/pwa-commit.txt", "the shell guard must read the archive's pwa-commit.txt")
at(verify, "checked_out=$(git -C ../dobby rev-parse HEAD)", "the shell guard must compare against the commit the PWA checkout landed on")
at(verify, 'if [ "$bundled_sha" != "$checked_out" ]; then', "the shell guard must refuse an archive whose record is not the checked-out commit")
record = release[idx[3]:idx[4]]
at(record, 'echo "name=testflight-$(git rev-parse HEAD)-$(cat "$RUNNER_TEMP/pwa-record/pwa-commit.txt")" >> "$GITHUB_OUTPUT"',
   "the record must be named for the pair the archive carries, testflight-<dobby-ios>-<pwa>")
at(release[idx[4]:idx[5]], "retention-days: 90", "the success record keeps 90 days")
# Only-on-success is also a condition: an if: always() (or any if:) on the record or its
# upload would record a pair whose TestFlight upload failed, and every tick would skip
# it for 90 days.
if "if:" in release[idx[3]:idx[5]]:
    fail("the success record or its upload carries an if:; it must run only when every step before it succeeded")
failed = release[idx[6]:]
at(failed[:failed.index("run: |")], "if: failure()", "the failure marker runs only when the job failed")
at(failed, 'echo "name=testflight-failed-$(git rev-parse HEAD)-$pwa" >> "$GITHUB_OUTPUT"', "the failure marker must be named for the pair")
at(release[idx[6]:], "\n        if: failure() && steps.failed.outputs.name != ''\n        with:\n          name: ${{ steps.failed.outputs.name }}\n",
   "the failure marker upload runs only on failure, and only when it has a name")
at(release[idx[7]:], "retention-days: 1", "the failure marker lives one day, so a broken pair retries daily")
# Producer: the record is written into the shell AFTER the wipe, or the wipe deletes it.
wipe_at = at(sh, "shutil.rmtree(shell_dir", "copy-app-shell.sh no longer wipes the shell dir first")
write_at = at(sh, 'open(os.path.join(shell_dir, "pwa-commit.txt"), "w")', "copy-app-shell.sh must write Shell/pwa-commit.txt")
at(sh, '["git", "-C", public_dir, "rev-parse", "HEAD"]', "pwa-commit.txt must be the PWA checkout's HEAD")
if not wipe_at < write_at:
    fail("copy-app-shell.sh writes pwa-commit.txt before it wipes the shell dir, so no archive carries it")
print("PASS: the archive carries the PWA commit it was built from, the guard checks it against the checkout (no ref: on it), and the pair is recorded only after the TestFlight upload, or marked failed for a day (#183)")

# 5. Behaviour: the script itself, every case the workflow can feed it.
A, B = "a" * 40, "b" * 40
cases = [
    (["push"], 0, "build=true"),
    (["workflow_dispatch"], 0, "build=true"),
    (["push", A, B, "1", "1"], 0, "build=true"),
    (["schedule", A, B, "1", "0"], 0, "build=false"),
    (["schedule", A, B, "0", "0"], 0, "build=true"),
    (["schedule", A, B, "0", "1"], 0, "build=false"),
    (["schedule", A, B, "2", "1"], 0, "build=false"),
    (["schedule", A, "not-a-sha", "0", "0"], 1, None),
    (["schedule", A, '{"sha":"%s","commit":{"message":"private subject"}}' % B, "0", "0"], 1, None),
    (["schedule", "", B, "0", "0"], 1, None),
    (["schedule", A, B, "", "0"], 1, None),
]
for args, code, want in cases:
    r = subprocess.run(["bash", "scripts/testflight-decide.sh"] + args, capture_output=True, text=True)
    lines = r.stdout.splitlines()
    if r.returncode != code or (want and want not in lines):
        fail("testflight-decide.sh %s: exit %d, stdout %r; expected exit %d with %r" % (" ".join(args), r.returncode, r.stdout, code, want))
    if code and args[2:3] and args[2] not in ("", B) and args[2] in r.stdout + r.stderr:
        fail("testflight-decide.sh %s echoes the rejected value; on a broken lookup that is the private commit JSON" % " ".join(args))
    if want and args[0] == "schedule" and ("pwa_sha=" + B) not in lines:
        fail("testflight-decide.sh %s must output pwa_sha for the failure marker's fallback" % " ".join(args))
print("PASS: testflight-decide.sh builds on push and dispatch, and on schedule only for a pair with no record and no failure marker, refusing a non-sha head or non-numeric count (%d cases) (#183)" % len(cases))
FOLLOWPWAPY

# ---------------------------------------------------------------------------
# #158 — the Apple bridge's TWO name seams, neither of which anything checked.
#
# `window.Dobby` is a JavaScript object literal living inside a Swift string
# (Dobby/Web/BridgeInjection.swift). Each of its members posts an action string
# that WebBridge.dispatch switches on. So a PWA call has to survive two renames,
# not one:
#
#   PWA call  ──seam 1──▶  JS member name  ──seam 2──▶  posted action ──▶ Swift case
#
# Both fail the same silent way. Seam 1: every PWA call site is `typeof`-guarded,
# so a missing member does not throw — the feature is simply absent. Seam 2: an
# action with no `case` lands on `default:`, which NSLogs "unhandled bridge
# action" and returns; nothing the user or a test can see. Guarding only seam 1
# leaves seam 2, which is why this is one block with three parts and not a patch.
#
# What it found on arrival (2026-09-20, the reason for the entry): the shared
# receiver `bridge()` in 21-android-tv.js returns EITHER wrapper, and three of the
# names it reached were not members of window.Dobby — attachAssDrawings,
# cancelPendingNative, removeNativeOffline. The first two are Android-only and
# have moved to `androidBridge()`; the third was a naming split (Apple said
# deleteNativeOffline) and the Apple side now spells it removeNativeOffline.
#
# Part A (seam 2 + the pairing) runs ALWAYS — it is entirely inside this repo.
# Part B (seam 1) needs the PWA, so it runs only when the sibling dobby checkout
# is there and SKIPs otherwise, the same shape the #151 checks above use. That is
# a real hole in CI, not a rhetorical one: until #155 gives this repo's CI a dobby
# checkout, seam 1 is guarded on a developer machine and skipped on the runner.
# The cost of closing it is #155's checkout, nothing more — Part B already reads
# the PWA through $DOBBY_PUBLIC_DIR and needs no Gradle-style plumbing.
#
# Part A's floors are what keep Part B honest, too: Part B's "declared" set is
# parsed out of the same object literal Part A counts, so a parser that went blind
# would red Part A rather than quietly empty Part B.
# ---------------------------------------------------------------------------

# Declared on window.Dobby, deliberately never called from the PWA. Each entry
# needs a reason: this list is the only thing standing between Part B's coverage
# count and fiction, exactly as #157's bridgeMethodsWithNoCaller is on the Android
# side. It is not a place to silence a failure unread.
# Called by the PWA, deliberately not declared: same rule, other direction.
DOBBY_PUBLIC_DIR_158="${DOBBY_PUBLIC_DIR:-$PWD/../dobby/Sources/BookPlayServer/Public}" \
python3 - <<'BRIDGENAMESPY'
import glob
import os
import re
import sys
sys.path.insert(0, "Tests")
from swift_strip import strip_swift
from js_strip import strip_js

MEMBERS_WITH_NO_PWA_CALLER = {
    "platform": "identity string the wrapper advertises; nothing in the PWA branches on it "
                "(canPlayNative is what every call site tests instead).",
    "version": "same — advertised, never read. Kept so a future PWA can gate on a wrapper age.",
    "isCarAudio": "written by the wrapper, not called: WebBridge.pushCarRoute assigns "
                  "window.Dobby.isCarAudio and the PWA is notified through the separate "
                  "window.bookPlayNativeAudioRoute callback. Part C pins that assignment.",
    "_offline": "the native-pushed offline cache itself; listNativeOffline/getNativeOffline "
                "read it from inside the literal, so no PWA call site names it.",
    "_setOffline": "called by the WRAPPER, not the PWA — WebBridge.swift callJS pushes the "
                   "index into it. Part C pins those two call sites.",
    "_piEnabled": "#181: the injected answer piEnabled()/setPiEnabled() read and write from "
                  "inside the literal, like _offline; no PWA call site names it.",
    "piEnabled": "#181: the PWA gate piEnabledBridge() (12-service-worker-offline.js) calls it, "
                 "but through window.BookPlayAndroid only; drop this entry when that gate also "
                 "accepts window.Dobby (the #181 guard prints PENDING until then).",
    "setPiEnabled": "#181: same gate, same pending dobby change as piEnabled.",
}

PWA_CALLS_NOT_DECLARED = {
    "deleteNativeOffline": "#158 field-skew fallback. It is the pre-#158 Apple-only spelling of "
                           "removeNativeOffline, kept at ONE call site "
                           "(12-service-worker-offline.js, book removal) because the PWA rsyncs "
                           "to the Pi instantly while a TestFlight build does not, so an app "
                           "installed before #158 would silently lose book removal. Drop the "
                           "else-branch there and this entry together once every installed "
                           "build carries removeNativeOffline.",
}

def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()

def fail(msg):
    sys.stderr.write("FAIL: " + msg + "\n")
    sys.exit(1)

# Swift comments stripped by the shared, probed lexer (#194); literal content is kept.
inject = strip_swift(read("Dobby/Web/BridgeInjection.swift"), "BridgeInjection.swift")
webbridge = strip_swift(read("Dobby/Web/WebBridge.swift"), "WebBridge.swift")

# --- the literal's members -------------------------------------------------
# Anchored on the assignment rather than braces: if this line moves or is renamed
# the PWA is addressing a different object entirely and every name below is stale.
anchor = "window.Dobby = {"
if anchor not in inject:
    fail("BridgeInjection.swift no longer contains `%s`. The PWA addresses the wrapper as "
         "window.Dobby; if that changed, every call site changed with it and this guard's "
         "seed needs updating (#158)." % anchor)
start = inject.index(anchor) + len(anchor)
end = inject.index("\n          };", start)
# JS comments inside the Swift literal are the page's comments: a member commented out
# there is not declared (#194, the same strip PIGATEPY applies).
literal = strip_js(inject[start:end])

declared = []
for line in literal.splitlines():
    m = re.match(r"\s{12}([A-Za-z_][A-Za-z0-9_]*)\s*:", line)
    if m:
        declared.append(m.group(1))

# A member can reach the literal through a Swift interpolation instead of a plain
# line, and the line scan above cannot see it. No member does today — the lyrics
# one did until #174 — so this loop finds nothing, and that is the point: it is
# what keeps the guard honest the next time someone adds one, rather than letting
# the member go silently unchecked.
for m in re.finditer(r"\\\(([A-Za-z_][A-Za-z0-9_]*)\)", literal):
    prop = m.group(1)
    found = re.findall(r'"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*function', inject)
    if not found:
        fail("BridgeInjection.swift interpolates \\(%s) into the window.Dobby literal and no "
             "quoted `name: function` member could be parsed out of the file — that member is "
             "invisible to this guard (#158)." % prop)
    declared.extend(found)

declared = list(dict.fromkeys(declared))
# A parser that silently matched nothing would make every comparison below vacuous
# and read exactly like a clean run.
if len(declared) < 18:
    fail("only %d window.Dobby member(s) parsed out of BridgeInjection.swift — the member "
         "parser needs updating (indentation changed, a member moved behind a new "
         "interpolation?). Refusing to check %s against anything as if that were all of them "
         "(#158)." % (len(declared), declared))

# --- Part A1: every posting member posts its OWN name ----------------------
# This is the cheap invariant that welds seam 1 to seam 2: hold it, and "the PWA
# reaches member X" and "Swift handles action X" become the same statement.
posting = {}
for m in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*function\s*\([^)]*\)\s*\{(.*?)\}\s*,", inject, re.S):
    name, body = m.group(1), m.group(2)
    p = re.search(r"post\('([A-Za-z_][A-Za-z0-9_]*)'", body)
    if p:
        posting[name] = p.group(1)
if len(posting) < 10:
    fail("only %d posting member(s) parsed out of BridgeInjection.swift; the body parser is "
         "blind and Part A2 below would be checking almost nothing (#158)." % len(posting))
mismatched = sorted("%s posts '%s'" % (k, v) for k, v in posting.items() if k != v)
if mismatched:
    fail("window.Dobby members must post their own name, or a PWA call reaches a member whose "
         "action nothing in this repo relates back to it: " + "; ".join(mismatched) + " (#158).")

# --- Part A2: posted actions vs the Swift switch ---------------------------
posted = sorted(set(re.findall(r"post\('([A-Za-z_][A-Za-z0-9_]*)'", inject)))
if len(posted) < 12:
    fail("only %d action string(s) parsed out of BridgeInjection.swift (#158)." % len(posted))

dstart = webbridge.index("private func dispatch(action: String")
dend = webbridge.index("        default:", dstart)
handled = sorted(set(re.findall(r'^\s*case "([A-Za-z_][A-Za-z0-9_]*)":', webbridge[dstart:dend], re.M)))
if len(handled) < 12:
    fail("only %d `case` arm(s) parsed out of WebBridge.dispatch (#158)." % len(handled))

unhandled = [a for a in posted if a not in handled]
if unhandled:
    fail("the injected bridge posts %d action(s) WebBridge.dispatch has no `case` for: %s. "
         "Those land on `default:`, which NSLogs and returns — on device the feature silently "
         "does nothing (#158)." % (len(unhandled), ", ".join(unhandled)))

unposted = [a for a in handled if a not in posted]
if unposted:
    fail("WebBridge.dispatch handles %d action(s) nothing in BridgeInjection.swift posts: %s. "
         "Either the action string was renamed on the JS side alone — in which case the web is "
         "still posting the old one and it is now hitting `default:` — or this arm is dead. "
         "This check is also what makes the one above falsifiable: a post() parser that went "
         "blind empties `posted` and every arm shows up here (#158)."
         % (len(unposted), ", ".join(unposted)))

# --- Part C: the wrapper's own reaches into the literal --------------------
# callJS strings are the native -> web direction and they name members too. Nothing
# else checks them, and _setOffline is reached ONLY this way.
swift_sources = [p for p in sorted(glob.glob("Dobby/**/*.swift", recursive=True))]
if len(swift_sources) < 15:
    fail("only %d Swift source(s) found; the callJS scan is not looking at this app (#158)."
         % len(swift_sources))
reached = {}
for path in swift_sources:
    # Comments stripped: a doc comment naming a member is drift worth noticing but not
    # worth failing a build over, and it would otherwise inflate the count below (#194:
    # through the shared lexer, so a /* */ block is stripped too).
    src = strip_swift(read(path), path)
    for m in re.finditer(r"window\.Dobby\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)", src):
        reached.setdefault(m.group(1), set()).add(path)
if not reached:
    fail("no `window.Dobby.<member>` reference found in any Swift source — WebBridge pushes the "
         "offline index and the car-audio flag that way, so the scan is blind (#158).")
stray = sorted(n for n in reached if n not in declared)
if stray:
    fail("Swift reaches %d window.Dobby member(s) the injected literal does not declare: %s. "
         "callJS evaluates that string in the page, where a missing member is `undefined` and "
         "the `window.Dobby && …` guard in front of it swallows the whole statement (#158)."
         % (len(stray), ", ".join("%s (%s)" % (n, ", ".join(sorted(reached[n]))) for n in stray)))

print("PASS: every window.Dobby member posts its own name, all %d posted action(s) have a "
      "WebBridge case and vice versa, and the %d member(s) Swift reaches through callJS are "
      "declared (#158 seam 2)" % (len(posted), len(reached)))

# --- Part B: seam 1, the PWA's calls vs the literal's members --------------
pub = os.environ.get("DOBBY_PUBLIC_DIR_158", "")
if not os.path.isdir(pub):
    print("SKIP: no dobby checkout at %r — seam 1 (PWA calls vs window.Dobby members) needs the "
          "PWA's Public dir. Until #155 gives CI a dobby checkout this half is developer-machine "
          "only (#158)." % pub)
    sys.exit(0)

sources = sorted(glob.glob(os.path.join(pub, "js", "*.js"))) + [os.path.join(pub, "index.html")]
if len(sources) < 10:
    fail("only %d source file(s) under %s — that is not the PWA, refusing to call the bridge "
         "uncalled (#158)." % (len(sources), pub))

# The receiver rules are #157's, mirrored onto window.Dobby, with one thing added.
# #157 matches a receiver NAME across the whole file; here that over-approximation
# is not survivable — 21-android-tv.js binds the same local `b` to bridge() and to
# the new androidBridge(), and 12-service-worker-offline.js binds `b` to a DOM node
# hundreds of lines further down. So a receiver binding's window ends at whichever
# comes first: the next binding of that same name, or the next `}` in column 1 (the
# end of the enclosing top-level function in this codebase's layout). Measured:
# without it, attachAssDrawings and cancelPendingNative are still reported as Dobby
# calls after they moved to androidBridge(), plus four DOM members.
calls = {}
files_with_receivers = 0
for path in sources:
    text = strip_js(read(path))
    if "window.Dobby" not in text:
        continue
    files_with_receivers += 1
    fn_aliases = []
    for m in re.finditer(r"return\b[^;]*?window\.Dobby[^;]*?;", text, re.S):
        enclosing = None
        for f in re.finditer(r"function\s+([A-Za-z0-9_]+)\s*\(", text[:m.start()]):
            enclosing = f.group(1)
        if enclosing:
            fn_aliases.append(enclosing)
    fn_aliases = list(dict.fromkeys(fn_aliases))
    dobby_expr = re.compile(r"window\.Dobby" + "".join(
        "|" + re.escape(f) + r"\s*\(" for f in fn_aliases))
    closers = [m.start() for m in re.finditer(r"^\}", text, re.M)]
    binds = [(m.start(), m.group(1), bool(dobby_expr.search(m.group(2))))
             for m in re.finditer(r"\b(?:var|let|const)\s+([A-Za-z0-9_]+)\s*=\s*([^;]*?);", text, re.S)]
    windows = [(r"window\.Dobby", 0, len(text))]
    windows += [(re.escape(f) + r"\s*\(\s*\)", 0, len(text)) for f in fn_aliases]
    for i, (pos, name, is_dobby) in enumerate(binds):
        if not is_dobby:
            continue
        stop = len(text)
        for pos2, name2, _ in binds[i + 1:]:
            if name2 == name:
                stop = min(stop, pos2)
                break
        for c in closers:
            if c > pos:
                stop = min(stop, c)
                break
        windows.append((re.escape(name), pos, stop))
    for recv, lo, hi in windows:
        for m in re.finditer(r"(?<![A-Za-z0-9_$.])" + recv + r"\s*\.\s*([A-Za-z0-9_]+)", text[lo:hi]):
            line = text[:lo + m.start()].count("\n") + 1
            calls.setdefault(m.group(1), set()).add("%s:%d" % (os.path.basename(path), line))

if len(calls) < 12:
    fail("only %d name(s) reached on a window.Dobby receiver across the PWA — the call-site "
         "matcher has gone blind and the comparisons below would pass on nothing (#158)." % len(calls))

undeclared = sorted(n for n in calls if n not in declared and n not in PWA_CALLS_NOT_DECLARED)
if undeclared:
    fail("the PWA calls %d name(s) on a window.Dobby receiver that BridgeInjection.swift does "
         "not declare: %s. Either it was renamed on the Apple side alone, or it was never added, "
         "or it is Android-only and is reaching a SHARED receiver it should not be "
         "(21-android-tv.js has androidBridge() for that). Every call site is typeof-guarded, so "
         "on device this does not throw — the feature silently does not exist (#158)."
         % (len(undeclared), "; ".join("%s() at %s" % (n, " and ".join(sorted(calls[n])))
                                       for n in undeclared)))

uncovered = sorted(n for n in declared
                   if n not in calls and n not in MEMBERS_WITH_NO_PWA_CALLER)
if uncovered:
    fail("BridgeInjection.swift declares %d window.Dobby member(s) nothing under %s calls: %s. "
         "If one was renamed on the Apple side alone, the PWA is still calling the old name and "
         "the feature is dead on device — rename it back, or rename the call sites. If it is "
         "genuinely not wired up yet, add it to MEMBERS_WITH_NO_PWA_CALLER in Tests/run-checks.sh "
         "WITH A REASON: this check is not policing dead code, it is the falsifiability check on "
         "the one above — a matcher that stops matching a file reads exactly like a clean run, "
         "and shows up here instead (#158)." % (len(uncovered), pub, ", ".join(uncovered)))

for name, why in sorted(MEMBERS_WITH_NO_PWA_CALLER.items()):
    if name not in declared:
        sys.stderr.write("WARN: MEMBERS_WITH_NO_PWA_CALLER lists %s, which BridgeInjection.swift "
                         "no longer declares — drop the entry.\n" % name)
    elif name in calls:
        sys.stderr.write("WARN: MEMBERS_WITH_NO_PWA_CALLER lists %s, but the PWA now calls it "
                         "(%s) — drop the entry.\n" % (name, ", ".join(sorted(calls[name]))))
for name, why in sorted(PWA_CALLS_NOT_DECLARED.items()):
    if name not in calls:
        sys.stderr.write("WARN: PWA_CALLS_NOT_DECLARED lists %s, which no PWA call site names any "
                         "more — drop the entry.\n" % name)
    elif name in declared:
        sys.stderr.write("WARN: PWA_CALLS_NOT_DECLARED lists %s, but BridgeInjection.swift now "
                         "declares it — drop the entry.\n" % name)

covered = [n for n in declared if n in calls]
occurrences = sum(len(v) for v in calls.values())
print("PASS: %d of %d window.Dobby member(s) reached at %d call site(s) across %d PWA file(s); "
      "uncalled by design: %s (#158 seam 1)"
      % (len(covered), len(declared), occurrences, files_with_receivers,
         ", ".join(sorted(MEMBERS_WITH_NO_PWA_CALLER)) or "none"))
BRIDGENAMESPY

# ---------------------------------------------------------------------------
# #169: every WKURLSchemeTask call is made on the main thread.
#
# Measured on the device, not reasoned about: answering a task from the handler's
# own serial queue against a loadSimulatedRequest document made didReceive(_:)
# never return, and because the call is made with the handler's NSLock held, the
# next webView(_:start:) wedged the main thread. 3 of 27 subresources started, 0
# finished, nothing logged, black screen. On the main thread: 27 of 27.
#
# No runtime assertion here can catch the regression. It needs a real WKWebView,
# a real simulated document and a real device — the macOS WebView check in this
# same suite was green through the whole outage. So this is textual, and it pins
# the two halves that can drift apart:
#   (a) every `task.did…` call sits inside an `onMain { … }` block, and
#   (b) `onMain` still branches on Thread.isMainThread.
# (b) is not decoration. webView(_:start:) and webView(_:stop:) are already on
# main and reach the same helpers, so an "unconditional main.sync is simpler"
# edit deadlocks the not-found path instead of hanging it — a different black
# screen, same afternoon.
# ---------------------------------------------------------------------------
python3 - <<'SCHEMEMAINPY'
import re
import sys
sys.path.insert(0, "Tests")
from swift_strip import strip_swift_lines

FILES = ["Dobby/Offline/OfflineSchemeHandler.swift", "Dobby/Web/ApiSchemeHandler.swift"]
# Only the calls made ON a captured `task` value need an enclosing onMain. The
# `$0.didReceive(…)` form is the closure handed TO send(_:_:_:), which runs it
# inside onMain — pinning that shape here would forbid the fix.
CALL = re.compile(r"\btask\.(didReceive|didFinish|didFailWithError)\b")

def onmain_ranges(lines):
    """[start, end] line indices of every `onMain {` block body, by brace depth."""
    out = []
    for i, line in enumerate(lines):
        if "onMain {" not in line:
            continue
        depth = 0
        for j in range(i, len(lines)):
            depth += lines[j].count("{") - lines[j].count("}")
            if depth <= 0:
                out.append((i, j))
                break
        else:
            out.append((i, len(lines) - 1))
    return out

problems = []
pinned = 0
for path in FILES:
    # One entry per source line, comments (// and /* */) blanked: the line numbers
    # below are the file's own (#190 shared stripper).
    lines = strip_swift_lines(open(path).read(), path)
    body = "\n".join(lines)

    if not re.search(r"private func onMain<T>\(_ body: \(\) -> T\) -> T \{", body):
        problems.append("%s: no `private func onMain<T>(_ body: () -> T) -> T {` helper." % path)
        continue
    if "Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)" not in body:
        problems.append(
            "%s: onMain no longer reads exactly "
            "`Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)`. "
            "Dropping the isMainThread arm deadlocks webView(_:start:)'s not-found path, "
            "which already runs on main." % path)

    ranges = onmain_ranges(lines)
    for i, line in enumerate(lines):
        if not CALL.search(line):
            continue
        if any(a <= i <= b for a, b in ranges):
            pinned += 1
        else:
            problems.append(
                "%s:%d: `%s` is outside every onMain { … } block. A WKURLSchemeTask "
                "answered off the main thread hangs against a loadSimulatedRequest "
                "document and takes the main thread down with it (#169)."
                % (path, i + 1, line.strip()))

if not pinned:
    problems.append(
        "No `task.did…` call was found inside an onMain block in either handler. "
        "This check matched nothing, which reads exactly like a clean run — the call "
        "sites were renamed or moved, so re-point CALL/FILES in Tests/run-checks.sh.")

if problems:
    for p in problems:
        sys.stderr.write("FAIL: %s\n" % p)
    sys.exit(1)

print("PASS: %d WKURLSchemeTask call(s) across %d handler(s) are made inside onMain, "
      "which still branches on Thread.isMainThread (#169)" % (pinned, len(FILES)))
SCHEMEMAINPY

# ---------------------------------------------------------------------------
# #174: Spotify stays deleted.
#
# The owner's call was "remove all functionality related to spotify as a whole".
# The PWA (dobby, main @ c8a504f) deleted the `Dobby.openSpotifyLyrics` call and
# every `/api/spotify/*` route; Android (dobby-android @ c6525be13) dropped its
# `spotifyClientId` mirror key. This side deleted `Dobby/Spotify/` whole, the
# bridge member and its dispatch case, the `"lyrics"` Live Activity kind, and the
# ninth settings null key.
#
# The parts that would come back quietly are pinned by NAME, not by a blanket
# "no such string anywhere" — a grep is only a guard if it names what it forbids:
#   (a) no source file declares a Spotify symbol or mentions the service,
#   (b) `openSpotifyLyrics` appears in neither end of the bridge, and
#   (c) the Live Activity contract carries no `"lyrics"` kind, which is the one
#       piece with no "spotify" in its spelling — CARPLAY.md's lane 7 is gone,
#       so nothing else records that the kind was Spotify-only.
# The CarPlay Dashboard lane itself is NOT Spotify and is deliberately not
# forbidden here: `kind` is still "book" | "video", both live.
#
# The floors matter more than the matches: an empty scan reads exactly like a
# clean tree, so the check fails if it did not actually inspect the files.
# ---------------------------------------------------------------------------
python3 - <<'NOSPOTIFYPY'
import glob
import os
import re
import sys

ROOTS = ["Dobby", "DobbyWidgets", "Shared", "Tests"]
EXTS = (".swift", ".plist", ".js", ".entitlements")
SKIP = os.path.join("Dobby", "Shell") + os.sep   # build-time PWA copy, not source

files = []
for root in ROOTS:
    for path in sorted(glob.glob(root + "/**/*", recursive=True)):
        if path.startswith(SKIP) or not path.endswith(EXTS) or not os.path.isfile(path):
            continue
        files.append(path)
for extra in ["project.yml"]:
    if os.path.isfile(extra):
        files.append(extra)

# This file names Spotify on purpose (the comment above), so it cannot scan itself.
SPOTIFY = re.compile(r"spotify", re.I)
BRIDGE = re.compile(r"\bopenSpotifyLyrics\b")
LYRICS_KIND = re.compile(r'"lyrics"')

problems = []
for path in files:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError as exc:
        problems.append("%s: unreadable (%s)" % (path, exc))
        continue
    for i, line in enumerate(text.splitlines(), 1):
        if SPOTIFY.search(line):
            problems.append(
                "%s:%d: Spotify is back — #174 removed it whole, and the server "
                "(dobby) and Android (dobby-android) halves are merged and closed, "
                "so this end has nothing to talk to: %s" % (path, i, line.strip()))
        if BRIDGE.search(line):
            problems.append(
                "%s:%d: the `openSpotifyLyrics` bridge method is back. Both ends went "
                "in #174 — the `window.Dobby` member in BridgeInjection.swift and the "
                "`WebBridge.dispatch` case — and no PWA build calls it." % (path, i))
        if LYRICS_KIND.search(line):
            problems.append(
                "%s:%d: a `\"lyrics\"` Live Activity kind is back. `kind` is "
                "\"book\" | \"video\"; the lyrics lane was the Spotify one (CARPLAY.md "
                "lane 7, deleted in #174). The CarPlay lane itself is generic and "
                "stays — this forbids only the Spotify kind." % (path, i))

# Falsifiability: the scan must have reached the files that used to carry this.
MUST_SCAN = [
    "Dobby/Web/BridgeInjection.swift",   # held the `window.Dobby` lyrics member
    "Dobby/Web/WebBridge.swift",         # held the dispatch case
    "Dobby/Web/ApiSchemeHandler.swift",  # held the ninth settings null key
    "Shared/DobbyPlaybackAttributes.swift",  # held `line`/`nextLine` and the kind doc
    "DobbyWidgets/DobbyWidgetBundle.swift",  # held LyricsBody and three kind branches
]
for path in MUST_SCAN:
    if path not in files:
        problems.append(
            "%s was not scanned — re-point ROOTS/EXTS in Tests/run-checks.sh. A scan "
            "that misses the file reads exactly like a file with nothing in it." % path)
if len(files) < 20:
    problems.append(
        "only %d source file(s) scanned; this repo has far more, so the glob is "
        "broken and a clean result here means nothing." % len(files))
if glob.glob("Dobby/Spotify/*"):
    problems.append("Dobby/Spotify/ exists again; #174 deleted the directory whole.")

if problems:
    for p in problems:
        sys.stderr.write("FAIL: %s\n" % p)
    sys.exit(1)

print("PASS: %d source file(s) carry no Spotify symbol, no openSpotifyLyrics bridge "
      "method and no \"lyrics\" Live Activity kind (#174)" % len(files))
NOSPOTIFYPY

# ---------------------------------------------------------------------------
# #181 — "Use a Pi server" on iOS/iPadOS. The rule itself is ServerAddressesCheck's;
# these pin what no rule test can see: that the injected bridge exposes BOTH functions
# the PWA gate requires (a bridge with one keeps the settings row hidden while every rule
# test passes), that start-up consults the setting BEFORE the probe, and that each native
# Pi leg and the page-origin block are reached on the path production takes.
# ---------------------------------------------------------------------------
DOBBY_PUBLIC_DIR_181="${DOBBY_PUBLIC_DIR:-$PWD/../dobby/Sources/BookPlayServer/Public}" \
python3 - <<'PIGATEPY'
import os
import re
import sys
sys.path.insert(0, "Tests")
from swift_strip import strip_swift
from js_strip import strip_js

def fail(msg):
    sys.stderr.write("FAIL: " + msg + " (#181)\n")
    sys.exit(1)

def locate(scope, needle, what, start=0):
    # A missing anchor is a named FAIL, never a ValueError traceback (#190).
    try:
        return scope.index(needle, start)
    except ValueError:
        fail("%s: anchor %r is missing" % (what, needle))

# The stripper is load-bearing for every count below; its probe runs on import (#190).
def read(path):
    with open(path, encoding="utf-8") as f:
        return strip_swift(f.read(), path)

def body(src, signature, label):
    at = src.find(signature)
    if at < 0 or src.count(signature) != 1:
        fail("%s: expected exactly one `%s`, found %d" % (label, signature, src.count(signature)))
    start = locate(src, "{", label, at)
    depth = 0
    for i in range(start, len(src)):
        depth += {"{": 1, "}": -1}.get(src[i], 0)
        if depth == 0:
            return src[start:i + 1]
    fail("%s: unbalanced braces after `%s`" % (label, signature))

def ordered(text, needles, label):
    pos = -1
    for i, n in enumerate(needles):
        if text.count(n) < 1:
            fail("%s: `%s` is missing" % (label, n))
        nxt = text.find(n, pos + 1)
        if nxt < 0:
            fail("%s: `%s` is not after `%s`" % (label, n, needles[i - 1]))
        pos = nxt
    return pos

# --- 1. the bridge: both functions, under window.Dobby, answering synchronously ----------
inject = read("Dobby/Web/BridgeInjection.swift")
anchor = "window.Dobby = {"
if inject.count(anchor) != 1:
    fail("BridgeInjection.swift must build exactly one `%s` literal" % anchor)
literal = inject[locate(inject, anchor, "BridgeInjection"):locate(inject, "\n          };", "the window.Dobby literal end", locate(inject, anchor, "BridgeInjection"))]
# The Swift lexer keeps literal content, so a member the page's JS comments out still reads as
# present; strip the page's own comments before counting members (#194).
literal = strip_js(literal)
members = {
    "piEnabled": r"^\s{12}piEnabled:\s*function\s*\(\)\s*\{\s*return this\._piEnabled === true;\s*\},$",
    "setPiEnabled": r"^\s{12}setPiEnabled:\s*function\s*\(on\)\s*\{\s*this\._piEnabled = on === true;\s*"
                    r"post\('setPiEnabled', this\._piEnabled\);\s*\},$",
    "_piEnabled": r'^\s{12}_piEnabled:\s*\\\(piEnabled \? "true" : "false"\),$',
}
for name, pattern in members.items():
    n = len(re.findall(pattern, literal, re.M))
    if n != 1:
        fail("window.Dobby must carry exactly one `%s` in its #181 shape, found %d. The PWA gate "
             "reads BOTH piEnabled and setPiEnabled as functions, piEnabled() synchronously, and "
             "setPiEnabled must update the value before it posts (the page re-probes right after)"
             % (name, n))
if 'static func script(piEnabled: Bool) -> String' not in inject or \
   'WKUserScript(source: script(piEnabled: ServerAddresses.piEnabled()),' not in inject:
    fail("BridgeInjection.userScript() must inject the live ServerAddresses.piEnabled() answer")

# --- 2. the PWA gate asks for exactly these names (sibling checkout only) ---------------
pub = os.environ.get("DOBBY_PUBLIC_DIR_181", "")
gate_file = os.path.join(pub, "js", "12-service-worker-offline.js")
pending = None
if os.path.isfile(gate_file):
    with open(gate_file, encoding="utf-8") as f:
        js = f.read()
    m = re.search(r"function piEnabledBridge\(\)\s*\{(.*?)\n\}", js, re.S)
    if not m:
        fail("piEnabledBridge() not found in the PWA; the row's gate moved and this guard with it")
    gate = m.group(1)
    required = set(re.findall(r"typeof bridge\.([A-Za-z_]\w*) === 'function'", gate))
    if required != {"piEnabled", "setPiEnabled"}:
        fail("the PWA gate now requires %s; window.Dobby declares piEnabled and setPiEnabled"
             % sorted(required))
    if "window.Dobby" not in gate:
        pending = ("PENDING: the PWA's piEnabledBridge() (js/12-service-worker-offline.js) reads "
                   "window.BookPlayAndroid only, so the iOS row stays hidden until it also accepts "
                   "window.Dobby — a one-line dobby change, not this repo's (#181)")
else:
    print("SKIP: no dobby checkout at %r — the PWA gate's name set is unchecked (#181)" % pub)

# --- 3. WebBridge persists and re-injects on the page's call ------------------------------
wb = read("Dobby/Web/WebBridge.swift")
arm = wb[locate(wb, 'case "setPiEnabled":', "WebBridge.dispatch"):locate(wb, "case \"downloadNativeOffline\":", "WebBridge.dispatch")] \
    if wb.count('case "setPiEnabled":') == 1 else fail("WebBridge.dispatch needs one setPiEnabled case")
ordered(arm, ["guard let on = payload as? Bool", "ServerAddresses.setPiEnabled(on)",
              "ucc.removeAllUserScripts()", "ucc.addUserScript(BridgeInjection.userScript())",
              "ucc.removeAllContentRuleLists()", "PiRequestBlock.install(in: ucc, origin: origin)"],
        "WebBridge setPiEnabled arm")

# --- 4. start-up: the setting is consulted BEFORE the probe, and skips it -----------------
cv = read("Dobby/ContentView.swift")
resolve = body(cv, "private func resolve() async", "ContentView.resolve")
gate_at = resolve.find("if !ServerAddresses.piEnabled() {")
probe_at = resolve.find("await ServerAddresses.resolve()")
if gate_at < 0 or probe_at < 0 or gate_at > probe_at:
    fail("ContentView.resolve() must consult ServerAddresses.piEnabled() before "
         "`await ServerAddresses.resolve()` fires the probe")
skip = body(resolve[gate_at:], "if !ServerAddresses.piEnabled() {", "the Pi-off branch")
for needle in ["if BundledShell.root != nil { continueOffline() }", "return"]:
    if needle not in skip:
        fail("the Pi-off start-up branch must `%s`" % needle)
calls = sum(read(os.path.join(d, f)).count("ServerAddresses.resolve()")
            for d, _, fs in os.walk("Dobby") for f in fs if f.endswith(".swift"))
if calls != 1:
    fail("expected ServerAddresses.resolve() called from exactly one place (ContentView), found %d" % calls)

# --- 5. every native Pi leg checks the setting before it sends, in Release too ------------
api = read("Dobby/Web/ApiSchemeHandler.swift")
for fn, sender in [("private static func pushSettings(", "Transport.sendSync(request)"),
                   ("private static func fetchSettings(", "Transport.sendSync(request)")]:
    b = body(api, fn, fn)
    gate_at = b.find("if !ServerAddresses.piEnabled() {")
    endif_at = b.find("#endif")
    if gate_at < 0 or gate_at > b.find(sender) or (endif_at >= 0 and gate_at < endif_at):
        fail("%s must check ServerAddresses.piEnabled() outside #if DEBUG and before it sends" % fn)
intents = read("Dobby/Intents/DobbyIntents.swift")
books = body(intents, "private func allBooks()", "allBooks")
if not (0 <= books.find("guard ServerAddresses.piEnabled() else { return [] }") < books.find("URLSession.shared")):
    fail("the Siri library fetch must check the setting before it reaches the Pi")

# --- 6. the page-origin block is in place before the first load when off ------------------
wc = read("Dobby/Web/WebContainer.swift")
make = body(wc, "fileprivate func makeWebView(", "makeWebView")
if make.count("ucc.addUserScript(BridgeInjection.userScript())") != 1:
    fail("makeWebView must install BridgeInjection.userScript()")
ordered(make, ["guard !ServerAddresses.piEnabled() else {", "load(loadURL, in: webView)",
               "await PiRequestBlock.install(in: ucc, origin: url)", "load(loadURL, in: webView)"],
        "makeWebView Pi-off load order")
if make.count("load(loadURL, in: webView)") != 2:
    fail("makeWebView must load in exactly two places (Pi on; Pi off after the block)")

print("PASS: window.Dobby exposes piEnabled() and setPiEnabled(); start-up consults the setting "
      "before the probe; push, fetch and Siri legs and the page-origin block honour it (#181)")
if pending:
    sys.stderr.write(pending + "\n")
PIGATEPY
