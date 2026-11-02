import SwiftUI
import KSPlayer

// E9 (#474) owns this file with MoreMenuModel.swift (state, pure) and ShortcutsOverlay.swift:
// the More menu (Speed, Info, Pause on OK), the Pause on OK behaviour and the Speed sheet.
// Android: buildMoreMenuOverlay :9101-9131, open/close :9298-9318, #274 Pause on OK.

extension PlayerControls {
    /// The bar's ⋯ tile (E2) calls this. Android openMoreMenu: focus the first row, hide the
    /// bar (it comes back on close, `onBarePicture`).
    func openMoreMenu() {
        more.focus = 0
        more.restoreBar = visible
        moreOpen = true          // first, so hiding the bar below is not a return to the bare picture
        visible = false
    }

    /// Up/down move, Return picks; left/right are swallowed (they would seek under the dim,
    /// Android swallows every key here). Space, letters and Esc fall through to the router.
    func moreMenuHandleKey(_ key: OSDKey) -> Bool {
        switch key {
        case .up: more.move(-1)
        case .down: more.move(1)
        case .ret: pickMoreRow(more.focus)
        case .left, .right: break
        default: return false
        }
        return true
    }

    func moreRowLabel(_ row: MoreMenuRow) -> String {
        switch row {
        case .speed:
            let r = playback?.player.playbackRate ?? 1
            return "Speed: " + (abs(r - 1) < 0.01 ? "Normal" : "\(trimRate(r))×")
        case .info: return "Info: " + (showInfo ? "On" : "Off")
        case .pauseOnOk: return "Pause on OK: " + (more.pauseOnOk ? "On" : "Off")
        }
    }

    /// The menu stays open under what a row opens: closing the Speed sheet lands back here.
    func pickMoreRow(_ idx: Int) {
        guard MoreMenuRow.allCases.indices.contains(idx) else { return }
        more.focus = idx
        switch MoreMenuRow.allCases[idx] {
        case .speed: openSheet(.speed)
        case .info: showInfo.toggle()
        case .pauseOnOk:
            more.togglePauseOnOk()
            flash(moreRowLabel(.pauseOnOk))
        }
    }

    /// OK on the bare picture, just before the bar shows (Android handleSelectPress
    /// :7160-7166). No toast: the bar's play tile already reads paused.
    func pauseOnOkIfEnabled() {
        guard more.okShouldPause(playing: isPlaying, started: loaded) else { return }
        playback?.player.playerLayer?.pause()
    }

    /// The bar and every layer just closed. The More menu's close brings its bar back first
    /// (Android closeMoreMenu, which then finds the bar up and resumes nothing); otherwise a
    /// Pause-on-OK pause resumes (Android resumeIfPausedByOk :2641-2649). Idempotent.
    func onBarePicture() {
        if more.restoreBar {
            more.restoreBar = false
            forceShow()
            return
        }
        guard more.bareShouldResume(paused: !isPlaying) else { return }
        playback?.player.playerLayer?.play()
    }

    // MARK: Speed sheet (Mac extra; E9 reaches it from a More menu row)

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    func speedSheetContent() -> OSDSheetContent {
        guard let p = playback else { return OSDSheetContent(title: "Speed", rows: []) }
        return OSDSheetContent(title: "Speed", rows: Self.speeds.map { s in
            OSDItem(id: "s\(s)", label: s == 1.0 ? "Normal" : "\(trimRate(s))×",
                    selected: abs(p.player.playbackRate - s) < 0.01, action: { [weak self] in
                p.player.playbackRate = s
                self?.flash("Speed: \(s == 1.0 ? "Normal" : "\(self?.trimRate(s) ?? "")×")")
            })
        })
    }

    /// Stub: the generic sheet keys apply.
    func speedSheetHandleKey(_ key: OSDKey) -> Bool { false }

    func trimRate(_ s: Float) -> String {
        let str = String(format: "%.2f", s)
        return str.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

extension PlayerView {
    /// Always in the tree. Android: #88000000 dim, a 280 pt menuCard card 48 pt from the right,
    /// vertically centred, padding 16/24, rows 18 pt padded 12/14, unselected #CCCCCC, the
    /// focused row filled menuSelected with white text. A click on the dim closes it.
    var moreMenu: some View {
        ZStack {
            if controls.moreOpen {
                let tint = controls.tint
                Color(argb: 0x88000000).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { controls.closeTopLayer() }
                VStack(spacing: 8) {
                    ForEach(Array(MoreMenuRow.allCases.enumerated()), id: \.offset) { i, row in
                        let focused = i == controls.more.focus
                        Text(controls.moreRowLabel(row))
                            .font(.system(size: 18))
                            .foregroundStyle(focused ? Color.white : Color(argb: 0xFFCCCCCC))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(focused ? tint.menuSelected : Color.clear)
                            .contentShape(Rectangle())
                            .onHover { if $0 { controls.more.focus = i } }
                            .onTapGesture { controls.pickMoreRow(i) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 24)
                .frame(width: 280)
                .background(tint.menuCard)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 48)
            }
        }
    }
}
