import KSPlayer

// E4 (#469) owns this file with QualitySheet.swift: the audio sheet.
// #466 moved the pre-#466 rows here unchanged.

extension PlayerControls {
    func audioSheetContent() -> OSDSheetContent {
        let tracks = playback?.player.playerLayer?.player.tracks(mediaType: .audio) ?? []
        if tracks.isEmpty {
            return OSDSheetContent(title: "Audio", rows: [OSDItem(id: "none", label: "No audio tracks", selected: false, enabled: false, action: {})])
        }
        let p = playback
        return OSDSheetContent(title: "Audio", rows: tracks.enumerated().map { idx, t in
            OSDItem(id: "a\(idx)", label: t.name, detail: t.languageCode, selected: t.isEnabled, action: { [weak self] in
                p?.player.playerLayer?.player.select(track: t)
                self?.flash("Audio: \(t.name)")
            })
        })
    }

    /// Stub: the generic sheet keys apply.
    func audioSheetHandleKey(_ key: OSDKey) -> Bool { false }
}
