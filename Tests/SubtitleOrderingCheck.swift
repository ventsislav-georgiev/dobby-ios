import Foundation

// #468: SubtitleOrdering.swift, the subtitles sheet's Android order and tab split.
@main
enum SubtitleOrderingCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        check(SubtitleOrdering.preferredLanguages("bg, EN,,bg") == ["bg", "en"],
              "the payload's comma list becomes lowercased codes in order, blanks and repeats dropped")
        check(SubtitleOrdering.preferredLanguages(nil).isEmpty, "no list is no preferred language")
        let priority = SubtitleOrdering.languagePriority("bul, en-US", deviceLanguage: "de")
        check(priority == ["bg", "en", "de"], "priority: preferred (normalized), device language, English once")

        // A mixed list as the sheet builds it: name, language, SDH, source rank.
        let rows: [(String, SubtitleSortKey)] = [
            ("secondary en", SubtitleSortKey(lang: "en", sdh: false, rank: 2)),
            ("online fr", SubtitleSortKey(lang: "fr", sdh: false, rank: 1)),
            ("embedded en", SubtitleSortKey(lang: "en", sdh: false, rank: 0)),
            ("online bg", SubtitleSortKey(lang: "bg", sdh: false, rank: 1)),
            ("embedded none", SubtitleSortKey(lang: nil, sdh: false, rank: 0)),
            ("embedded en sdh", SubtitleSortKey(lang: "en", sdh: true, rank: 0)),
            ("embedded es", SubtitleSortKey(lang: "es", sdh: false, rank: 0)),
            ("embedded bg", SubtitleSortKey(lang: "bg", sdh: false, rank: 0)),
            ("embedded ar", SubtitleSortKey(lang: "ar", sdh: false, rank: 0)),
        ]
        let order = SubtitleOrdering.order(rows.map(\.1), priority: ["bg", "en"]).map { rows[$0].0 }
        check(order == ["embedded bg", "embedded en sdh", "embedded en", "online bg", "secondary en",
                        "embedded ar", "embedded es", "embedded none", "online fr"],
              "Android order: preferred first, embedded < online < secondary, preference order, "
              + "others by name with unknown last, SDH first; got \(order)")

        let tabs = SubtitleOrdering.tabs(priority: ["bg", "en"])
        check(tabs.map(SubtitleOrdering.tabTitle) == ["Bulgarian", "English", "Other"], "tabs: languages then Other")
        check(SubtitleOrdering.inTab(nil, SubtitleOrdering.otherTab, priority: ["bg"])
              && SubtitleOrdering.inTab("fr", SubtitleOrdering.otherTab, priority: ["bg"])
              && !SubtitleOrdering.inTab("bg", SubtitleOrdering.otherTab, priority: ["bg"]),
              "Other holds no-language and non-preferred rows only")
        check(SubtitleOrdering.tabIndex(of: "fr", priority: ["bg", "en"]) == 2
              && SubtitleOrdering.tabIndex(of: "en", priority: ["bg", "en"]) == 1,
              "the sheet opens on the playing subtitle's tab")
        check(SubtitleOrdering.flag("bul") == "🇧🇬", "flag from a three-letter code")
        check(SubtitleOrdering.languageFromLabel("Online - 🇧🇬 Bulgarian · x", priority: ["en", "bg"]) == "bg",
              "a sideloaded label's flag names its language")
        check(SubtitleOrdering.catalogLabel(lang: "en", id: "abc12345", fileName: nil) == "🇬🇧 EN · #2345",
              "unlabelled catalog row: flag, code, id tail")
        print("SubtitleOrderingCheck: all checks passed")
    }
}
