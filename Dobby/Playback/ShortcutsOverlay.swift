import SwiftUI

// E9 (#474) owns this file with MoreMenu.swift: the "Player shortcuts" card (Android
// buildShortcutsOverlay :1848-1895), opened by holding Return 550 ms or "?" (the router does
// both). It lists exactly the keys PlayerControls' bare-picture router handles. iPhone and iPad
// without a keyboard never reach it (no key input there), so touch needs nothing more.

extension PlayerControls {
    /// Keys while the card is open. Return closes it; Esc closes it through the router.
    func shortcutsHandleKey(_ key: OSDKey) -> Bool {
        guard key == .ret else { return false }
        shortcutsOpen = false
        return true
    }
}

extension PlayerControls {
    /// One line per key the router's bare picture handles (PlayerControls.barePictureKey), in
    /// Android's "key — action" form.
    static let shortcutLines = [
        "Space — Play / Pause",
        "← / → — Seek",
        "↑ / ↓ — Jump 20 %",
        "Return / click — Show or hide the bar",
        "Hold Return / ? — Toggle shortcuts",
        "S — Subtitles   A — Audio   Q — Quality",
        "W — Aspect   D — Speed   I — Info",
        ", / . — Subtitle delay ±100 ms   / — Delay pill",
        "B — Add bookmark at current position",
        "F / double-click — Fullscreen",
        "Esc — Back, leave fullscreen, exit playback",
    ]
}

extension PlayerView {
    /// Always in the tree; draws while `controls.shortcutsOpen`.
    var shortcutsOverlay: some View {
        ZStack {
            if controls.shortcutsOpen {
                let tint = controls.tint
                VStack(alignment: .leading, spacing: 4) {
                    Text("Player shortcuts").font(.system(size: 22, weight: .bold)).foregroundStyle(tint.accent)
                    ForEach(PlayerControls.shortcutLines, id: \.self) { Text($0) }
                    .font(.system(size: 16)).foregroundStyle(tint.text)
                }
                .padding(30)
                .frame(width: 520, alignment: .leading)
                .osdCard(fill: tint.sheet, radius: 9, hairline: tint.accent(0x4D))
                .onTapGesture { controls.shortcutsOpen = false }
            }
        }
    }
}
