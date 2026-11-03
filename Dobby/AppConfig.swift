import Foundation

/// Static app configuration. The web app and this native app are both Dobby.
enum AppConfig {
    /// Web app origin: the Pi's https name, once served over Tailscale.
    /// #491: the Pi's https name is not in this public repo. DOBBY_PI_HOST is expanded at
    /// build time into Info.plist's WKAppBoundDomains (the one place iOS needs it), and the
    /// default address is read back from there. Unset means no default.
    /// #508: the Pi is retired and this is never contacted; it is the origin the bundled shell's
    /// data lives under on a device that stored no other (ServerAddresses.origin()).
    static let serverURL = piURL(Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") as? [String] ?? [])

    static func piURL(_ appBoundDomains: [String]) -> URL? {
        guard let host = appBoundDomains.first?.trimmingCharacters(in: .whitespaces),
              !host.isEmpty else { return nil }
        return URL(string: "https://" + host)
    }

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

    /// #464: the Mac DMG's update settings out of Info.plist (Updater.swift), or nil when the
    /// build carries none: no feed, a non-https feed, no EdDSA public key or no update token.
    /// Only scripts/mac-release.sh builds fill them, so every other build starts no updater.
    /// Here rather than in Updater.swift so Tests/AppConfigCheck.swift runs it without Sparkle.
    static func macUpdateConfig(_ info: [String: Any]) -> (feed: URL, token: String)? {
        let value = { (key: String) in (info[key] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        guard !value("SUPublicEDKey").isEmpty, !value("DobbyUpdateToken").isEmpty,
              let feed = URL(string: value("SUFeedURL")), feed.scheme == "https", feed.host != nil
        else { return nil }
        return (feed, value("DobbyUpdateToken"))
    }
}
