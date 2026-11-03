import Foundation

/// #508: the Pi is retired and no build contacts it. What is left of the old address book is the
/// ORIGIN the bundled shell is loaded under (WebContainer, `loadSimulatedRequest`): the page's
/// localStorage, IndexedDB and service worker caches are keyed by it, so it must stay the one this
/// device has always come up on. It is read from what earlier builds stored, in their order (the last
/// address that answered, the list the web app pushed, the build's own name), and nothing writes those
/// keys any more, so it can no longer move. Never fetched: PiRequestBlock refuses it to WebKit and
/// `isPiOrigin` to the native downloads.
enum ServerAddresses {
    private static let listKey = "dobby.serverAddresses"
    private static let lastGoodKey = "dobby.serverAddresses.lastGood"
    /// #245: which addresses this platform can use. On iOS WebKit enforces WKAppBoundDomains
    /// (Info.plist): on any other origin it ignores the injected bridge, refuses message handler
    /// posts and never commits the Pi-less shell, so an address off that list is a blank or
    /// bridge-less app. iOS therefore keeps only https on an app-bound host (http to that name
    /// is refused by App Transport Security anyway). Loopback is exempt from the WebKit rule but
    /// no Pi lives on a phone's loopback, so it is kept on the simulator only, where a dev
    /// server on the Mac does. macOS does not enforce the list and keeps every address, as
    /// Android does for the same shared list.
    struct AppBound {
        let enforced: Bool
        let loopback: Bool
        let domains: [String]

        #if os(iOS)
        static let enforcedHere = true
        #else
        static let enforcedHere = false
        #endif
        #if targetEnvironment(simulator)
        static let loopbackHere = true
        #else
        static let loopbackHere = false
        #endif
        static let current = AppBound(enforced: enforcedHere, loopback: loopbackHere,
                                      domains: Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") as? [String] ?? [])
        /// Every address, on every platform: for questions of identity (is this host the Pi),
        /// not of which address this device can load.
        static let keepAll = AppBound(enforced: false, loopback: false, domains: [])

        /// True when `url`'s host is covered by `domains` (the entry matches the host or a
        /// suffix of it). LAN IPs never are: WKAppBoundDomains only takes domains.
        func covers(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return domains.contains { domain in
                let d = domain.lowercased()
                return host == d || host.hasSuffix("." + d)
            }
        }

        func keeps(_ url: URL) -> Bool {
            guard enforced else { return true }
            // ponytail: the three spellings a dev server is typed as; any other 127/8 host is dropped.
            if loopback, ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "") { return true }
            return url.scheme == "https" && covers(url)
        }
    }

    /// #508: the origin the bundled shell comes up on. The first candidate, the same pick every
    /// earlier build made for its Pi-less start (`continueOffline`), over keys nothing writes now.
    static func origin(_ defaults: UserDefaults = .standard, rule: AppBound = .current) -> URL? {
        candidates(defaults, rule: rule).first
    }

    /// Origin order: last known-good, then the configured list, then the baked default.
    /// #245: on iOS an entry the platform cannot use is skipped here, not cleared: a last
    /// known-good stored before the guard stays on disk (the bundled shell's origin when it is
    /// app-bound), it just is never picked on an origin WebKit would cripple.
    static func candidates(_ defaults: UserDefaults = .standard, rule: AppBound = .current) -> [URL] {
        var out: [URL] = []
        append(&out, defaults.string(forKey: lastGoodKey))
        for stored in stored(defaults) { append(&out, stored.absoluteString) }
        append(&out, AppConfig.serverURL?.absoluteString)
        return out.filter(rule.keeps)
    }

    /// The configured list alone, in the order the user set, unfiltered (#245: on iOS the
    /// entries that are not app-bound are kept here and skipped by `candidates()`).
    static func stored(_ defaults: UserDefaults = .standard) -> [URL] {
        var out: [URL] = []
        for raw in defaults.stringArray(forKey: listKey) ?? [] { append(&out, raw) }
        return out
    }

    /// #217: whether a URL the app would fetch natively points at the Pi. Its host, compared
    /// case-insensitively with the host of every candidate (last known-good, the configured
    /// list, the baked default): any scheme and any port, the rule PiRequestBlock applies to
    /// WebKit's loads. A URL with no host is page-relative, and the page always sits on a
    /// candidate, so it is the Pi. No parseable URL is nothing to fetch.
    /// #245: identity, not usability, so the candidates are unfiltered (`.keepAll`): on iOS a
    /// stored LAN address of the Pi is not loadable but is still the Pi, and the Pi-off
    /// download refusal must keep refusing it.
    static func isPiOrigin(_ raw: String?, candidates: [URL] = candidates(rule: .keepAll)) -> Bool {
        guard let raw, let url = URL(string: raw) else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return true }
        return candidates.contains { $0.host?.lowercased() == host }
    }

    /// "192.0.2.31:8080" → "http://192.0.2.31:8080". Nil when unusable.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text } // bare host = a LAN box
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func append(_ out: inout [URL], _ raw: String?) {
        guard let raw, let url = normalize(raw), !out.contains(url) else { return }
        out.append(url)
    }
}
