import Foundation
import KSPlayer

// E3 (#468) owns this file with SubtitleOrdering.swift: the subtitles sheet (Android
// populateTrackSheet "subtitles" :4363-4440, tabs :4649-4702). One merged list of embedded,
// attached and catalog subtitles in Android's order, split into language tabs, numbered over
// the full list so a number is stable across tabs; a picked catalog row shows ⏳ until it
// attaches or 60 s pass. Picking never closes the sheet (Android #023): Esc, a click outside or
// the iOS edge swipe does. Touch: tabs and rows are tappable (OSDSheetView).

/// E3's sheet state.
struct SubtitleSheetState {
    /// The active language tab, set to the playing subtitle's tab when the sheet opens.
    var tab = 0
    /// Catalog ids requested and not yet attached: their rows show ⏳ (Android loadedCatalogIds).
    var pending: Set<String> = []
}

/// One row before ordering.
private struct SubtitleRow {
    let id: String
    let label: String
    let key: SubtitleSortKey
    let selected: Bool
    let pick: () -> Void
}

extension PlayerControls {
    /// Android CATALOG_SUBTITLE_TIMEOUT_MS.
    private static let catalogTimeoutNs: UInt64 = 60_000_000_000

    private var subtitlePriority: [String] {
        SubtitleOrdering.languagePriority(playback?.request?.preferredSubtitleLang,
                                          deviceLanguage: Locale.current.language.languageCode?.identifier)
    }

    /// Every subtitle the sheet can list, unordered: the player's tracks (embedded and
    /// sideloaded), then the catalog rows not attached yet.
    private func subtitleRows(_ p: PlaybackCoordinator, priority: [String]) -> [SubtitleRow] {
        var rows: [SubtitleRow] = []
        let model = p.player.subtitleModel
        for info in model.subtitleInfos {
            let sel = model.selectedSubtitleInfo?.subtitleID == info.subtitleID
            let lang: String?
            let label: String
            if info is URLSubtitleInfo {
                // Sideloaded: the web's label already names its source and flag.
                label = info.name
                lang = subtitleLang(ofLabel: info.name, p, priority: priority)
            } else {
                lang = SubtitleOrdering.normalize((info as? MediaPlayerTrack)?.languageCode)
                let flag = SubtitleOrdering.flag(lang)
                label = "Embedded - " + (flag.isEmpty ? "" : flag + " ") + info.name
            }
            rows.append(SubtitleRow(id: info.subtitleID, label: label,
                                    key: SubtitleSortKey(lang: lang, sdh: SubtitleOrdering.isSdh(info.name), rank: 0),
                                    selected: sel, pick: { [weak self] in
                model.selectedSubtitleInfo = info
                self?.flash("Subtitles: \(label)")
            }))
        }
        for entry in p.subtitleCatalog where !p.attachedCatalogIds.contains(entry.id) {
            let label = entry.label ?? SubtitleOrdering.catalogLabel(lang: entry.lang, id: entry.id,
                                                                     fileName: entry.fileName)
            let shown = (subtitleSheet.pending.contains(entry.id) ? "⏳ " : "") + label
            rows.append(SubtitleRow(id: "cat-\(entry.id)", label: shown,
                                    key: SubtitleSortKey(lang: SubtitleOrdering.normalize(entry.lang), sdh: false,
                                                         rank: entry.provider == "a4k" ? 2 : 1),
                                    selected: false, pick: { [weak self] in
                self?.requestCatalogSubtitle(entry.id, p)
                self?.flash("Loading: \(label)")
            }))
        }
        return rows
    }

    /// A sideloaded subtitle's language: the catalog entry or payload track carrying the same
    /// label, else the flag in the label (SubtitleOrdering.languageFromLabel).
    private func subtitleLang(ofLabel name: String, _ p: PlaybackCoordinator, priority: [String]) -> String? {
        if let e = p.subtitleCatalog.first(where: { $0.label == name }) { return SubtitleOrdering.normalize(e.lang) }
        if let t = p.request?.subs?.first(where: { ($0.label ?? $0.lang) == name }) {
            return SubtitleOrdering.normalize(t.lang)
        }
        return SubtitleOrdering.languageFromLabel(name, priority: priority)
    }

    private func requestCatalogSubtitle(_ id: String, _ p: PlaybackCoordinator) {
        p.requestCatalogSubtitle(id: id)
        subtitleSheet.pending.insert(id)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.catalogTimeoutNs)
            guard let self, self.subtitleSheet.pending.remove(id) != nil else { return }
            if !(self.playback?.attachedCatalogIds.contains(id) ?? false) { self.flash("Subtitle timed out") }
        }
    }

    /// Called by `openSheet(.subtitles)` before it places the focus: land on the tab holding
    /// the playing subtitle (Android tabOfActiveSubtitle). Refreshes keep the user's tab.
    func subtitleSheetWillOpen() {
        guard let p = playback else { subtitleSheet.tab = 0; return }
        let priority = subtitlePriority
        let playing = subtitleRows(p, priority: priority).first { $0.selected }
        subtitleSheet.tab = SubtitleOrdering.tabIndex(of: playing?.key.lang, priority: priority)
    }

    func subtitleSheetContent() -> OSDSheetContent {
        guard let p = playback else { return OSDSheetContent(title: "Subtitles", rows: []) }
        let priority = subtitlePriority
        let tabs = SubtitleOrdering.tabs(priority: priority)
        let tab = min(max(subtitleSheet.tab, 0), tabs.count - 1)
        let all = subtitleRows(p, priority: priority)
        let ordered = SubtitleOrdering.order(all.map(\.key), priority: priority)
        let model = p.player.subtitleModel
        var items = [OSDItem(id: "off", label: "Off", selected: model.selectedSubtitleInfo == nil) { [weak self] in
            model.selectedSubtitleInfo = nil
            self?.flash("Subtitles off")
        }]
        var shown = 0
        for (n, i) in ordered.enumerated()
        where SubtitleOrdering.inTab(all[i].key.lang, tabs[tab], priority: priority) {
            let row = all[i]
            items.append(OSDItem(id: row.id, label: "\(n + 1). \(row.label)", selected: row.selected, action: row.pick))
            shown += 1
        }
        if shown == 0 {
            let label = tabs.count > 1
                ? "Nothing in \(SubtitleOrdering.tabTitle(tabs[tab])) — ◀/▶ for other tabs"
                : "No subtitle tracks available yet"
            items.append(OSDItem(id: "empty", label: label, selected: false) { [weak self] in
                self?.flash("Subtitles still loading")
            })
        }
        return OSDSheetContent(title: "Subtitles (\(shown), ◀/▶ language)", rows: items,
                               tabs: tabs.map(SubtitleOrdering.tabTitle), activeTab: tab,
                               selectTab: { [weak self] i in
            // A different list: the old row index means nothing (Android cycleSubtitleTab).
            self?.subtitleSheet.tab = i
            self?.focusIndex = 0
        })
    }

    /// The generic sheet keys cover it: up/down rows, left/right tabs, Return picks.
    func subtitleSheetHandleKey(_ key: OSDKey) -> Bool { false }
}
