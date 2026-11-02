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
        LanguageCodes.normalize(raw)
    }

    /// Android languageFlag: regional-indicator pair for the language's region, "" when unknown.
    static func flag(_ lang: String?) -> String {
        LanguageCodes.flag(lang)
    }

    /// Android stripLeadingFlagAndSeparators.
    static func stripLeadingFlag(_ s: String) -> String {
        String(s.unicodeScalars.drop {
            (0x1F1E6...0x1F1FF).contains($0.value) || " ·|:-".unicodeScalars.contains($0)
        })
    }
}
