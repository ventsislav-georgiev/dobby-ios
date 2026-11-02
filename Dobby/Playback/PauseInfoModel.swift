import Foundation

/// E10 (#475): the pure half of the pause info cards (PauseInfoCards.swift draws them), a port
/// of Android's applyMediaInfoContent / refreshMediaInfoPanel (PlaybackActivity :2154-2190).
/// Foundation only, so Tests/run-checks.sh compiles it standalone.
struct PauseInfoModel: Equatable {
    let title: String?
    /// The meta line, "S1 · E5 · 2024 · ★ 8.4" (the payload's `subtitle`).
    let meta: String?
    let plot: String?
    let image: URL?

    init(title: String?, subtitle: String?, description: String?, thumb: String?, poster: String?) {
        func text(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        self.title = text(title)
        self.meta = text(subtitle)
        self.plot = text(description)
        // The still, else the poster; an empty or unusable thumb falls through to the poster.
        self.image = Self.imageURL(thumb) ?? Self.imageURL(poster)
    }

    /// Android shows the cards only with something to read: no title and no plot, no cards.
    var hasText: Bool { title != nil || plot != nil }

    /// Android refreshMediaInfoPanel: paused, the control bar up, no layer over it, not the
    /// SmartTube lane, and something to show. Tied to the bar, so hiding the bar takes them too.
    func shows(paused: Bool, barVisible: Bool, layerOpen: Bool, smartTube: Bool) -> Bool {
        paused && barVisible && !layerOpen && !smartTube && hasText
    }

    /// A fetchable http(s) image URL. Pi-less, the page may hand over its own image proxy,
    /// `dobby-api://proxy?target=image&url=<CDN url>`, which only the WebView's scheme handler
    /// can serve; unwrap it to the CDN URL so URLSession can fetch it directly.
    static func imageURL(_ raw: String?) -> URL? {
        guard let raw, var c = URLComponents(string: raw) else { return nil }
        if c.scheme == "dobby-api", c.host == "proxy" {
            let q = c.queryItems ?? []
            guard q.first(where: { $0.name == "target" })?.value == "image",
                  let inner = q.first(where: { $0.name == "url" })?.value,
                  let ic = URLComponents(string: inner) else { return nil }
            c = ic
        }
        guard let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              c.host?.isEmpty == false else { return nil }
        return c.url
    }
}
