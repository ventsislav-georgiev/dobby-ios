import Foundation
import Security
import WebKit
import os

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
    static let defaultImageCacheControl = "public, max-age=604800, immutable"
    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "api-scheme")

    /// The origin the WebView actually loaded — the Tailscale name or the LAN
    /// address, whichever `ServerAddresses.resolve()` picked. Not `AppConfig.serverURL`:
    /// on the home network the page is on plain http and a refresh aimed at the
    /// Tailscale name would be a second, slower link to the same box.
    private let server: URL

    /// `server` as an `Origin` header spells it. The only value the secret-carrying
    /// lanes will ever answer `Access-Control-Allow-Origin` with.
    private let serverOrigin: String?

    private let queue = DispatchQueue(label: "com.solarflare.dobby.api-scheme", qos: .userInitiated)
    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    /// One refresh in flight at a time; a boot that reads settings twice must not
    /// hit the Pi twice.
    private let refreshing = NSLock()
    private var refreshInFlight = false

    init(server: URL) {
        self.server = server
        self.serverOrigin = Self.normalizedOrigin(server.absoluteString)
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
            fail(task, id, 405, "Settings mirror is GET only", origin, secret: true); return
        }
        let outcome = Self.settingsOutcome(mirror: SettingsMirrorStore.load()) {
            Self.fetchSettings(from: server)
        }
        if outcome.store { SettingsMirrorStore.save(outcome.body) }
        // no-store: this body carries every secret since #045, so nothing that
        // outlives the request is allowed to hold a copy of it but the Keychain item.
        respond(task, id, status: outcome.status, contentType: "application/json",
                body: outcome.body, origin: origin, secret: true,
                extra: ["Cache-Control": "no-store"])
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

    /// #071: the image lane is the only one with a disk cache — a poster is
    /// public artwork, nothing injected, exactly what belongs in a plaintext
    /// `Caches/` directory, unlike the settings/credential bodies above. Cache
    /// checked directly against `ImageTransport.cache` before any request (the
    /// "or ask `urlCache.cachedResponse(for:)`" option), so a disk hit never
    /// reaches `ImageTransport.stream` at all — no transport call, no log-line
    /// "upstream" for what is actually free.
    private func serveImage(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                            _ raw: String?, _ method: String, _ origin: String?) {
        guard method == "GET" else { fail(task, id, 405, "Image proxy is GET only", origin); return }
        guard var current = Self.allowedImageURL(raw) else {
            fail(task, id, 400, "Missing or invalid image url", origin); return
        }

        for _ in 0..<Self.maxImageRequests {
            let request = Self.imageRequest(current)
            let startedAt = DispatchTime.now()

            if let hit = Self.cachedImageAnswer(ImageTransport.cache, request) {
                let contentType = hit.response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                logImage(path: current.path, status: 200, contentType: contentType,
                         length: "\(hit.data.count)", startedAt: startedAt, diskHit: true)
                // Content-Type passed through, not inspected: Amazon serves posters as
                // binary/octet-stream often enough that an "image/* only" rule refuses
                // artwork every browser renders. The allowlist is what bounds this lane.
                respond(task, id, status: 200, contentType: contentType, body: hit.data, origin: origin,
                        extra: ["Cache-Control": hit.response.value(forHTTPHeaderField: "Cache-Control")
                                    ?? Self.defaultImageCacheControl])
                return
            }

            switch streamImageHop(task, id, request, origin, path: current.path, startedAt: startedAt) {
            case .served:
                return
            case .redirect(let location):
                // Re-validated every hop: an allowlisted host may still point
                // somewhere that is not, and the check is worth nothing if it only
                // ever runs on the URL the page supplied.
                guard let next = Self.nextImageHop(from: current, location: location) else {
                    fail(task, id, 502, "Image redirect target is not allowlisted", origin); return
                }
                current = next
            case .failed(let status, let message):
                fail(task, id, status, message, origin); return
            }
        }
        fail(task, id, 502, "Image proxy followed too many redirects", origin)
    }

    private enum ImageHopOutcome {
        case served
        case redirect(String?)
        case failed(Int, String)
    }

    /// One upstream hop, delivered to `task` as bytes arrive (`ImageStreamSink`
    /// forwards straight from `StreamDelegate.urlSession(_:dataTask:didReceive:)`)
    /// rather than the old buffer-then-256KB-chunk `respond(...)` did against a
    /// `Transport.sendSync` result that was already fully downloaded before any
    /// chunk left this process.
    private func streamImageHop(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ request: URLRequest,
                                _ origin: String?, path: String, startedAt: DispatchTime) -> ImageHopOutcome {
        let sink = ImageStreamSink(handler: self, task: task, id: id, origin: origin,
                                   path: path, startedAt: startedAt)
        ImageTransport.stream(request, sink: sink)
        return sink.outcome
    }

    /// Bridges one streamed hop to the `WKURLSchemeTask`. Nested so it can call
    /// the handler's private `respond`/`send`/`finish` machinery directly — see
    /// `streamImageHop` for why this replaces the old buffered `respond(...)`
    /// call for the network path (the disk-cache hit above still uses it, since
    /// that body is already fully in memory and chunking it further buys nothing).
    private final class ImageStreamSink: ImageSink {
        // weak, not unowned: StreamDelegate holds this sink independently of
        // the handler's own lifetime, so a WebView torn down mid-stream can
        // deallocate the handler while a callback from the URLSession
        // delegate queue is still pending — `unowned` would trap on that
        // dereference instead of harmlessly no-oping.
        private weak var handler: ApiSchemeHandler?
        private let task: WKURLSchemeTask
        private let id: ObjectIdentifier
        private let origin: String?
        private let path: String
        private let startedAt: DispatchTime
        private(set) var outcome: ImageHopOutcome = .failed(502, "Image proxy failed")

        init(handler: ApiSchemeHandler, task: WKURLSchemeTask, id: ObjectIdentifier, origin: String?,
             path: String, startedAt: DispatchTime) {
            self.handler = handler; self.task = task; self.id = id
            self.origin = origin; self.path = path; self.startedAt = startedAt
        }

        func respond(_ response: HTTPURLResponse) -> Bool {
            if (300...399).contains(response.statusCode) {
                // Redirects are refused by StreamDelegate, so this IS the final
                // response for this hop; its body (if any) is drained and
                // discarded in receive(), never forwarded to the task.
                outcome = .redirect(response.value(forHTTPHeaderField: "Location"))
                return true
            }
            guard let finalURL = response.url, ApiSchemeHandler.isAllowedImageURL(finalURL) else {
                outcome = .failed(502, "Image response came from a non-allowlisted host")
                return false
            }
            guard (200...299).contains(response.statusCode) else {
                outcome = .failed(502, "Image proxy upstream failed")
                return false
            }
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            // expectedContentLength mirrors the upstream Content-Length, which
            // for a Content-Encoding response is the *encoded* size — but
            // URLSession hands this delegate the already-decoded bytes, so
            // forwarding that number would tell WKURLSchemeTask to expect a
            // byte count nothing here ever produces, and WebKit fails the
            // load. Omit the header rather than guess the decoded size.
            let length = response.value(forHTTPHeaderField: "Content-Encoding") == nil
                && response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil
            let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") ?? ApiSchemeHandler.defaultImageCacheControl
            guard let handler else {
                outcome = .failed(502, "Image proxy failed")
                return false
            }
            handler.logImage(path: path, status: 200, contentType: contentType,
                             length: length.map { "\($0)" } ?? "?", startedAt: startedAt, diskHit: false)
            guard handler.beginImageStream(task, id, contentType: contentType, contentLength: length,
                                           origin: origin, cacheControl: cacheControl) else {
                outcome = .failed(502, "Image proxy failed")
                return false
            }
            outcome = .served
            return true
        }

        func receive(_ data: Data) {
            guard case .served = outcome, let handler else { return } // a redirect's body, not the image
            _ = handler.send(task, id) { $0.didReceive(data) }
        }

        func complete(error: Error?) {
            guard case .served = outcome, let handler else { return } // redirect/failure: streamImageHop's caller decides
            if let error {
                handler.failMidStream(task, id, error)
            } else {
                handler.finish(task, id)
            }
        }
    }

    private func logImage(path: String, status: Int, contentType: String, length: String,
                          startedAt: DispatchTime, diskHit: Bool) {
        let ms = (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        Self.log.info("answered \(path, privacy: .public) image \(status) \(contentType, privacy: .public) \(length, privacy: .public)B head \(ms)ms \(diskHit ? "disk-hit" : "upstream", privacy: .public)")
    }

    private func beginImageStream(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, contentType: String,
                                  contentLength: Int?, origin: String?, cacheControl: String) -> Bool {
        guard let url = task.request.url else { return false }
        var headerFields = ["Content-Type": contentType, "Cache-Control": cacheControl]
        if let contentLength { headerFields["Content-Length"] = "\(contentLength)" }
        if let acao = Self.acao(origin: origin, serverOrigin: serverOrigin, secret: false) {
            headerFields["Access-Control-Allow-Origin"] = acao
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: headerFields) else { return false }
        return send(task, id) { $0.didReceive(response) }
    }

    private func serveGraphQL(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                              _ document: String?, _ method: String, _ origin: String?) {
        let noStore = ["Cache-Control": "no-store"]
        guard method == "GET" else {
            fail(task, id, 405, "Credential lane is GET only", origin, noStore, secret: true); return
        }
        guard let document, !document.isEmpty else {
            fail(task, id, 400, "Missing graphql document", origin, noStore, secret: true); return
        }
        guard let token = SettingsMirrorStore.imdbAuthToken() else {
            fail(task, id, 401, "IMDb auth token not configured", origin, noStore, secret: true); return
        }
        let upstream = Self.credentialRequest(document: document, token: token)
        guard let url = upstream.url, Self.isAllowedCredentialURL(url) else {
            fail(task, id, 502, "Credential lane upstream is not allowlisted", origin, noStore, secret: true); return
        }

        let (data, http) = Transport.sendSync(upstream)
        guard let http else { fail(task, id, 502, "IMDb proxy failed", origin, noStore, secret: true); return }
        if (300...399).contains(http.statusCode) {
            fail(task, id, 502, "IMDb redirected; refusing to carry the credential", origin, noStore, secret: true); return
        }
        guard let finalURL = http.url, Self.isAllowedCredentialURL(finalURL) else {
            fail(task, id, 502, "IMDb response came from a non-allowlisted host", origin, noStore, secret: true); return
        }
        // Upstream failures collapse to 502 the way the Pi reports them: copying
        // IMDb's 401 through would make the page read "no token configured" for an
        // expired one and blame the settings.
        guard (200...299).contains(http.statusCode), let data else {
            fail(task, id, 502, "IMDb proxy upstream failed", origin, noStore, secret: true); return
        }
        // Only Content-Type is answered, so an upstream Set-Cookie cannot reach the page.
        respond(task, id, status: 200, contentType: "application/json", body: data,
                origin: origin, secret: true, extra: noStore)
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

    struct CachedImageAnswer {
        let data: Data
        let response: HTTPURLResponse
    }

    /// Cache-first, checked as a value: a real (temp-directory) `URLCache` in
    /// `Tests/ApiSchemeHandlerCheck.swift` proves a populated cache answers
    /// here with no upstream call, the #071 unit check, without a socket in
    /// the loop.
    ///
    /// A non-2xx entry is never served as a hit even if something once stored
    /// one (belt-and-braces alongside `ImageTransport.cachePolicy`, which is
    /// what should stop it from ever being stored) — `serveImage` always
    /// answers a hit as 200, so a cached 404 must not become one.
    ///
    /// ponytail: no max-age/freshness check on this path — a poster is
    /// immutable at its URL (Amazon's own contract, not just our default), so
    /// "present" is treated as "fresh" for as long as `URLCache`'s own LRU
    /// keeps it. Upgrade path if that assumption ever breaks: compare the
    /// stored response's `Date` header plus its `Cache-Control: max-age`
    /// against now, same as a real HTTP cache would.
    static func cachedImageAnswer(_ cache: URLCache, _ request: URLRequest) -> CachedImageAnswer? {
        guard let cached = cache.cachedResponse(for: request),
              let http = cached.response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return CachedImageAnswer(data: cached.data, response: http)
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

    /// `Access-Control-Allow-Origin` is needed at all because the page is on https
    /// (or LAN http) and the response is on `dobby-api:` — a cross-origin fetch as
    /// far as WebKit is concerned, refused without it.
    ///
    /// The boundary is the WebView, NOT the page. The handler is registered on the
    /// `WKWebViewConfiguration`, so every document that WebView loads can issue
    /// `dobby-api:` requests — an iframe, an ad, any page it navigated to — and
    /// navigation is not restricted (`limitsNavigationsToAppBoundDomains` is false
    /// on the LAN path). So echoing the caller's `Origin`, or falling back to `*`,
    /// would hand the settings body — `imdbAuthToken` and the rest of #045 — to
    /// whichever document asked for it.
    ///
    /// Hence two lanes. The settings and credential lanes answer the header only
    /// when the caller IS the origin the WebView was pointed at, compared as
    /// normalised `scheme://host[:port]`, and answer no ACAO at all otherwise —
    /// no `*`, no echo. The image lane carries no secret (allowlisted artwork,
    /// nothing injected), so it keeps the permissive header and images still load
    /// for a page on whichever address `ServerAddresses.resolve()` picked.
    static func acao(origin: String?, serverOrigin: String?, secret: Bool) -> String? {
        guard secret else { return origin ?? "*" }
        guard let serverOrigin, let origin = normalizedOrigin(origin),
              origin == serverOrigin else { return nil }
        return serverOrigin
    }

    /// `scheme://host[:port]`, lowercased, default ports dropped — the shape a
    /// browser puts in `Origin`. Both sides of the compare go through this one
    /// parser, so a spelled-out `:443` on either side cannot make two spellings of
    /// the same origin read as different origins. Anything unparseable (`null`,
    /// an opaque origin, empty) is nil and therefore never matches.
    static func normalizedOrigin(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if let port = url.port, port != defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    private func headers(_ contentType: String, _ length: Int, _ origin: String?,
                         _ secret: Bool, _ extra: [String: String]) -> [String: String] {
        var out = [
            "Content-Type": contentType,
            "Content-Length": "\(length)",
        ]
        if let value = Self.acao(origin: origin, serverOrigin: serverOrigin, secret: secret) {
            out["Access-Control-Allow-Origin"] = value
        }
        for (key, value) in extra { out[key] = value }
        return out
    }

    private func respond(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, status: Int,
                         contentType: String, body: Data, origin: String?,
                         secret: Bool = false, extra: [String: String] = [:]) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: headers(contentType, body.count, origin,
                                                                   secret, extra)) else {
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
                      _ message: String, _ origin: String? = nil, _ extra: [String: String] = [:],
                      secret: Bool = false) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        respond(task, id, status: status, contentType: "application/json",
                body: Data("{\"error\":\"\(escaped)\"}".utf8), origin: origin,
                secret: secret, extra: extra)
    }

    private func isActive(_ id: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active.contains(id)
    }

    /// The check-then-call is atomic with `lock` held across `body(task)`, not
    /// just across the check: `webView(_:stop:)` also takes `lock` to remove
    /// `id`, so a `stop` racing a WebKit call on this task now either happens
    /// fully before or fully after it, never in between. Before #071 the two
    /// were separate critical sections, which was already a live crash window
    /// (a `stop` landing between the check and the call raises
    /// `NSInternalInconsistencyException` on a torn-down `WKURLSchemeTask`,
    /// uncatchable in Swift) — #071's streamed delivery calls this once per
    /// network chunk from the `URLSession` delegate queue, running
    /// concurrently with the handler's own serial queue, which turned an
    /// occasional window into one per chunk. `didReceive`/`didFinish`/
    /// `didFailWithError` are all fast, non-reentrant WebKit calls, so holding
    /// `lock` across them is cheap and never risks a deadlock back into this
    /// class.
    private func send(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                      _ body: (WKURLSchemeTask) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active.contains(id) else { return false }
        body(task)
        return true
    }

    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        guard active.contains(id) else { return }
        task.didFinish()
        active.remove(id)
    }

    private func failMidStream(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard active.contains(id) else { return }
        task.didFailWithError(error)
        active.remove(id)
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

    /// #071's "the credential lane never touches the image session" check: the
    /// two lanes' sessions differ in exactly this, this one has no disk cache
    /// at all (ephemeral: `urlCache` is a real, non-nil `URLCache` with
    /// `diskCapacity == 0` — memory-only, nothing ever reaches
    /// `Caches/image-proxy`), `ImageTransport`'s has a positive disk capacity.
    /// Actual isolation is that `serveSettings`/`serveGraphQL` call only
    /// `Transport.sendSync`, never `ImageTransport.stream` — not something a
    /// value-level check can observe directly, so this is the closest
    /// structural proof.
    static var usesDiskCache: Bool { (session.configuration.urlCache?.diskCapacity ?? 0) > 0 }

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

// MARK: - ImageTransport

/// The image lane's session (#071, the #060 grey-splash fix mirrored from
/// Android's `imageClient()`): unlike `Transport`, NOT ephemeral — a disk
/// `URLCache` is the entire point, so a second open of a grid answers posters
/// from `Caches/image-proxy` instead of media-amazon. The settings and
/// credential lanes stay on `Transport`'s ephemeral, no-store session; nothing
/// that spends a secret or carries `/api/settings` ever touches this one.
enum ImageTransport {
    /// 8 MB memory / 64 MB disk under `Caches/image-proxy`, so the OS may
    /// purge it under storage pressure — a purged poster costs one more
    /// upstream fetch, never a crash. Matches Android's 64 MB `image-proxy`
    /// `okhttp3.Cache` sizing.
    static let cache: URLCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("image-proxy", isDirectory: true)
        return URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024, directory: dir)
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // timeoutIntervalForRequest is an inactivity timeout, not a transfer
        // bound — a server that trickles bytes never trips it. The 25 s wait
        // in stream() below is a transfer bound, so timeoutIntervalForResource
        // must be under it or a slow poster can still be running past the
        // semaphore's timeout with outcome left at its .failed default.
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = cache
        return URLSession(configuration: config, delegate: StreamDelegate.shared, delegateQueue: nil)
    }()

    static var usesDiskCache: Bool { (session.configuration.urlCache?.diskCapacity ?? 0) > 0 }

    /// One hop, streamed to `sink` as bytes arrive rather than buffered whole
    /// and re-chunked afterwards. Redirects are refused by `StreamDelegate`
    /// exactly as `Transport.RefuseRedirects` does, so a 3xx completes as its
    /// own final response with no further body — `ApiSchemeHandler`'s per-hop
    /// allowlist re-check is unchanged, it just reads the outcome differently.
    /// The 25 s wait here is comfortably above `timeoutIntervalForResource`
    /// (20 s) on `session`, so the transfer itself — not just the connection
    /// going idle — is what's actually bounded below this call returning.
    static func stream(_ request: URLRequest, sink: ImageSink) {
        let semaphore = DispatchSemaphore(value: 0)
        StreamDelegate.shared.run(session.dataTask(with: request), sink: sink) { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 25)
    }

    /// Applied in `StreamDelegate`'s `willCacheResponse` before a response is
    /// allowed into `cache`. An explicit upstream `Cache-Control` is honoured
    /// as-is, `no-store` included — the URL Loading System typically never
    /// offers a no-store response to this delegate method at all, so the
    /// explicit veto here is defence in depth, not the only thing standing in
    /// the way. Only when upstream sends no header at all does this invent
    /// `ApiSchemeHandler.defaultImageCacheControl`, via a `CachedURLResponse`
    /// rewrite (fewer lines than calling `URLCache.storeCachedResponse`
    /// directly, and it runs through the same callback the real session uses).
    static func cachePolicy(for proposed: CachedURLResponse) -> CachedURLResponse? {
        guard let http = proposed.response as? HTTPURLResponse else { return proposed }
        // Redirects are refused (StreamDelegate), so a 3xx IS the final response
        // of its hop and CFNetwork may still offer it here; a 404/410 is
        // heuristically cacheable too. None of those are the poster — caching
        // any of them under the image's URL would poison it until eviction.
        guard (200...299).contains(http.statusCode) else { return nil }
        if let cacheControl = http.value(forHTTPHeaderField: "Cache-Control") {
            return cacheControl.lowercased().contains("no-store") ? nil : proposed
        }
        guard let url = http.url else { return proposed }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { headers[key] = "\(value)" }
        }
        headers["Cache-Control"] = ApiSchemeHandler.defaultImageCacheControl
        guard let rewritten = HTTPURLResponse(url: url, statusCode: http.statusCode,
                                              httpVersion: "HTTP/1.1", headerFields: headers) else {
            return proposed
        }
        return CachedURLResponse(response: rewritten, data: proposed.data,
                                 userInfo: proposed.userInfo, storagePolicy: proposed.storagePolicy)
    }
}

/// What one streamed image hop tells its caller, as it happens: a response
/// (return false to cancel before any body is spent), then chunks, then done.
protocol ImageSink: AnyObject {
    func respond(_ response: HTTPURLResponse) -> Bool
    func receive(_ data: Data)
    func complete(error: Error?)
}

/// One instance shared by every `ImageTransport.stream` call, keyed by task
/// identifier so concurrent hops (should the handler's queue ever stop being
/// serial) do not cross-deliver to the wrong sink.
private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    static let shared = StreamDelegate()

    private let lock = NSLock()
    private var sinks: [Int: (sink: ImageSink, done: () -> Void)] = [:]

    func run(_ task: URLSessionDataTask, sink: ImageSink, done: @escaping () -> Void) {
        lock.lock(); sinks[task.taskIdentifier] = (sink, done); lock.unlock()
        task.resume()
    }

    private func entry(for task: URLSessionTask) -> (sink: ImageSink, done: () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return sinks[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // refused, same as Transport.RefuseRedirects
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let entry = entry(for: dataTask), let http = response as? HTTPURLResponse,
              entry.sink.respond(http) else {
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        entry(for: dataTask)?.sink.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = entry(for: task) else { return }
        entry.sink.complete(error: error)
        lock.lock(); sinks.removeValue(forKey: task.taskIdentifier); lock.unlock()
        entry.done()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(ImageTransport.cachePolicy(for: proposedResponse))
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
