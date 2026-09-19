import Foundation

/// Static app configuration. The legacy web app is "bookplay"; the native app is Dobby.
enum AppConfig {
    /// Web app origin (served from the Pi over Tailscale, valid TLS via `tailscale serve`).
    static let serverURL = URL(string: "https://dobby.solarflare-tarpon.ts.net")!

    /// Appended to WKWebView's User-Agent so the web app can detect the native wrapper.
    static let userAgentSuffix = "Dobby/0.1"

    /// WKScriptMessageHandler name. Web calls `window.webkit.messageHandlers.dobby.postMessage(...)`.
    static let bridgeName = "dobby"

    /// The scheme the page uses to reach ApiSchemeHandler. WKWebView refuses a
    /// handler for https, so these two API paths are addressed by scheme instead.
    static let apiScheme = "dobby-api"

    /// UA used by the native player's FFmpeg/HTTP layer (direct googlevideo / origin
    /// streams). A real browser UA avoids servers that 403 the default "KSPlayer".
    static let streamUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Debug-only test seam (#116 device round 3): DOBBY_START_PATH=/some/route opens
    /// that route at launch instead of the bare origin, for a headless run that cannot
    /// tap into a series detail page. Path only — no scheme, no host, no leading "//"
    /// (that would let the seam redirect off-origin); the bare `origin` is returned
    /// untouched for anything else. Predicate compiled in every configuration (see
    /// Tests/AppConfigCheck.swift); the call site in WebContainer.makeWebView is
    /// `#if DEBUG` only.
    static func startURL(origin: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let raw = env["DOBBY_START_PATH"],
              raw.hasPrefix("/"), !raw.hasPrefix("//"),
              var components = URLComponents(string: raw),
              components.scheme == nil, components.host == nil
        else { return origin }
        components.scheme = origin.scheme
        components.host = origin.host
        components.port = origin.port
        return components.url ?? origin
    }
}
