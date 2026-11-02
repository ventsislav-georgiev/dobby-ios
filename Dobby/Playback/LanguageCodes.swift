import Foundation

// #493: the one ISO 639-2 to 639-1 table, normalize and flag, shared by AudioTrackLabel,
// SubtitleOrdering and TrackPreference. Pure (Foundation only); Tests/run-checks.sh compiles it
// with each pure check.
enum LanguageCodes {
    /// Android normalizeLangCode: "en-US" / "pt_BR" / "eng" -> "en" / "pt" / "en". Empty and
    /// "und" are no language.
    static func normalize(_ raw: String?) -> String? {
        var code = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let cut = code.firstIndex(where: { $0 == "-" || $0 == "_" }), cut != code.startIndex {
            code = String(code[..<cut])
        }
        if code.isEmpty || code == "und" { return nil }
        return lang3to2[code] ?? code
    }

    /// Android languageFlag: regional-indicator pair for a two-letter code, "" when unmapped.
    static func flag(_ lang: String?) -> String {
        guard let lang, let region = langToRegion[lang] else { return "" }
        return String(String.UnicodeScalarView(region.unicodeScalars.compactMap {
            Unicode.Scalar(0x1F1E6 + $0.value - 0x41)
        }))
    }

    private static let lang3to2: [String: String] = [
        "eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it",
        "por": "pt", "pob": "pt", "dut": "nl", "nld": "nl", "rus": "ru", "jpn": "ja", "kor": "ko",
        "chi": "zh", "zho": "zh", "ara": "ar", "hin": "hi", "bul": "bg", "hrv": "hr", "alb": "sq",
        "sqi": "sq", "hun": "hu", "cze": "cs", "ces": "cs", "pol": "pl", "swe": "sv", "tur": "tr",
        "ukr": "uk", "rum": "ro", "ron": "ro", "gre": "el", "ell": "el", "heb": "he", "dan": "da",
        "fin": "fi", "nor": "no", "srp": "sr", "scc": "sr", "scr": "hr", "slv": "sl", "slk": "sk",
        "slo": "sk", "mac": "mk", "mkd": "mk", "est": "et", "lav": "lv", "lit": "lt", "ice": "is",
        "isl": "is", "baq": "eu", "eus": "eu", "cat": "ca", "per": "fa", "fas": "fa", "vie": "vi",
        "tha": "th", "ind": "id", "may": "ms", "msa": "ms", "tam": "ta", "tel": "te", "ben": "bn",
        "mar": "mr", "mal": "ml", "kan": "kn", "urd": "ur", "pan": "pa", "guj": "gu", "ori": "or",
        "amh": "am", "swa": "sw", "zul": "zu", "afr": "af", "arm": "hy", "hye": "hy", "aze": "az",
        "geo": "ka", "kat": "ka", "mlt": "mt", "bos": "bs", "wel": "cy", "cym": "cy", "gla": "gd",
        "gle": "ga", "ltz": "lb", "fil": "tl", "tgl": "tl",
        // TrackPreference (#473) also mapped these; kept as the union (#493).
        "bur": "my", "mao": "mi", "tib": "bo",
    ]

    private static let langToRegion: [String: String] = [
        "en": "GB", "es": "ES", "fr": "FR", "de": "DE", "it": "IT", "pt": "PT", "nl": "NL",
        "ru": "RU", "ja": "JP", "ko": "KR", "zh": "CN", "ar": "SA", "hi": "IN", "bg": "BG",
        "sv": "SE", "pl": "PL", "tr": "TR", "vi": "VN", "th": "TH", "cs": "CZ", "da": "DK",
        "fi": "FI", "el": "GR", "he": "IL", "hu": "HU", "id": "ID", "ms": "MY", "no": "NO",
        "uk": "UA", "hr": "HR", "sq": "AL", "ro": "RO", "sr": "RS", "sl": "SI", "sk": "SK",
        "mk": "MK", "et": "EE", "lv": "LV", "lt": "LT", "is": "IS", "eu": "ES", "ca": "ES",
        "fa": "IR", "ta": "IN", "te": "IN", "bn": "BD", "mr": "IN", "ml": "IN", "kn": "IN",
        "ur": "PK", "pa": "IN", "gu": "IN", "or": "IN", "am": "ET", "sw": "TZ", "zu": "ZA",
        "af": "ZA", "hy": "AM", "az": "AZ", "ka": "GE", "mt": "MT", "bs": "BA", "cy": "GB",
        "gd": "GB", "ga": "IE", "lb": "LU", "tl": "PH",
    ]
}
