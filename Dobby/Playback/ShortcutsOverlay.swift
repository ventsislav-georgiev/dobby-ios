import SwiftUI

// E9 (#474) owns this file with MoreMenu.swift: the "Player shortcuts" card (Android
// buildShortcutsOverlay :1848-1895), opened by holding Return 550 ms or "?" (the router does
// both). #466 stub: a plain card listing today's keys.

extension PlayerControls {
    /// Keys while the card is open. Return closes it; Esc closes it through the router.
    func shortcutsHandleKey(_ key: OSDKey) -> Bool {
        guard key == .ret else { return false }
        shortcutsOpen = false
        return true
    }
}

extension PlayerView {
    /// Always in the tree; draws while `controls.shortcutsOpen`.
    var shortcutsOverlay: some View {
        ZStack {
            if controls.shortcutsOpen {
                let tint = controls.tint
                VStack(alignment: .leading, spacing: 6) {
                    Text("Player shortcuts").font(.system(size: 22, weight: .bold)).foregroundStyle(tint.accent)
                    ForEach([
                        "Space  play / pause", "◀ ▶  seek", "Return / click  show or hide the bar",
                        "S  subtitles   A  audio   Q  quality   W  aspect   D  speed",
                        "F / double-click  fullscreen   I  info   Esc  back",
                    ], id: \.self) { Text($0) }
                    .font(.system(size: 16)).foregroundStyle(tint.text)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(width: 520, alignment: .leading)
                .osdCard(fill: tint.sheet, radius: 9, hairline: tint.accent(0x4D))
                .onTapGesture { controls.shortcutsOpen = false }
            }
        }
    }
}
