import Foundation

/// Codable mirror of the web app's `playNative` JSON envelope (shared contract with
/// the Android wrapper). Unknown keys are ignored; optionals tolerate older/newer web.
struct PlayNativePayload: Decodable {
    let ref: String
    let url: String?
    let mimeType: String?
    let title: String?
    let artist: String?          // Now Playing secondary line (YouTube channel / author)
    let album: String?           // Now Playing tertiary line (series / show)
    let startMs: Int?
    let poster: String?
    let preferredSubtitleLang: String?
    let preferredAudioLang: String?
    let allowBookmarks: Bool?
    let subs: [SubtitleTrack]?

    // OSD (#466, Android parity). All optional: an older page sends none of them.
    let skin: String?               // "appletv" or anything else (Simple); see OsdTint.forSkin
    let description: String?        // pause info card plot
    let subtitle: String?           // pause info card meta line, "S1 · E5 · 2024 · ★ 8.4"
    let thumb: String?              // pause info card still (absolute URL), else poster
    let video: VideoMeta?           // the page's video descriptor; per-title memory key
    let serverUrl: String?          // the page's API origin

    // SmartTube / YouTube variants
    let playbackKind: String?       // "smarttube"
    let qualityMode: String?        // "ytdlpAdaptive", ...
    let isLive: Bool?
    let videoId: String?
    let videoUrl: String?           // ytdlpAdaptive: separate streams
    let audioUrl: String?
    let videoMimeType: String?
    let audioMimeType: String?
    let durationMs: Int?            // ytdlpAdaptive: for the synthesized MPD
    let qualityOptions: [QualityOption]?   // ytdlpAdaptive: per-height video alternates

    /// One selectable quality: a video-only URL sharing the payload's audio stream.
    struct QualityOption: Decodable {
        let label: String?
        let height: Int?
        let videoUrl: String?
        let videoMimeType: String?
        let isDefault: Bool?
    }

    /// The page sends its whole video meta object here, whose field types vary (season may be a
    /// number or a string, the object may be absent or not an object at all). Decoding it never
    /// throws, so an odd `video` can never cost the whole payload (and with it playback).
    struct VideoMeta: Decodable {
        let imdbId: String?
        let type: String?
        let season: String?
        let episode: String?

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) {
            let c = try? decoder.container(keyedBy: Key.self)
            func str(_ k: String) -> String? {
                guard let c else { return nil }
                if let s = try? c.decode(String.self, forKey: Key(stringValue: k)) { return s }
                if let i = try? c.decode(Int.self, forKey: Key(stringValue: k)) { return String(i) }
                return nil
            }
            imdbId = str("imdbId"); type = str("type"); season = str("season"); episode = str("episode")
        }
    }

    var startSeconds: Double { Double(startMs ?? 0) / 1000.0 }

    /// Separate adaptive video+audio URLs that must be merged at playback time.
    var isAdaptivePair: Bool {
        qualityMode == "ytdlpAdaptive" && videoUrl != nil && audioUrl != nil
    }

    static func decode(_ json: String) -> PlayNativePayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlayNativePayload.self, from: data)
    }
}

/// Payload for the `attachSubtitle` bridge call (a single external track added
/// mid-playback, e.g. an online subtitle the user picked).
struct AttachSubtitlePayload: Decodable {
    let ref: String?
    let url: String?
    let dataBase64: String?
    let mimeType: String?
    let lang: String?
    let label: String?
    let catalogId: String?

    static func decode(_ json: String) -> AttachSubtitlePayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AttachSubtitlePayload.self, from: data)
    }
}

/// One entry of the web's online-subtitle catalog (`setSubtitleCatalog`) — results the
/// user hasn't downloaded yet. Selecting one asks the web (via
/// `dobbyNativeRequestSubtitle`) to fetch it and call `attachSubtitle` back.
struct SubtitleCatalogEntry: Decodable, Identifiable {
    let id: String
    let lang: String?
    let label: String?
    let fileName: String?
    let kind: String?
    /// "a4k" ranks below Stremio within a language (E3, SubtitleOrdering).
    let provider: String?

    var displayName: String { label ?? fileName ?? lang ?? id }
}

struct SubtitleTrack: Decodable {
    let url: String?
    let dataBase64: String?
    let mimeType: String?
    let lang: String?
    let label: String?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case url, dataBase64, mimeType, lang, label
        case isDefault = "default"
    }
}
