import Foundation

// E3 (#468) owns this file: the pure ordering behind the subtitles sheet (Android
// orderedSubtitleEntries :7395-7436, tabs :4618-4702, flags/codes :7522-7584). No SwiftUI or
// KSPlayer import, so Tests/run-checks.sh compiles it standalone with
// Tests/SubtitleOrderingCheck.swift.

/// What the order looks at for one subtitle row. `rank` is the source type within a language:
/// 0 embedded or already attached, 1 Stremio (any online provider but a4k), 2 a4k.
struct SubtitleSortKey {
    let lang: String?
    let sdh: Bool
    let rank: Int
}

enum SubtitleOrdering {
    /// The tab after the preferred languages: no language, or a language not preferred.
    static let otherTab = "*other"

    /// The payload's preferredSubtitleLang / preferredAudioLang comma list ("bg, en") as
    /// lowercased codes in order, blanks and repeats dropped.
    static func preferredLanguages(_ csv: String?) -> [String] {
        var out: [String] = []
        for part in (csv ?? "").split(separator: ",") {
            let code = part.trimmingCharacters(in: .whitespaces).lowercased()
            if !code.isEmpty, !out.contains(code) { out.append(code) }
        }
        return out
    }

    /// Android languagePriority + normalizedLanguagePriority: the preferred list, then the
    /// device language, then English, as two-letter codes without repeats.
    static func languagePriority(_ csv: String?, deviceLanguage: String?) -> [String] {
        var out: [String] = []
        for raw in preferredLanguages(csv) + [deviceLanguage ?? "", "en"] {
            if let code = normalize(raw), !out.contains(code) { out.append(code) }
        }
        return out
    }

    /// Android normalizeLangCode: "en-US" / "pt_BR" / "eng" -> "en" / "pt" / "en". Empty and
    /// "und" (the web's unknown) are no language.
    static func normalize(_ raw: String?) -> String? {
        LanguageCodes.normalize(raw)
    }

    /// Android languageFlag: the regional-indicator flag for a language, "" when unmapped.
    static func flag(_ lang: String?) -> String {
        LanguageCodes.flag(normalize(lang))
    }

    /// English display name ("bg" -> "Bulgarian"), the upper-cased code when unknown.
    static func displayName(_ lang: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: lang) ?? lang.uppercased()
    }

    /// Android orderedSubtitleEntries: indices of `keys` in sheet order. Preferred languages
    /// first; then source type (embedded < Stremio < a4k); then preference order; other
    /// languages by English name, unknown last; SDH before plain; stable otherwise.
    static func order(_ keys: [SubtitleSortKey], priority: [String]) -> [Int] {
        let prefRank = keys.map { k in k.lang.flatMap { priority.firstIndex(of: $0) } ?? Int.max }
        let names = keys.map { k in k.lang.map { displayName($0).lowercased() } ?? "zzz" }
        return keys.indices.sorted { a, b in
            let pa = prefRank[a] != Int.max, pb = prefRank[b] != Int.max
            if pa != pb { return pa }
            if keys[a].rank != keys[b].rank { return keys[a].rank < keys[b].rank }
            if prefRank[a] != prefRank[b] { return prefRank[a] < prefRank[b] }
            if names[a] != names[b] { return names[a] < names[b] }
            if keys[a].sdh != keys[b].sdh { return keys[a].sdh }
            return a < b
        }
    }

    /// The tab strip: one tab per priority language, then Other.
    static func tabs(priority: [String]) -> [String] { priority + [otherTab] }

    static func tabTitle(_ tab: String) -> String { tab == otherTab ? "Other" : displayName(tab) }

    /// Android entryInTab: Other collects no-language rows and every non-preferred language.
    static func inTab(_ lang: String?, _ tab: String, priority: [String]) -> Bool {
        if tab == otherTab { return lang.map { !priority.contains($0) } ?? true }
        return lang == tab
    }

    /// Android tabOfActiveSubtitle: the tab holding the playing subtitle, the first tab when
    /// nothing plays.
    static func tabIndex(of lang: String?, priority: [String]) -> Int {
        guard let lang else { return 0 }
        return priority.firstIndex(of: lang) ?? priority.count
    }

    /// Android buildCatalogEntryLabel for a catalog row the web sent without a label:
    /// "🇬🇧 EN · release name", else "🇬🇧 EN · #1234".
    static func catalogLabel(lang: String?, id: String, fileName: String?) -> String {
        let flag = flag(lang)
        var out = (flag.isEmpty ? "" : flag + " ") + (lang?.uppercased() ?? "Track")
        let file = (fileName ?? "").trimmingCharacters(in: .whitespaces)
        let detail = !file.isEmpty ? file : (id.isEmpty ? "" : "#" + id.suffix(4))
        if !detail.isEmpty { out += " · " + detail }
        return out
    }

    /// A sideloaded subtitle keeps only its label on Apple (KSPlayer's URLSubtitleInfo has no
    /// language), and the web's labels carry the language flag ("Stremio - 🇧🇬 Bulgarian ·
    /// ..."). The first priority language whose flag is in the label, else nil (Other).
    static func languageFromLabel(_ label: String, priority: [String]) -> String? {
        priority.first { let f = flag($0); return !f.isEmpty && label.contains(f) }
    }

    /// Android isSdhGroup's label half.
    static func isSdh(_ label: String) -> Bool { label.lowercased().contains("sdh") }
}
