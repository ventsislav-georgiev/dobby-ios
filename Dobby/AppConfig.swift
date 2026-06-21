import Foundation

/// Static app configuration. The legacy web app is "bookplay"; the native app is Dobby.
enum AppConfig {
    /// Web app origin (served from the Pi over Tailscale, valid TLS via `tailscale serve`).
    static let serverURL = URL(string: "https://dobby.solarflare-tarpon.ts.net")!

    /// Appended to WKWebView's User-Agent so the web app can detect the native wrapper.
    static let userAgentSuffix = "Dobby/0.1"

    /// WKScriptMessageHandler name. Web calls `window.webkit.messageHandlers.dobby.postMessage(...)`.
    static let bridgeName = "dobby"

    /// UA used by the native player's FFmpeg/HTTP layer (direct googlevideo / origin
    /// streams). A real browser UA avoids servers that 403 the default "KSPlayer".
    static let streamUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}
