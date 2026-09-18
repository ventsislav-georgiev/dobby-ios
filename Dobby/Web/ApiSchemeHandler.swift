import Foundation
import Security
import WebKit

/// The two API paths the page cannot get from the Pi when the Pi is off, answered
/// natively over `dobby-api://` (plan §9, option (a)).
///
/// Why a custom scheme rather than the Android trick: `WKURLSchemeHandler` is
/// refused for any scheme WebKit handles itself, `https` included, so there is no
/// iOS equivalent of `shouldInterceptRequest` — the page has to address the
/// wrapper explicitly. It does that only for these two paths (`js/01-state-init.js`,
/// `apiUrlFor`); everything else stays on the Pi origin, so localStorage, IndexedDB
/// and the service worker are untouched. Scheme requests never reach the service
/// worker at all — `fetch` events only fire for http(s) — which is exactly what we
/// want for the credential lane.
///
/// `dobby-api://settings` — mirror-first, the rule Android landed in #044: a
/// mirrored body is answered immediately and the Pi is asked again behind the
/// answer; only an empty mirror waits on the Pi. The mirror is one Keychain item
/// holding the whole `/api/settings` payload, secrets included (owner decision
/// #045), so the credential lane below has a token with the Pi unreachable.
///
/// `dobby-api://proxy?target=…` — the same two legs as `ProxyRoutes.swift` and
/// `ApiInterceptor.java`: allowlisted IMDb artwork with nothing injected, and the
/// credential lane, which is the only thing here that spends a secret and is
/// therefore the narrow one — exactly `graphql.imdb.com`, no wildcards, redirects
/// answered as an error rather than followed with the cookie attached.
final class ApiSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = AppConfig.apiScheme

    /// At most this many upstream requests per image, redirects included.
    private static let maxImageRequests = 3
    private static let imdbGraphQL = "https://graphql.imdb.com/"
    private static let imdbSessionID = "132-4567890-1234567"
    private static let defaultImageCacheControl = "public, max-age=604800, immutable"

    /// The origin the WebView actually loaded — the Tailscale name or the LAN
    /// address, whichever `ServerAddresses.resolve()` picked. Not `AppConfig.serverURL`:
    /// on the home network the page is on plain http and a refresh aimed at the
    /// Tailscale name would be a second, slower link to the same box.
    private let server: URL

    private let queue = DispatchQueue(label: "com.solarflare.dobby.api-scheme", qos: .userInitiated)
    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    /// One refresh in flight at a time; a boot that reads settings twice must not
    /// hit the Pi twice.
    private let refreshing = NSLock()
    private var refreshInFlight = false

    init(server: URL) {
        self.server = server
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); active.insert(id); lock.unlock()

        guard let url = task.request.url else {
            fail(task, id, 400, "Bad dobby-api request"); return
        }
        let method = (task.request.httpMethod ?? "GET").uppercased()
        let origin = task.request.value(forHTTPHeaderField: "Origin")

        queue.async { [weak self] in
            guard let self else { return }
            switch url.host?.lowercased() {
            case "settings": self.serveSettings(task, id, url, method, origin)
            case "proxy": self.serveProxy(task, id, url, method, origin)
            default: self.fail(task, id, 404, "Unknown dobby-api route", origin)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); active.remove(id); lock.unlock()
    }

    // MARK: - dobby-api://settings

    private func serveSettings(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                               _ url: URL, _ method: String, _ origin: String?) {
        guard method == "GET" else {
            fail(task, id, 405, "Settings mirror is GET only", origin); return
        }
        let outcome = Self.settingsOutcome(mirror: SettingsMirrorStore.load()) {
            Self.fetchSettings(from: server)
        }
        if outcome.store { SettingsMirrorStore.save(outcome.body) }
        // no-store: this body carries every secret since #045, so nothing that
        // outlives the request is allowed to hold a copy of it but the Keychain item.
        respond(task, id, status: outcome.status, contentType: "application/json",
                body: outcome.body, origin: origin, extra: ["Cache-Control": "no-store"])
        if outcome.status == 200 && !outcome.store { refreshSettingsInBackground() }
    }

    /// Mirror-first as values, so the rule is checkable without a WebView.
    ///
    /// A mirrored body answers on the spot and `fetch` is never called — the read
    /// the page makes at boot must not hold on a slow-but-reachable Pi (#044). Only
    /// an empty mirror waits, and a cold start with the Pi down has nothing to say.
    static func settingsOutcome(mirror: Data?, fetch: () -> Data?) -> (status: Int, body: Data, store: Bool) {
        if let mirror, !mirror.isEmpty { return (200, mirror, false) }
        if let fresh = fetch(), !fresh.isEmpty { return (200, fresh, true) }
        return (503, Data(#"{"error":"Settings unavailable and nothing mirrored"}"#.utf8), false)
    }

    private func refreshSettingsInBackground() {
        refreshing.lock()
        if refreshInFlight { refreshing.unlock(); return }
        refreshInFlight = true
        refreshing.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            if let fresh = Self.fetchSettings(from: self.server) { SettingsMirrorStore.save(fresh) }
            self.refreshing.lock(); self.refreshInFlight = false; self.refreshing.unlock()
        }
    }

    /// Blocking on purpose: this runs on `queue`, never on the WebView's thread.
    private static func fetchSettings(from server: URL) -> Data? {
        var request = URLRequest(url: server.appendingPathComponent("api/settings"))
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        let (data, http) = Transport.sendSync(request)
        guard let http, (200...299).contains(http.statusCode), let data, !data.isEmpty else { return nil }
        return data
    }

    // MARK: - dobby-api://proxy

    private func serveProxy(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                            _ url: URL, _ method: String, _ origin: String?) {
        let query = Self.query(of: url)
        switch query["target"] {
        case "image": serveImage(task, id, query["url"], method, origin)
        case "imdb-graphql": serveGraphQL(task, id, query["q"], method, origin)
        default: fail(task, id, 400, "Unknown proxy target", origin)
        }
    }

    private func serveImage(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                            _ raw: String?, _ method: String, _ origin: String?) {
        guard method == "GET" else { fail(task, id, 405, "Image proxy is GET only", origin); return }
        guard var current = Self.allowedImageURL(raw) else {
            fail(task, id, 400, "Missing or invalid image url", origin); return
        }

        for _ in 0..<Self.maxImageRequests {
            let (data, http) = Transport.sendSync(Self.imageRequest(current))
            guard let http else { fail(task, id, 502, "Image proxy failed", origin); return }

            if (300...399).contains(http.statusCode) {
                // Re-validated every hop: an allowlisted host may still point
                // somewhere that is not, and the check is worth nothing if it only
                // ever runs on the URL the page supplied.
                guard let next = Self.nextImageHop(from: current,
                                                   location: http.value(forHTTPHeaderField: "Location")) else {
                    fail(task, id, 502, "Image redirect target is not allowlisted", origin); return
                }
                current = next
                continue
            }
            guard let finalURL = http.url, Self.isAllowedImageURL(finalURL) else {
                fail(task, id, 502, "Image response came from a non-allowlisted host", origin); return
            }
            guard (200...299).contains(http.statusCode), let data else {
                fail(task, id, 502, "Image proxy upstream failed", origin); return
            }
            // Content-Type passed through, not inspected: Amazon serves posters as
            // binary/octet-stream often enough that an "image/* only" rule refuses
            // artwork every browser renders. The allowlist is what bounds this lane.
            respond(task, id, status: 200,
                    contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                    body: data, origin: origin,
                    extra: ["Cache-Control": http.value(forHTTPHeaderField: "Cache-Control")
                                ?? Self.defaultImageCacheControl])
            return
        }
        fail(task, id, 502, "Image proxy followed too many redirects", origin)
    }

    private func serveGraphQL(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                              _ document: String?, _ method: String, _ origin: String?) {
        let noStore = ["Cache-Control": "no-store"]
        guard method == "GET" else {
            fail(task, id, 405, "Credential lane is GET only", origin, noStore); return
        }
        guard let document, !document.isEmpty else {
            fail(task, id, 400, "Missing graphql document", origin, noStore); return
        }
        guard let token = SettingsMirrorStore.imdbAuthToken() else {
            fail(task, id, 401, "IMDb auth token not configured", origin, noStore); return
        }
        let upstream = Self.credentialRequest(document: document, token: token)
        guard let url = upstream.url, Self.isAllowedCredentialURL(url) else {
            fail(task, id, 502, "Credential lane upstream is not allowlisted", origin, noStore); return
        }

        let (data, http) = Transport.sendSync(upstream)
        guard let http else { fail(task, id, 502, "IMDb proxy failed", origin, noStore); return }
        if (300...399).contains(http.statusCode) {
            fail(task, id, 502, "IMDb redirected; refusing to carry the credential", origin, noStore); return
        }
        guard let finalURL = http.url, Self.isAllowedCredentialURL(finalURL) else {
            fail(task, id, 502, "IMDb response came from a non-allowlisted host", origin, noStore); return
        }
        // Upstream failures collapse to 502 the way the Pi reports them: copying
        // IMDb's 401 through would make the page read "no token configured" for an
        // expired one and blame the settings.
        guard (200...299).contains(http.statusCode), let data else {
            fail(task, id, 502, "IMDb proxy upstream failed", origin, noStore); return
        }
        // Only Content-Type is answered, so an upstream Set-Cookie cannot reach the page.
        respond(task, id, status: 200, contentType: "application/json", body: data,
                origin: origin, extra: noStore)
    }

    // MARK: - The rules, as pure functions (see Tests/ApiSchemeHandlerCheck.swift)

    /// Keeps the Swift `isAllowedImageURL` rule verbatim: https, no port,
    /// leading-dot suffixes, so `media-amazon.com.attacker.tld` cannot match.
    static func isAllowedImageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "m.media-amazon.com" || host.hasSuffix(".media-amazon.com")
            || host == "m.media-amazon.co.uk" || host.hasSuffix(".media-amazon.co.uk")
    }

    /// One parser, one decision: either the URL to fetch or nil. Deciding with one
    /// parser and fetching with another is how an allowlist gets walked past.
    static func allowedImageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw), isAllowedImageURL(url) else { return nil }
        return url
    }

    static func nextImageHop(from current: URL, location: String?) -> URL? {
        guard let location, !location.isEmpty,
              let next = URL(string: location, relativeTo: current)?.absoluteURL,
              isAllowedImageURL(next) else { return nil }
        return next
    }

    static func isAllowedCredentialURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "graphql.imdb.com" && url.port == nil
    }

    /// The only request that carries the IMDb cookie, and it is built against a
    /// fixed URL — nothing the page sends picks the host or the headers.
    static func credentialRequest(document: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: imdbGraphQL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("at-main=\(token); ubid-main=\(imdbSessionID)", forHTTPHeaderField: "Cookie")
        request.setValue(imdbSessionID, forHTTPHeaderField: "x-amzn-sessionid")
        // IMDb's edge (CloudFront/WAF) 403s anything without a client-name header.
        request.setValue("imdb-web-next", forHTTPHeaderField: "x-imdb-client-name")
        request.httpBody = Data(document.utf8)
        return request
    }

    /// The public lane: no credential, no page-supplied header.
    static func imageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        return request
    }

    static func query(of url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if out[item.name] == nil { out[item.name] = item.value }
        }
        return out
    }

    // MARK: - Answering the task

    /// `Access-Control-Allow-Origin` echoes the page's own `Origin` because the
    /// page is on https (or LAN http) and the response is on `dobby-api:` — a
    /// cross-origin fetch as far as WebKit is concerned, refused without it. The
    /// echo rather than a constant: the WebView loads whichever address answered
    /// (`ServerAddresses.resolve()`), so there is no single origin to hard-code.
    /// Only this app's own WebView can reach the scheme at all.
    private func headers(_ contentType: String, _ length: Int, _ origin: String?,
                         _ extra: [String: String]) -> [String: String] {
        var out = [
            "Content-Type": contentType,
            "Content-Length": "\(length)",
            "Access-Control-Allow-Origin": origin ?? "*",
        ]
        for (key, value) in extra { out[key] = value }
        return out
    }

    private func respond(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, status: Int,
                         contentType: String, body: Data, origin: String?,
                         extra: [String: String] = [:]) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: headers(contentType, body.count, origin, extra)) else {
            finish(task, id); return
        }
        guard send(task, id, { $0.didReceive(response) }) else { return }

        var offset = 0
        let chunkSize = 256 * 1024
        while offset < body.count {
            let end = min(offset + chunkSize, body.count)
            let chunk = body.subdata(in: offset..<end)
            guard send(task, id, { $0.didReceive(chunk) }) else { return }
            offset = end
        }
        finish(task, id)
    }

    private func fail(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ status: Int,
                      _ message: String, _ origin: String? = nil, _ extra: [String: String] = [:]) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        respond(task, id, status: status, contentType: "application/json",
                body: Data("{\"error\":\"\(escaped)\"}".utf8), origin: origin, extra: extra)
    }

    private func isActive(_ id: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active.contains(id)
    }

    private func send(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                      _ body: (WKURLSchemeTask) -> Void) -> Bool {
        guard isActive(id) else { return false }
        body(task)
        return true
    }

    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier) {
        guard isActive(id) else { return }
        task.didFinish()
        lock.lock(); active.remove(id); lock.unlock()
    }
}

// MARK: - Transport

/// One hop, redirects refused and cookies off, so the IMDb cookie can never be
/// replayed onto a `Location` and no upstream `Set-Cookie` is kept. Callers decide
/// what a 3xx means — the image lane re-validates and follows, the credential lane
/// gives up.
enum Transport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    /// Blocking. Every caller already runs on the handler's own queue, and a
    /// semaphore here is a great deal less code than threading async/await through
    /// a delegate-based scheme handler for three call sites.
    /// ponytail: semaphore hop, swap for async/await if this ever runs on an actor.
    static func sendSync(_ request: URLRequest) -> (Data?, HTTPURLResponse?) {
        let semaphore = DispatchSemaphore(value: 0)
        var out: (Data?, HTTPURLResponse?) = (nil, nil)
        session.dataTask(with: request) { data, response, _ in
            out = (data, response as? HTTPURLResponse)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return out
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

// MARK: - The mirror

/// The last body the Pi gave for `GET /api/settings`, in one Keychain item.
///
/// The Keychain rather than `UserDefaults` because since #045 that payload carries
/// every secret — `imdbAuthToken` and `premiumizeApiKey` included — and secrets may
/// persist on clients but not in a plist an iTunes backup hands over in the clear.
/// `AfterFirstUnlock` so a launch into a locked phone (background audio, a Live
/// Activity tap) can still read it.
///
/// Stored as the raw body, as Android does: the page reads it back verbatim, and
/// parsing it here would invent a second schema to keep in step with the Swift one.
enum SettingsMirrorStore {
    private static let service = "eu.illegible.dobbyios.api-mirror"
    private static let account = "api/settings"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func save(_ body: Data) {
        guard !body.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: body,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecSuccess { return }
        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        SecItemDelete(baseQuery as CFDictionary)
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func imdbAuthToken() -> String? {
        imdbAuthToken(from: load())
    }

    /// The JSON-null trap Android hit: since #045 the Pi sends the key with a
    /// literal `null` when it is cleared, which decodes to `NSNull` — `as? String`
    /// is what makes that read as "no token" rather than the string "<null>".
    static func imdbAuthToken(from json: Data?) -> String? {
        guard let json, !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let token = object["imdbAuthToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
