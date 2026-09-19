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
if not (view_src.index(".onDisappear {")
        < view_src.index(".onChange(of: sliderTouch)")
        < view_src.index("Slider(value:")):
    sys.stderr.write("FAIL: the sliderTouch onChange moved off the root view onto the control bar, where it dies with the Slider it backs up (#131)\n")
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
stanza_text = "".join(stanza)
code_text = "".join(code_lines)

if "revision: 6dda7ccca2e1c678d413db279adf03339a1194cc" not in stanza_text:
    sys.stderr.write("FAIL: project.yml pins KSPlayer to revision 6dda7cc, never a branch (#130)\n")
    sys.exit(1)
if "branch:" in code_text:
    sys.stderr.write("FAIL: project.yml pins KSPlayer to revision 6dda7cc, never a branch (#130)\n")
    sys.exit(1)

print("PASS: project.yml pins KSPlayer to revision 6dda7cc, never a branch (#130)")
KSPLAYERPINPY
