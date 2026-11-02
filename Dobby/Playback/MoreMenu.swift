import SwiftUI
import KSPlayer

// E9 (#474) owns this file with ShortcutsOverlay.swift: the More menu (Pause on OK, Speed and
// Info rows), the Pause on OK behaviour and the Speed sheet. #466 moved the pre-#466 speed rows
// here unchanged; the More menu itself is a stub (nothing opens it yet).

/// E9's state (the More menu's focused row, Pause on OK and whether this pause came from it, ...).
struct MoreMenuState {}

extension PlayerControls {
    /// The bar's ⋯ tile (E2) calls this. Stub: opens an empty layer.
    func openMoreMenu() { moreOpen = true; forceShow() }

    /// Keys while the More menu is open. Stub: none (Esc closes it through the router).
    func moreMenuHandleKey(_ key: OSDKey) -> Bool { false }

    /// OK on the bare picture, just before the bar shows. E9: pause when Pause on OK is on
    /// and the video has started (Android handleSelectPress :7160-7166).
    func pauseOnOkIfEnabled() {}

    /// The bar and every layer just closed. E9: resume a Pause-on-OK pause (Android
    /// resumeIfPausedByOk :2641-2649). Called on every layer change while bare, so it must
    /// check its own flag and be idempotent.
    func onBarePicture() {}

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

    private func trimRate(_ s: Float) -> String {
        let str = String(format: "%.2f", s)
        return str.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

extension PlayerView {
    /// Always in the tree; E9 draws the right-side card over a dim while `controls.moreOpen`.
    var moreMenu: some View { EmptyView() }
}
