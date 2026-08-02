import Foundation

/// Multi-homed address book for the Dobby server.
///
/// The web app owns the canonical list (Settings → Dobby server addresses) and
/// pushes it down through the JS bridge on every load; we cache it so a cold
/// start can find the server on whichever network we woke up on — the LAN IP at
/// home, the Tailscale name everywhere else.
///
/// Probing is sequential in preference order, not a parallel race: the last
/// known-good address goes first, so the common case answers on the first probe
/// and only the launch right after a network change pays for a failed one.
enum ServerAddresses {
    private static let listKey = "dobby.serverAddresses"
    private static let lastGoodKey = "dobby.serverAddresses.lastGood"
    /// Long enough for a sleepy Pi, short enough that a dead LAN address is not a stall.
    private static let probeTimeout: TimeInterval = 1.5

    /// Probe order: last known-good, then the configured list, then the baked default.
    static func candidates() -> [URL] {
        var out: [URL] = []
        append(&out, UserDefaults.standard.string(forKey: lastGoodKey))
        for stored in stored() { append(&out, stored.absoluteString) }
        append(&out, AppConfig.serverURL.absoluteString)
        return out
    }

    /// The configured list alone, in the order the user set — what the editor shows.
    static func stored() -> [URL] {
        var out: [URL] = []
        for raw in UserDefaults.standard.stringArray(forKey: listKey) ?? [] { append(&out, raw) }
        return out
    }

    /// Accepts the JS bridge payload (a JSON string array). Ignores anything unusable.
    static func store(json: String) {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String] else { return }
        var parsed: [URL] = []
        for entry in raw { append(&parsed, entry) }
        guard !parsed.isEmpty else { return } // never let a bad push erase the way back in
        store(parsed)
    }

    static func store(_ addresses: [URL]) {
        UserDefaults.standard.set(addresses.map(\.absoluteString), forKey: listKey)
    }

    /// First candidate that answers `/api/health`, or nil when none do.
    static func resolve() async -> URL? {
        for origin in candidates() {
            guard await reachable(origin) else { continue }
            UserDefaults.standard.set(origin.absoluteString, forKey: lastGoodKey)
            return origin
        }
        return nil
    }

    private static func reachable(_ origin: URL) async -> Bool {
        var request = URLRequest(url: origin.appendingPathComponent("api/health"))
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeout
        config.waitsForConnectivity = false
        guard let (_, response) = try? await URLSession(configuration: config).data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
    }

    /// "192.168.1.31:8080" → "http://192.168.1.31:8080". Nil when unusable.
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
