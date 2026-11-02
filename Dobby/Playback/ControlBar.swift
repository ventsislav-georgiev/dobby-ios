import SwiftUI
import KSPlayer

// E2 (#467) owns this file with PlayerControls+Transport.swift and ScrubState.swift: the
// control bar, its progress band and the seek pill, ported from Android buildControlBar,
// updateControlBarFocusVisual, onControlBarTouch and buildSeekProgressOverlay. Sizes are
// Android dp as points and raw px halved (OSD-CONTRACT.md). The band's #115 / #128 / #129 /
// #131 rules are pinned by Tests/run-checks.sh against this file; its @GestureState and the
// root-level onChange that backs up the release stay in PlayerView.swift on purpose.

/// E2's bar state.
struct ControlBarState {
    /// The tile keyboard focus sits on (Android controlFocusIndex); kept while the bar hides.
    var focus: BarTile = .play
    /// Return opened this bar, so the arrows belong to it. A bar the pointer or a click
    /// summoned leaves them seeking (#463 section 5).
    var keyboard = false
    /// A tile is lit in the accent: the first arrow on a keyboard bar, or the pointer on a tile.
    var lit = false
}

extension PlayerControls {
    /// Android isControlEnabled: Bookmark only with allowBookmarks, Quality only with more than
    /// one option (the YouTube-only quality list, owner ruling D5).
    var barTiles: [BarTile] {
        BarTile.allCases.filter {
            switch $0 {
            case .bookmark: return playback?.request?.allowBookmarks == true
            case .quality: return (playback?.qualityOptions.count ?? 0) > 1
            default: return true
            }
        }
    }

    /// The router's one E2 hook (PlayerControls.barePictureKey, Return): if that Return opened
    /// the bar, the bar takes the arrows.
    func controlBarOpenedByKey() { if visible { bar.keyboard = true } }

    /// Keys while the bar is up and every modal layer declined (Android dispatchKey with
    /// controlBarVisible). Only a keyboard or lit bar takes keys: left/right light, then move
    /// the tile focus; Return presses the lit tile (unlit, it falls through and hides the bar,
    /// owner ruling D2); up/down/Esc drop the bar.
    func controlBarHandleKey(_ key: OSDKey) -> Bool {
        guard !anyLayerOpen, bar.keyboard || bar.lit else { return false }
        switch key {
        case .left, .right:
            let tiles = barTiles
            if !bar.lit || !tiles.contains(bar.focus) {
                if !tiles.contains(bar.focus) { bar.focus = .play }
                bar.lit = true
            } else {
                let i = tiles.firstIndex(of: bar.focus) ?? 0
                bar.focus = tiles[(i + (key == .left ? -1 : 1) + tiles.count) % tiles.count]
            }
            scheduleHide()
        case .ret:
            guard bar.lit else { return false }
            pressTile(bar.focus)
        case .up, .down, .escape:
            hide()
        default:
            return false
        }
        return true
    }

    /// Android activateFocusedControl. Re-arms the auto-hide first, as Android does.
    func pressTile(_ tile: BarTile) {
        bar.focus = tile
        scheduleHide()
        switch tile {
        case .play: togglePlay()
        case .subtitles: openSheet(.subtitles)
        case .subsDelay: openSubsDelay()
        case .audio: openSheet(.audio)
        case .bookmark: bookmark()
        case .aspect: openSheet(.aspect)
        case .quality: openSheet(.quality)
        case .style: openSheet(.style)
        case .more: openMoreMenu()
        }
    }
}

extension PlayerView {
    /// Always in the tree (PlayerView places it): the bar while `controls.visible`, else the
    /// seek pill for 2.2 s after a seek. Also resets the bar's keyboard state when it hides and
    /// raises Android's "Loading m:ss" toast on a rebuffer after the first frame.
    var controlBarLayer: some View {
        ZStack {
            if controls.visible && controls.loaded {
                VStack { Spacer(); controlBar }.transition(.opacity)
            } else if controls.transport.pillShown {
                VStack { Spacer(); seekPill }.transition(.opacity).allowsHitTesting(false)
            }
        }
        .onChange(of: controls.visible) { shown in
            if !shown { controls.bar.keyboard = false; controls.bar.lit = false }
        }
        .onChange(of: controls.buffering) { buffering in
            if buffering, controls.loaded { controls.flash("Loading \(PlayerControls.clock(Double(time.currentTime)))") }
        }
    }

    /// Android's floating pill: the progress label and band over a row of captioned tiles,
    /// bottom-centre, 28 pt up, capped to the width minus 88 pt (the row scrolls past that).
    var controlBar: some View {
        let total = max(1, Double(time.totalTime))
        let current = scrub.displayed(live: Double(time.currentTime))
        return ControlBarLook(tint: controls.tint) {
            scrubber(current: current, total: total)
        } row: {
            tileRow
        }
    }

    /// Android buildSeekProgressOverlay: the bar's label and band alone, 700 pt at most.
    private var seekPill: some View {
        let total = max(1, Double(time.totalTime))
        let current = Double(time.currentTime)
        return VStack(spacing: 3) {
            progressLabel(current: current, total: total)
            progressBand(current: current, total: total)
        }
        .seekPillCard(controls.tint)
    }

    /// "m:ss / h:mm:ss" in the text colour, 11 pt, centred. #128: both halves format at the
    /// total's field width, so the label never changes width under a drag.
    private func progressLabel(current: Double, total: Double) -> some View {
        HStack(spacing: 0) {
            Text(timeLabel(current, matching: total))
            Text(" / ")
            Text(timeLabel(total, matching: total))
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(controls.tint.text)
        .frame(maxWidth: .infinity)
    }

    /// The band at the live (or scrubbed) position, with KSPlayer's buffered range.
    private func progressBand(current: Double, total: Double) -> some View {
        let buffered = playback.player.playerLayer?.player.playableTime ?? 0
        func fraction(_ t: Double) -> Double { t.isFinite ? min(1, max(0, t / total)) : 0 }
        return ProgressBand(played: fraction(current), buffered: fraction(buffered), tint: controls.tint)
    }

    /// The label and the band as one drag target (Android #450 onControlBarTouch, which takes a
    /// finger's width around the band): press or drag previews the time under the pointer in the
    /// label and the band, release seeks there. Same ScrubState rules as the pre-#467 Slider:
    /// seed from the live position (#115), hold the OSD for the whole drag (#129), commit exactly
    /// once with `sliderTouchEnded` as the backup when SwiftUI drops the end (#131).
    private func scrubber(current: Double, total: Double) -> some View {
        GeometryReader { geo in
            VStack(spacing: 3) {
                progressLabel(current: current, total: total)
                progressBand(current: current, total: total)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard let target = ScrubState.target(x: drag.location.x, width: geo.size.width, duration: total) else { return }
                if !scrub.isScrubbing {
                    controls.scrubbing = true; scrub.begin(at: current)   // #129 hold the OSD, #115 seed from the live position
                    sliderDidBegin = true
                    Self.log.info("slider scrub begin at=\(current, privacy: .public)s total=\(total, privacy: .public)s")
                }
                scrub.update(to: target)
                controls.forceShow()
            }.onEnded { _ in
                // #131: a healthy release and a release the recovery already committed both
                // reach here; capture whether THIS callback is the one that seeked.
                let seekedHere = scrub.isScrubbing
                if scrub.isScrubbing { playback.seek(to: scrub.end()) }   // #131: skip if the recovery path already committed this drag
                Self.log.info("slider release delivered target=\(scrub.value, privacy: .public)s seeked=\(seekedHere, privacy: .public)")
                controls.scrubbing = false
                controls.scheduleHide()   // #129: resume the idle timer after release
            })
            // #131: rides along (never steals) purely so `sliderTouch` exists to be reset when
            // SwiftUI cancels the drag instead of ending it.
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($sliderTouch) { _, down, _ in down = true })
        }
    }

    /// The tiles, scrolled sideways when they do not fit (iPhone portrait, a narrow window);
    /// the lit tile scrolls into view (Android scrollFocusedControlIntoView).
    private var tileRow: some View {
        let row = HStack(spacing: 4) { ForEach(controls.barTiles, id: \.self) { tile($0) } }
        return ViewThatFits(in: .horizontal) {
            row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .onChange(of: controls.bar.focus) { f in withAnimation { proxy.scrollTo(f) } }
            }
        }
    }

    /// A tile button; the pointer lights the tile it is on (macOS).
    private func tile(_ t: BarTile) -> some View {
        Button { controls.pressTile(t) } label: {
            BarTileFace(glyph: t == .play && isPlaying ? BarTile.pauseGlyph : t.glyph, caption: t.caption,
                        lit: controls.bar.lit && controls.bar.focus == t, tint: controls.tint)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { inside in
            if inside { controls.bar.focus = t; controls.bar.lit = true }
            else if controls.bar.focus == t { controls.bar.lit = false }
        }
        #endif
        .id(t)
    }

    #if os(iOS)
    /// iOS (Android tablet #450 installVideoGestures): a tap on the picture closes the top layer,
    /// else shows or hides the bar (OK); a double-tap on the left or right half is the 15 s burst
    /// with the seek pill. Replaces the pre-#467 centre and corner zones. Below the OSD in
    /// PlayerView's ZStack, so the bar's tiles and band win.
    var touchRegions: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                    if controls.anyLayerOpen { controls.closeTopLayer() }
                    else { controls.seekKey(tap.location.x < geo.size.width / 2 ? -1 : 1) }
                }.exclusively(before: TapGesture().onEnded {
                    if !controls.closeTopLayer() { controls.okPress() }
                }))
        }
        .ignoresSafeArea()
    }
    #endif

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

// MARK: Look (no player behind it, so Tests' snapshot harness draws these with fake state)

/// A tile on the bar, in Android order (CONTROL_BUTTON_LABELS). No Up next: that is the
/// SmartTube Pi queue, out of scope on Apple.
enum BarTile: CaseIterable {
    case play, subtitles, subsDelay, audio, bookmark, aspect, quality, style, more

    var glyph: String {
        switch self {
        case .play: return "\u{25B6}\u{FE0E}"
        case .subtitles: return "CC"
        case .subsDelay: return "\u{23F1}\u{FE0E}"
        case .audio: return "\u{266A}"
        case .bookmark: return "\u{2605}"
        case .aspect: return "\u{25A3}"
        case .quality: return "HQ"
        case .style: return "Aa"
        case .more: return "\u{22EF}"
        }
    }

    /// The play tile while playing.
    static let pauseGlyph = "\u{275A}\u{275A}"

    var caption: String {
        switch self {
        case .play: return "Play / Pause"
        case .subtitles: return "Subtitles"
        case .subsDelay: return "Subs delay"
        case .audio: return "Audio"
        case .bookmark: return "Bookmark"
        case .aspect: return "Aspect"
        case .quality: return "Quality"
        case .style: return "Style"
        case .more: return "More"
        }
    }
}

/// Android buildControlBar: the progress strip laid over the top of the tile row, so the band
/// is exactly as wide as the row (Android syncProgressBarWidthToRow); the panel card with the
/// 0x66 accent hairline, bottom-centre, 28 pt up, 44 pt off each side.
struct ControlBarLook<Strip: View, Row: View>: View {
    let tint: OsdTint
    @ViewBuilder let strip: Strip
    @ViewBuilder let row: Row

    var body: some View {
        row
            .padding(.top, 30)
            .overlay(alignment: .top) { strip.frame(height: 30) }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .osdCard(fill: tint.panel, radius: 7, hairline: tint.accent(0x66))
            .padding(.horizontal, 44)
            .padding(.bottom, 28)
    }
}

extension View {
    /// Android buildSeekProgressOverlay: the bar's card around the label and band alone, at
    /// most 700 pt wide.
    func seekPillCard(_ tint: OsdTint) -> some View {
        padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
            .frame(maxWidth: 700)
            .osdCard(fill: tint.panel, radius: 7, hairline: tint.accent(0x66))
            .padding(.horizontal, 44)
            .padding(.bottom, 28)
    }
}

/// The 6 pt band: played over buffered over the track, as fractions of the duration. Apple TV
/// tint: white on a 0.3 white track (OsdTint.progress); Simple: the accent.
struct ProgressBand: View {
    let played: Double
    let buffered: Double
    let tint: OsdTint

    var body: some View {
        let fill = tint.progress ?? tint.accent
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(fill.opacity(0.3))
                Capsule().fill(fill.opacity(0.5)).frame(width: geo.size.width * buffered)
                Capsule().fill(fill).frame(width: geo.size.width * played)
            }
        }
        .frame(height: 6)
    }
}

/// Android updateControlBarFocusVisual: bold 18 pt glyph over a 10 pt caption, at least 80 pt
/// wide, `row` fill; lit, `accent` fill with `onAccent` text.
struct BarTileFace: View {
    let glyph: String
    let caption: String
    let lit: Bool
    let tint: OsdTint

    var body: some View {
        VStack(spacing: 2) {
            Text(glyph)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(lit ? tint.onAccent : .white)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(lit ? tint.onAccent.opacity(0.9) : tint.text(0xCC))
        }
        .lineLimit(1)
        .padding(.horizontal, 5).padding(.vertical, 4)
        .frame(minWidth: 80)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(lit ? tint.accent : tint.row))
        .contentShape(Rectangle())
    }
}
