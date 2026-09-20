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
    Dobby/AppConfig.swift Dobby/Web/ApiSchemeHandler.swift Tests/ApiSchemeWebViewCheck.swift
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
python3 - <<'PY'
import sys

path = "Dobby/Web/WebContainer.swift"
with open(path) as f:
    lines = f.readlines()

calls = [i for i, l in enumerate(lines)
         if "registerAsSecureScheme(in:" in l and "//" not in l.split("registerAsSecureScheme")[0]]
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
PY

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

need("            SettingsMirrorStore.save(merged)",
     "the settings POST no longer stores the merged document")
need("            SettingsMirrorStore.markAheadOfServer()",
     "the settings POST no longer marks the mirror as ahead of the Pi, so the next background refresh can pull the pre-write body back over it")

# Order is the meaning: the write must be stored and marked before the page is
# told it succeeded, or a 200 can outlive a failed save.
save_idx = src.index("            SettingsMirrorStore.save(merged)")
mark_idx = src.index("            SettingsMirrorStore.markAheadOfServer()")
ack_idx = src.index("            respond(task, id, status: 200, contentType: \"application/json\",")
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

python3 - <<'TIMELABELWIDTHPY'
import sys

path = "Dobby/Playback/PlayerView.swift"
with open(path) as f:
    lines = f.readlines()

code_lines = [l for l in lines if not l.strip().startswith("//")]
src = "".join(code_lines)

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
      Dobby/AppConfig.swift Dobby/Web/ApiSchemeHandler.swift \
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
need(content, "        resolving = true\n        offlineShell = false\n        serverURL = await ServerAddresses.resolve()",
     "resolve() must clear offlineShell before probing, so a Pi that came back is used")

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

inject = read("Dobby/Web/BridgeInjection.swift")
webbridge = read("Dobby/Web/WebBridge.swift")

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
literal = inject[start:end]

declared = []
for line in literal.splitlines():
    m = re.match(r"\s{12}([A-Za-z_][A-Za-z0-9_]*)\s*:", line)
    if m:
        declared.append(m.group(1))

# The lyrics member reaches the literal through a Swift interpolation, so the line
# scan above cannot see it. Resolve every interpolation by name instead of skipping
# them: an unresolved one means a member this guard is not looking at.
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
    # worth failing a build over, and it would otherwise inflate the count below.
    src = "\n".join(re.sub(r"//.*", "", l) for l in read(path).splitlines())
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

def strip_js(js):
    js = re.sub(r"/\*.*?\*/", "", js, flags=re.S)
    return "\n".join(re.sub(r"//.*", "", l) for l in js.splitlines())

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
