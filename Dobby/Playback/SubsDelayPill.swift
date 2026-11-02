import SwiftUI
import KSPlayer

// E6 (#471) owns this file with SubsDelayModel.swift: the subtitle delay pill, its keys and
// how the delay reaches KSPlayer. #466 stub: a top-centre pill stepping the pre-#466 presets
// (the delay rows that used to sit in the subtitles menu), opened from the bar's ⏱ button.

extension PlayerControls {
    func openSubsDelay() { subsDelayOpen = true; forceShow() }

    /// Called on every change of `subsDelay`. E6: debounce, fps correction.
    func applySubsDelay() { playback?.player.subtitleModel.subtitleDelay = subsDelay.delay }

    /// Every playback tick (about 10 Hz). E6: the time-dependent fps-corrected delay.
    func subsDelayTick(current: TimeInterval) {}

    /// Keys while the pill is open (it is the top layer).
    func subsDelayHandleKey(_ key: OSDKey) -> Bool {
        switch key {
        case .left: subsDelay.step(-1)
        case .right: subsDelay.step(1)
        case .up, .down: break
        case .ret: subsDelayOpen = false; scheduleHide()
        default: return false
        }
        return true
    }

    /// "," "." "/" on the bare picture. Stub: not handled (the keys pass through as before).
    /// E6: -100 ms, +100 ms, reset, each flashing the pill.
    func subsDelayGlobalKey(_ key: OSDKey) -> Bool { false }
}

extension PlayerView {
    /// Always in the tree; draws while the pill is open (E6: also while it flashes).
    var subsDelayPill: some View {
        ZStack {
            if controls.subsDelayOpen {
                let tint = controls.tint
                VStack {
                    HStack(spacing: 14) {
                        Text("◀").onTapGesture { controls.subsDelay.step(-1) }
                        Text("Subs delay  \(controls.subsDelay.label)")
                        Text("▶").onTapGesture { controls.subsDelay.step(1) }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .osdCard(fill: tint.osdFill, radius: 9, hairline: Color(argb: 0x66F1C40F))
                    .padding(.top, 20)
                    Spacer()
                }
            }
        }
    }
}
