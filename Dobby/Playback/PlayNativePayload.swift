import Foundation

/// Codable mirror of the web app's `playNative` JSON envelope (shared contract with
/// the Android wrapper). Unknown keys are ignored; optionals tolerate older/newer web.
struct PlayNativePayload: Decodable {
    let ref: String
    let url: String?
    let mimeType: String?
    let title: String?
    let startMs: Int?
    let poster: String?
    let preferredSubtitleLang: String?
    let preferredAudioLang: String?
    let allowBookmarks: Bool?
    let subs: [SubtitleTrack]?

    // SmartTube / YouTube variants
    let playbackKind: String?       // "smarttube"
    let qualityMode: String?        // "ytdlpAdaptive", ...
    let isLive: Bool?
    let videoId: String?
    let videoUrl: String?           // ytdlpAdaptive: separate streams
    let audioUrl: String?
    let videoMimeType: String?
    let audioMimeType: String?

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

    static func decode(_ json: String) -> AttachSubtitlePayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AttachSubtitlePayload.self, from: data)
    }
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
