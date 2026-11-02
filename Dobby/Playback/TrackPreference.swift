import Foundation

// E8 (#473): the initial audio and subtitle pick from the payload's preferredAudioLang /
// preferredSubtitleLang (Android languagePriority :7470-7489, selectDefaultSubtitleIfNeeded
// :7323-7383). Foundation only, so Tests/run-checks.sh compiles it standalone with
// Tests/TrackPreferenceCheck.swift.
enum TrackPreference {
    /// Track tag to a two-letter code: "en-US" / "eng" / "ger" -> "en" / "en" / "de".
    /// nil for empty and "und". Matroska tags are ISO 639-2/B, which Foundation does not map.
    static func normalize(_ raw: String?) -> String? {
        let code = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if code.isEmpty || code == "und" { return nil }
        let t = bibliographic[code] ?? code
        return Locale.Language(identifier: t).languageCode?.identifier(.alpha2) ?? t
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

    private static let bibliographic = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces",
        "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
        "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "rum": "ron", "slo": "slk",
        "tib": "bod", "wel": "cym",
    ]
}
