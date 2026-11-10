import Foundation

// E8 (#473): the initial audio and subtitle pick from the payload's preferredAudioLang /
// preferredSubtitleLang (Android languagePriority :7470-7489, selectDefaultSubtitleIfNeeded
// :7323-7383). Foundation only, so Tests/run-checks.sh compiles it standalone with
// Tests/TrackPreferenceCheck.swift.
enum TrackPreference {
    /// Track tag to a two-letter code: "en-US" / "eng" / "ger" -> "en" / "en" / "de".
    /// nil for empty and "und". The shared table maps ISO 639-2/B (Matroska), Foundation the rest.
    static func normalize(_ raw: String?) -> String? {
        guard let code = LanguageCodes.normalize(raw) else { return nil }
        return Locale.Language(identifier: code).languageCode?.identifier(.alpha2) ?? code
    }

    /// Android languagePriority: the comma list in order, then the device language, then "en".
    static func priority(_ csv: String?, deviceLanguage: String?) -> [String] {
        var out: [String] = []
        for raw in (csv ?? "").split(separator: ",").map(String.init) + [deviceLanguage ?? "", "en"] {
            if let code = normalize(raw), !out.contains(code) { out.append(code) }
        }
        return out
    }

    /// Index of the track to start on: the first track in the earliest priority language,
    /// nil when no track matches (leave the player's own pick alone).
    static func pick(_ trackLangs: [String?], priority: [String]) -> Int? {
        let langs = trackLangs.map(normalize)
        for want in priority {
            if let i = langs.firstIndex(of: want) { return i }
        }
        return nil
    }

    /// #586: the subtitle auto-pick under the page's subtitle mode. on is pick() unchanged; forced
    /// considers only tracks marked forced, in the same priority; off never auto-picks (a hand
    /// pick in SubtitleSheet still works and leaves the mode alone).
    static func pickSubtitle(_ trackLangs: [String?], forced: [Bool], priority: [String], mode: SubtitleMode) -> Int? {
        switch mode {
        case .on: return pick(trackLangs, priority: priority)
        case .off: return nil
        case .forced:
            return pick(trackLangs.indices.map { forced.indices.contains($0) && forced[$0] ? trackLangs[$0] : nil },
                        priority: priority)
        }
    }

    /// A forced marking in a track's title or label ("English (Forced)", "eng.forced").
    static func isForcedLabel(_ name: String?) -> Bool {
        name?.range(of: #"(?<![a-z])forced(?![a-z])"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// #586: the play payload's subtitleMode. Missing or unknown reads on (owner ruling, OQ-76).
enum SubtitleMode: String {
    case on, forced, off

    init(_ raw: String?) { self = raw.flatMap(SubtitleMode.init(rawValue:)) ?? .on }
}
