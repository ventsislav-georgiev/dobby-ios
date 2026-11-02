import SwiftUI
import KSPlayer

// E2 (#467) owns this file: the control bar, its progress and the seek pill.
// #466 moved the pre-#466 bar here (skin tint, plus buttons for the new Style sheet and the
// subtitle delay pill, which took the rows the old subtitles menu carried). The Slider's #115 /
// #129 / #131 rules are pinned by Tests/run-checks.sh against this file; its @GestureState and
// the root-level onChange that backs up the release stay in PlayerView.swift on purpose.

/// E2's bar state (keyboard tile focus, whether the bar was opened by keyboard, ...).
struct ControlBarState {}

extension PlayerControls {
    /// Keys while the bar is up, after every modal layer declined. Stub: none, so arrows keep
    /// seeking and Return toggles the bar. E2: tile focus (left/right), Return presses a tile.
    func controlBarHandleKey(_ key: OSDKey) -> Bool { false }
}

extension PlayerView {
    /// Always in the tree (PlayerView places it); draws the bar while `controls.visible`.
    /// E2 also draws the seek pill here while the bar is hidden.
    var controlBarLayer: some View {
        ZStack {
            if controls.visible {
                VStack { Spacer(); controlBar }.transition(.opacity)
            }
        }
    }

    var controlBar: some View {
        let total = max(1, Double(time.totalTime))
        let current = scrub.displayed(live: Double(time.currentTime))
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(timeLabel(current, matching: total)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { current }, set: { scrub.update(to: $0) }), in: 0...total) { editing in
                    // The knob binds to this value the instant the drag starts — seed it
                    // from the live position or it lands wherever the last drag ended (#115).
                    // #131 review: a healthy release and a release the recovery already
                    // committed both reach this branch, and SwiftUI documents no ordering
                    // between the gesture-state reset and onEditingChanged(false). Capture
                    // whether THIS callback is the one that seeked, so the two never share
                    // a log signature.
                    let seekedHere = !editing && scrub.isScrubbing
                    if editing { controls.scrubbing = true }   // #129: hold the OSD for the whole drag
                    if editing { scrub.begin(at: current) }
                    else if scrub.isScrubbing { playback.seek(to: scrub.end()) }   // #131: skip if the recovery path already committed this drag
                    if editing {
                        sliderDidBegin = true
                        Self.log.info("slider scrub begin at=\(current, privacy: .public)s total=\(total, privacy: .public)s")
                    } else {
                        Self.log.info("slider release delivered target=\(scrub.value, privacy: .public)s seeked=\(seekedHere, privacy: .public)")
                    }
                    if !editing { controls.scrubbing = false }
                    controls.forceShow()
                    if !editing { controls.scheduleHide() }   // #129: resume the idle timer after release
                }
                .tint(controls.tint.progress ?? controls.tint.accent)
                // #131: the Slider's own release callback is the only thing that used to
                // end a drag, and on device SwiftUI simply did not deliver it once. This
                // rides along (never steals — `simultaneousGesture`, and the Slider keeps
                // tracking normally) purely so `sliderTouch` exists to be reset.
                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($sliderTouch) { _, down, _ in down = true })
                Text(timeLabel(total, matching: total)).font(.caption.monospacedDigit())
            }

            // Portrait iPhone can't fit every button: fall back to a tighter row
            // without the ±10s buttons (the tap zones already cover seeking).
            ViewThatFits(in: .horizontal) {
                buttonRow(spacing: 18, compact: false)
                buttonRow(spacing: 12, compact: true)
                buttonRow(spacing: 6, compact: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Slider release recovery (#131)

    /// Every finger that goes down on the Slider comes back through here, whether the
    /// gesture ended or was cancelled — see `sliderTouch`. On device SwiftUI dropped one
    /// drag's `onEditingChanged(false)` entirely (`.claude-work/115-evidence/diag4-owner-drag.log`,
    /// drag 3 at 19:08:36.942): the knob moved, the finger lifted, no seek ran, and
    /// `controls.scrubbing` stayed set, so #129's guards kept the OSD on screen for the
    /// rest of the session.
    ///
    /// Exactly-once is `ScrubState.isScrubbing`, not a second flag: `end()` clears it, so
    /// whichever of the two release paths runs first commits and the other sees `false`
    /// and does nothing. Both are MainActor-isolated, so the read and the clear cannot
    /// interleave. A touch that never became a drag (a tap on the track, which iOS's
    /// Slider ignores) leaves `isScrubbing` false and therefore cannot seek to the
    /// *previous* drag's stale value.
    ///
    /// A cancelled drag still seeks, on purpose: the knob was visibly moved and the user's
    /// last seen intent is where it sits. Snapping back would be the surprising behaviour.
    func sliderTouchEnded() {
        if scrub.isScrubbing {
            let target = scrub.end()
            Self.log.info("slider release recovered target=\(target, privacy: .public)s scrubWasLive=true (#131)")
            playback.seek(to: target)
        } else if sliderDidBegin {
            Self.log.info("slider touch ended, release already delivered")
        } else {
            Self.log.info("slider touch ended without starting a drag")
        }
        sliderDidBegin = false
        controls.scrubbing = false   // #131: the one clear that cannot be lost
        controls.scheduleHide()
    }

    /// Sheets that make sense for the current stream: quality is only offered
    /// when the payload carried per-height alternates (ytdlpAdaptive lane).
    private var sheetButtons: [PlayerControls.Sheet] {
        PlayerControls.Sheet.allCases.filter { $0 != .quality || !playback.qualityOptions.isEmpty }
    }

    private func buttonRow(spacing: CGFloat, compact: Bool) -> some View {
        HStack(spacing: spacing) {
            iconButton(isPlaying ? "pause.fill" : "play.fill", size: 22) { controls.togglePlay(); isPlaying = controls.isPlaying }
            if !compact {
                iconButton("gobackward.10", size: 19) { controls.seekBy(-10) }
                iconButton("goforward.10", size: 19) { controls.seekBy(10) }
            }
            Spacer()
            ForEach(sheetButtons) { s in
                iconButton(icon(for: s), size: 18, active: controls.sheet == s) { controls.toggleSheet(s) }
            }
            iconButton("timer", size: 18, active: controls.subsDelayOpen) { controls.openSubsDelay() }
            iconButton("info.circle", size: 18, active: controls.showInfo) { controls.toggleInfo() }
            #if os(macOS)
            iconButton("arrow.up.left.and.arrow.down.right", size: 18) { controls.toggleFullscreen() }
            #endif
        }
    }

    private func icon(for s: PlayerControls.Sheet) -> String {
        switch s {
        case .subtitles: return "captions.bubble"
        case .audio: return "waveform"
        case .quality: return "slider.horizontal.3"
        case .speed: return "speedometer"
        case .aspect: return "aspectratio"
        case .style: return "textformat.size"
        }
    }

    private func iconButton(_ name: String, size: CGFloat, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? controls.tint.accent : .white)
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
    }

    // #128: the elapsed label used to format itself alone, so scrubbing across the
    // 1:00:00 mark grew it from d:dd to d:dd:dd mid-drag, reflowing the HStack and
    // sliding the Slider under the tracking finger. `matching` pins the field width
    // to the total's own shape (which never changes during a drag) so the elapsed
    // label never grows independently.
    func timeLabel(_ seconds: Double, matching total: Double = 0) -> String {
        let s = Int(seconds.isFinite ? seconds : 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        let showHours = h > 0 || total >= 3600
        if showHours { return String(format: "%d:%02d:%02d", h, m, sec) }
        // Same defect one field down: under an hour the minutes are unpadded, so the
        // elapsed label still grows from 9:59 to 10:00 mid-drag on anything over ten
        // minutes. Pin the minutes width to the total's the way the hours field is
        // pinned above. The total's own rendering never changes, only the elapsed
        // label gains a leading zero, which is what makes the two labels equal width.
        let totalMinutes = Int(total.isFinite ? total : 0) / 60
        return String(format: totalMinutes >= 10 ? "%02d:%02d" : "%d:%02d", m, sec)
    }
}
