import SwiftUI

// #560 owns this file with SkipSegments.swift (pure): the Skip intro / Skip recap button, the
// Skipped label after an auto-skip, and the Next episode button at the credits. Driven by
// PlayerControls.playbackTick; firing next ends playback like the natural end, with next: true.

extension PlayerControls {
    /// Every playback tick: advance the state, run the seek or the next it asks for.
    func skipTick(current: TimeInterval) {
        guard let p = playback else { return }
        var s = skip
        let action = s.tick(ref: p.activeRef, position: current, duration: p.remoteDuration, skip: p.request?.skip)
        if s != skip { skip = s }   // only a change re-renders the OSD (ticks come at about 10 Hz)
        switch action {
        case .seek(let t)?: p.seek(to: t)
        case .next?: skipNext()
        case nil: break
        }
    }

    /// The Skip intro / Skip recap button: seek to the segment's end.
    func skipPress() {
        guard let t = skip.buttonTarget(playback?.request?.skip) else { return }
        skip.button = nil
        playback?.seek(to: t)
    }

    /// The Next episode button, or its countdown running out.
    func skipNext() {
        skip = SkipState()
        playback?.onFinish(error: nil, next: true)
    }

    /// Ahead of every layer: Return on a visible button while the OSD is hidden presses it; any
    /// other key cancels a running countdown (the button stays). Esc only cancels; the rest
    /// still do their own thing.
    func skipHandleKey(_ key: OSDKey) -> Bool {
        if key == .ret, !visible, !anyLayerOpen {
            if skip.button != nil { skipPress(); return true }
            if skip.nextShown { skipNext(); return true }
        }
        guard skip.countdown != nil else { return false }
        skip.cancelCountdown()
        return key == .escape
    }
}

extension PlayerView {
    /// Always in the tree; bottom-trailing, above the control bar while it shows. Phone: tap;
    /// Mac: click, or Return while the OSD is hidden.
    var skipOverlay: some View {
        let s = controls.skip
        let tint = controls.tint
        return ZStack {
            if let kind = s.button {
                skipButton("Skip \(kind.rawValue)", tint: tint) { controls.skipPress() }
            } else if s.nextShown {
                skipButton(s.countdown.map { "Next episode  \($0)" } ?? "Next episode", tint: tint) { controls.skipNext() }
            } else if let kind = s.skipped {
                Text("Skipped \(kind.rawValue)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .osdCard(fill: tint.osdFill, radius: 9, hairline: tint.accent(0x66))
                    .allowsHitTesting(false)
            }
        }
        .padding(.trailing, 44)
        .padding(.bottom, controls.visible && controls.loaded ? barCover + 12 : 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.16), value: s)
    }

    /// Drawn as a focused sheet row (accent fill, onAccent text): Return presses it.
    private func skipButton(_ title: String, tint: OsdTint, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(tint.onAccent)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .osdCard(fill: tint.accent, radius: 10, hairline: tint.accent(0x66))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }
}
