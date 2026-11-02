import Foundation

// E4 (#469): the audio sheet's row label, Android describeAudioFormat: "🇬🇧 EN · DD+ 5.1".
// Pure (Foundation only) so Tests/AudioTrackLabelCheck.swift compiles it standalone.

enum AudioTrackLabel {
    /// `name` is the player's track name; KSPlayer falls back to the language code or the codec
    /// name when the file has no title, and those fallbacks count as no name (Android: the
    /// uppercased language, else "Track N"). `codec` is FFmpeg's codec name or the FourCC.
    static func label(name: String, language: String?, codec: String, codecName: String?,
                      channels: Int, index: Int) -> String {
        let lang = normalizeLanguage(language)
        let title = stripLeadingFlag(name)
        var base: String
        if !title.isEmpty, title != codecName, title != language { base = title }
        else if let lang { base = lang.uppercased() }
        else { base = "Track \(index + 1)" }
        let flag = flag(lang)
        if !flag.isEmpty { base = flag + " " + base }
        let c = codecLabel(codec)
        if !c.isEmpty { base += " · " + c }
        let ch = channelLayout(channels)
        if !ch.isEmpty { base += " " + ch }
        return base
    }

    /// Android audioCodecName, keyed by FFmpeg codec name (before any " (profile)") or FourCC.
    static func codecLabel(_ raw: String) -> String {
        var key = raw.lowercased()
        if let paren = key.range(of: " (") { key = String(key[..<paren.lowerBound]) }
        key = key.trimmingCharacters(in: .whitespaces)
        switch key {
        case "": return ""
        case "ac3", "ac-3": return "AC3"
        case "eac3", "ec-3", "ec+3": return "DD+"
        case "dts", "dtsc", "dtse", "dtsh", "dtsl": return "DTS"
        case "truehd", "mlpa", "mlp": return "TrueHD"
        case "aac", "mp4a": return "AAC"
        case "mp3", ".mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "flac": return "FLAC"
        case "lpcm": return "PCM"
        default: return key.hasPrefix("pcm_") ? "PCM" : key.uppercased()
        }
    }

    /// Android audioChannelLayout.
    static func channelLayout(_ n: Int) -> String {
        switch n {
        case ..<1: return ""
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n)ch"
        }
    }

    /// Android normalizeLangCode: lowercased, region cut, ISO 639-2 to 639-1. "und" is no language.
    static func normalizeLanguage(_ raw: String?) -> String? {
        guard var code = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !code.isEmpty, code != "und"
        else { return nil }
        if let cut = code.firstIndex(where: { $0 == "-" || $0 == "_" }), cut != code.startIndex {
            code = String(code[..<cut])
        }
        return lang3to2[code] ?? code
    }

    /// Android languageFlag: regional-indicator pair for the language's region, "" when unknown.
    static func flag(_ lang: String?) -> String {
        guard let lang, let region = langToRegion[lang] else { return "" }
        return String(String.UnicodeScalarView(region.unicodeScalars.compactMap {
            Unicode.Scalar(0x1F1E6 + $0.value - 0x41)
        }))
    }

    /// Android stripLeadingFlagAndSeparators.
    static func stripLeadingFlag(_ s: String) -> String {
        String(s.unicodeScalars.drop {
            (0x1F1E6...0x1F1FF).contains($0.value) || " ·|:-".unicodeScalars.contains($0)
        })
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
