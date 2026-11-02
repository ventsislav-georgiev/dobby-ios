import KSPlayer

// E3 (#468) owns this file with SubtitleOrdering.swift: the subtitles sheet.
// #466 moved the pre-#466 track rows here unchanged; the style / size / position rows moved to
// StyleSheet.swift (E5) and the delay rows to the subtitle delay pill (E6).

/// E3's sheet state (active language tab, pending catalog row and its 60 s timeout, ...).
struct SubtitleSheetState {}

extension PlayerControls {
    func subtitleSheetContent() -> OSDSheetContent {
        guard let p = playback else { return OSDSheetContent(title: "Subtitles", rows: []) }
        var rows: [OSDItem] = [OSDItem(
            id: "off",
            label: "Off",
            selected: p.player.subtitleModel.selectedSubtitleInfo == nil,
            action: { [weak self] in
                p.player.subtitleModel.selectedSubtitleInfo = nil
                self?.flash("Subtitles off")
            })]
        for info in p.player.subtitleModel.subtitleInfos {
            let sel = p.player.subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID
            // Sideloaded subs (URLSubtitleInfo) carry a source-prefixed label from
            // the web layer (Stremio -, Addic7ed -); mark in-container tracks so
            // the two are distinguishable in the list.
            let name = info is URLSubtitleInfo ? info.name : "Embedded - \(info.name)"
            rows.append(OSDItem(id: info.subtitleID, label: name, selected: sel, action: { [weak self] in
                p.player.subtitleModel.selectedSubtitleInfo = info
                self?.flash("Subtitles: \(name)")
            }))
        }
        // Online catalog (web-pushed a4k/Stremio/etc. results): pick-to-download.
        // Already-attached ids are hidden — they show as regular rows above.
        for entry in p.subtitleCatalog where !p.attachedCatalogIds.contains(entry.id) {
            let name = entry.displayName
            rows.append(OSDItem(id: "cat-\(entry.id)", label: "⬇ \(name)", detail: entry.lang,
                                selected: false, action: { [weak self] in
                p.requestCatalogSubtitle(id: entry.id)
                self?.flash("Loading: \(name)")
            }))
        }
        return OSDSheetContent(title: "Subtitles", rows: rows)
    }

    /// Stub: the generic sheet keys apply. E3: tab switching etc. if the generic keys fall short.
    func subtitleSheetHandleKey(_ key: OSDKey) -> Bool { false }
}
