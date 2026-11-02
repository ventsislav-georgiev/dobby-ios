import SwiftUI
import KSPlayer

// E6 (#471) owns this file with SubsDelayModel.swift: the subtitle delay pill, its keys and
// how the delay reaches KSPlayer (Android openSubsDelayOsd :8244-8336, view :1613-1667).
// KSPlayer applies subtitleDelay per render, so there is no 1 s debounce (Android's was for a
// subtitle reattach). The fps correction is a time-dependent delay, rewritten every tick.

extension PlayerControls {
    func openSubsDelay() { syncSubsDelay(); subsDelayOpen = true; forceShow() }

    /// Called on every change of `subsDelay`: write the delay for the current position.
    /// `subsDelay.applied = d` below fires subsDelay's didSet, which calls back in here; with
    /// fps on, offset(at:) reads the live clock, so each re-entry gets a new d and never stops.
    private static var applyingSubsDelay = false

    func applySubsDelay() {
        guard !Self.applyingSubsDelay else { return }
        Self.applyingSubsDelay = true
        defer { Self.applyingSubsDelay = false }
        guard let player = playback?.player else { return }
        let d = subsDelay.offset(at: player.playerLayer?.player.currentPlaybackTime ?? 0)
        guard d != subsDelay.applied else { return }
        player.subtitleModel.subtitleDelay = d
        subsDelay.applied = d
    }

    /// Every playback tick (about 10 Hz): pick up a delay the page set, follow the fps drift.
    func subsDelayTick(current: TimeInterval) {
        syncSubsDelay()
        if subsDelay.fpsIndex != 0 { applySubsDelay() }
    }

    /// A new title starts from KSPlayer's value with fps Off; a value someone else wrote to
    /// the player (setSubtitleOffsetMs) becomes the delay and flashes the pill, as Android
    /// applyExternalSubsDelay does.
    private func syncSubsDelay() {
        guard let p = playback else { return }
        let cur = p.player.subtitleModel.subtitleDelay
        if subsDelay.ref != p.activeRef {
            var m = SubsDelayModel()
            m.ref = p.activeRef; m.delay = cur; m.applied = cur
            m.flashing = subsDelay.flashing; m.flashToken = subsDelay.flashToken
            subsDelay = m
            return
        }
        var m = subsDelay
        if m.adopt(playerDelay: cur) { subsDelay = m; flashSubsDelay() }
    }

    private func flashSubsDelay() {
        subsDelay.flashToken += 1
        subsDelay.flashing = true
        let token = subsDelay.flashToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // Android SUBS_DELAY_HUD_AUTOHIDE_MS
            guard let self, self.subsDelay.flashToken == token else { return }
            self.subsDelay.flashing = false
        }
    }

    /// Steps, fps and reset: the keys, the global keys and the pill's buttons all land here.
    func subsDelayStep(_ d: Int) { syncSubsDelay(); subsDelay.step(d); flashSubsDelay() }
    func subsDelayCycleFps(_ d: Int) { syncSubsDelay(); subsDelay.cycleFps(d); flashSubsDelay() }
    func subsDelayReset() { syncSubsDelay(); subsDelay.reset(); flashSubsDelay() }

    /// Keys while the pill is open (it is the top layer). Esc falls to the router, which closes it.
    func subsDelayHandleKey(_ key: OSDKey) -> Bool {
        switch key {
        case .left, .char(","): subsDelayStep(-1)
        case .right, .char("."): subsDelayStep(1)
        case .up: subsDelayCycleFps(-1)
        case .down: subsDelayCycleFps(1)
        case .ret, .char("/"): subsDelayReset()
        default: return false
        }
        return true
    }

    /// "," "." "/" on the bare picture: -100 ms, +100 ms, reset, each flashing the pill.
    func subsDelayGlobalKey(_ key: OSDKey) -> Bool {
        switch key {
        case .char(","): subsDelayStep(-1)
        case .char("."): subsDelayStep(1)
        case .char("/"): subsDelayReset()
        default: return false
        }
        return true
    }
}

extension PlayerView {
    /// Always in the tree; draws while the pill is open or flashing. Top-centre 20 pt (Android
    /// 40 px), osdFill with the yellow hairline. ◀ ▶ and ▲ ▼ are buttons for the mouse and
    /// touch (no "," "." on a phone); the chip resets.
    var subsDelayPill: some View {
        ZStack {
            if controls.subsDelayOpen || controls.subsDelay.flashing {
                let tint = controls.tint
                let m = controls.subsDelay
                let fps = Double(playback.player.playerLayer?.player.nominalFrameRate ?? 0)
                VStack {
                    HStack(spacing: 9) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                pillButton("◀") { controls.subsDelayStep(-1) }
                                Text("Subs delay  \(m.label)").monospacedDigit()
                                pillButton("▶") { controls.subsDelayStep(1) }
                            }
                            HStack(spacing: 6) {
                                pillButton("▲") { controls.subsDelayCycleFps(-1) }
                                pillButton("▼") { controls.subsDelayCycleFps(1) }
                                Text(m.fpsLabel(videoFps: fps))
                            }
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        Text("⟳ Reset (OK)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(argb: 0xFFF1C40F))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .osdCard(fill: Color(argb: 0x33F1C40F), radius: 6, hairline: Color(argb: 0x66F1C40F))
                            .contentShape(Rectangle())
                            .onTapGesture { controls.subsDelayReset() }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .osdCard(fill: tint.osdFill, radius: 9, hairline: Color(argb: 0x66F1C40F))
                    .padding(.top, 20 + pillTopInset)
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
        }
    }

    /// A glyph with a finger-sized hit area (touch) that the mouse clicks the same way.
    private func pillButton(_ glyph: String, _ action: @escaping () -> Void) -> some View {
        Text(glyph)
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    /// PlayerView.topSafeInset is private to the E1 file; the same read (an ancestor ignores
    /// the safe area, so GeometryReader reports zero).
    private var pillTopInset: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
        #else
        0
        #endif
    }
}
