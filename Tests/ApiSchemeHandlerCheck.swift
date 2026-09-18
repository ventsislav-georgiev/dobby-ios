import Foundation

// The rules in ApiSchemeHandler that are worth being wrong about: the image
// allowlist, the redirect re-check, the cookie rule, the mirror-first fallback and
// the JSON-null token trap.
//
// A standalone binary rather than an XCTest target because the app project has no
// test target and adding one would put a second scheme and a host-app dependency
// into a pbxproj that is generated on every build — a lot of machinery around six
// pure functions. Run it with:
//
//   ./Tests/run-checks.sh
//
// No secret value appears here; the token fixtures are obvious fakes and are only
// ever asserted on by presence and length.

@main
enum ApiSchemeHandlerCheck {
    static func main() {
        allowlist()
        redirects()
        cookieRule()
        mirrorFallback()
        tokenTrap()
        corsOriginGate()
        imageCacheHit()
        imageCachePolicy()
        imageLaneIsolation()
        imageCacheNonSuccessNeverHits()
        print("ApiSchemeHandlerCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    // MARK: exact host, near-miss host

    static func allowlist() {
        for allowed in [
            "https://m.media-amazon.com/images/M/poster.jpg",
            "https://images-na.ssl-images-amazon.media-amazon.com/x.jpg",
            "https://m.media-amazon.co.uk/images/M/poster.jpg",
            "https://a.media-amazon.co.uk/x.png",
        ] {
            check(ApiSchemeHandler.allowedImageURL(allowed) != nil, "allowed: \(allowed)")
        }
        for refused in [
            // the classic suffix walk-past
            "https://media-amazon.com.attacker.tld/x.jpg",
            "https://m.media-amazon.com.attacker.tld/x.jpg",
            // one character off
            "https://mmedia-amazon.com/x.jpg",
            "https://m.media-amazon.net/x.jpg",
            "https://m.media-amazonxcom/x.jpg",
            // scheme and port are part of the rule
            "http://m.media-amazon.com/x.jpg",
            "https://m.media-amazon.com:8443/x.jpg",
            // the credential host is not on the image allowlist
            "https://graphql.imdb.com/",
            "",
        ] {
            check(ApiSchemeHandler.allowedImageURL(refused) == nil, "refused: \(refused)")
        }
        check(ApiSchemeHandler.allowedImageURL(nil) == nil, "refused: nil url")
    }

    // MARK: a redirect off the allowlist

    static func redirects() {
        let current = URL(string: "https://m.media-amazon.com/images/M/poster.jpg")!

        check(ApiSchemeHandler.nextImageHop(from: current, location: "/images/M/moved.jpg")?.absoluteString
            == "https://m.media-amazon.com/images/M/moved.jpg", "relative hop stays on the allowlist")
        check(ApiSchemeHandler.nextImageHop(from: current, location: "https://a.media-amazon.com/x.jpg") != nil,
              "absolute hop onto another allowlisted host")

        check(ApiSchemeHandler.nextImageHop(from: current, location: "https://attacker.tld/x.jpg") == nil,
              "hop off the allowlist is refused")
        check(ApiSchemeHandler.nextImageHop(from: current, location: "http://m.media-amazon.com/x.jpg") == nil,
              "hop downgraded to http is refused")
        check(ApiSchemeHandler.nextImageHop(from: current, location: "//attacker.tld/x.jpg") == nil,
              "protocol-relative hop off the allowlist is refused")
        check(ApiSchemeHandler.nextImageHop(from: current, location: nil) == nil,
              "3xx with no Location is refused")
    }

    // MARK: the cookie goes to exactly one host, and only on the credential lane

    static func cookieRule() {
        let token = "fake-at-main-token"
        let credential = ApiSchemeHandler.credentialRequest(document: "{\"query\":\"{x}\"}", token: token)

        check(credential.url?.absoluteString == "https://graphql.imdb.com/", "credential URL is fixed")
        check(ApiSchemeHandler.isAllowedCredentialURL(credential.url!), "credential URL is allowlisted")
        let cookie = credential.value(forHTTPHeaderField: "Cookie")
        check(cookie != nil, "credential request carries a Cookie")
        check(cookie!.hasPrefix("at-main="), "cookie is the at-main cookie")
        check(cookie!.contains("ubid-main="), "cookie carries the session id")
        check(credential.value(forHTTPHeaderField: "x-imdb-client-name") == "imdb-web-next",
              "IMDb edge needs the client-name header")
        check(credential.httpMethod == "POST", "credential lane POSTs the document upstream")

        let image = ApiSchemeHandler.imageRequest(URL(string: "https://m.media-amazon.com/x.jpg")!)
        check(image.value(forHTTPHeaderField: "Cookie") == nil, "image lane carries no cookie")
        check(image.allHTTPHeaderFields?.isEmpty ?? true, "image lane injects nothing at all")

        // Only graphql.imdb.com, no wildcards — a near-miss must not be the credential host.
        for refused in ["https://graphql.imdb.com.attacker.tld/", "https://imdb.com/",
                        "https://www.graphql.imdb.com/", "http://graphql.imdb.com/",
                        "https://graphql.imdb.com:8443/"] {
            check(!ApiSchemeHandler.isAllowedCredentialURL(URL(string: refused)!), "not credential host: \(refused)")
        }
    }

    // MARK: mirror-first

    static func mirrorFallback() {
        let mirrored = Data(#"{"premiumizeApiKey":"fake-key"}"#.utf8)
        let fresh = Data(#"{"premiumizeApiKey":"fake-key-2"}"#.utf8)

        var fetches = 0
        let hit = ApiSchemeHandler.settingsOutcome(mirror: mirrored) { fetches += 1; return fresh }
        check(hit.status == 200 && hit.body == mirrored, "a mirrored body is answered as-is")
        check(!hit.store, "a mirror hit does not rewrite the mirror")
        check(fetches == 0, "a mirror hit never waits on the Pi")

        let cold = ApiSchemeHandler.settingsOutcome(mirror: nil) { fetches += 1; return fresh }
        check(cold.status == 200 && cold.body == fresh, "an empty mirror waits on the Pi")
        check(cold.store, "the fetched body becomes the mirror")
        check(fetches == 1, "the empty mirror is the only case that fetches")

        let dead = ApiSchemeHandler.settingsOutcome(mirror: nil) { nil }
        check(dead.status == 503, "empty mirror plus no Pi is a 503")
        check(!dead.store, "a 503 body is never mirrored")

        let empty = ApiSchemeHandler.settingsOutcome(mirror: Data()) { fresh }
        check(empty.status == 200 && empty.body == fresh, "an empty mirror entry counts as no mirror")
    }

    // MARK: the JSON-null trap

    static func tokenTrap() {
        func token(_ json: String) -> String? {
            SettingsMirrorStore.imdbAuthToken(from: Data(json.utf8))
        }
        let present = token(#"{"imdbAuthToken":"fake-token-value","hasImdbAuthToken":true}"#)
        check(present != nil, "a set token is read back")
        check(present!.count == 16, "token read back whole (length only, never the value)")

        check(token(#"{"imdbAuthToken":null,"hasImdbAuthToken":false}"#) == nil, "JSON null is no token")
        check(token(#"{"imdbAuthToken":"","hasImdbAuthToken":false}"#) == nil, "empty string is no token")
        check(token(#"{"hasImdbAuthToken":false}"#) == nil, "absent key is no token")
        check(token("not json at all") == nil, "an unparseable mirror is no token")
        check(token("[]") == nil, "a non-object mirror is no token")
        check(SettingsMirrorStore.imdbAuthToken(from: nil) == nil, "no mirror is no token")
        check(SettingsMirrorStore.imdbAuthToken(from: Data()) == nil, "an empty mirror is no token")
    }

    /// The scheme handler hangs off the WKWebViewConfiguration, so every document
    /// the WebView loads can fetch `dobby-api:` — an iframe, a page it navigated
    /// to. The secret lanes therefore answer ACAO only to the server's own origin;
    /// anything else, and a request with no Origin at all, gets no header and the
    /// caller cannot read the body.
    static func corsOriginGate() {
        let server = "http://dobby.local:8080"

        for (lane, secret) in [("settings", true), ("credential", true)] {
            check(ApiSchemeHandler.acao(origin: server, serverOrigin: server, secret: secret) == server,
                  "\(lane): the server's own origin gets ACAO")
            check(ApiSchemeHandler.acao(origin: "https://evil.example", serverOrigin: server,
                                        secret: secret) == nil,
                  "\(lane): a third-party origin gets no ACAO")
            check(ApiSchemeHandler.acao(origin: nil, serverOrigin: server, secret: secret) == nil,
                  "\(lane): no Origin gets no ACAO — never a * fallback")
            for refused in ["null", "", "http://dobby.local", "https://dobby.local:8080",
                            "http://dobby.local:8081", "http://dobby.local.evil.example:8080",
                            "http://evil.example/?x=http://dobby.local:8080"] {
                check(ApiSchemeHandler.acao(origin: refused, serverOrigin: server, secret: secret) == nil,
                      "\(lane): not the server origin: \(refused)")
            }
            check(ApiSchemeHandler.acao(origin: server, serverOrigin: nil, secret: secret) == nil,
                  "\(lane): an unparseable server URL gates everything shut")
        }

        // Case and default ports are spellings of one origin, not different ones.
        check(ApiSchemeHandler.acao(origin: "HTTP://Dobby.Local:8080", serverOrigin: server,
                                    secret: true) == server, "origin compare is case-insensitive")
        check(ApiSchemeHandler.acao(origin: "https://pi.ts.net:443",
                                    serverOrigin: ApiSchemeHandler.normalizedOrigin("https://pi.ts.net/x"),
                                    secret: true) == "https://pi.ts.net",
              "an explicit default port is the same origin")
        check(ApiSchemeHandler.normalizedOrigin("http://pi.local:80/api") == "http://pi.local",
              "http default port is dropped")
        check(ApiSchemeHandler.normalizedOrigin("http://pi.local:8080/api") == "http://pi.local:8080",
              "a non-default port is kept")
        check(ApiSchemeHandler.normalizedOrigin("null") == nil, "an opaque origin never normalises")
        check(ApiSchemeHandler.normalizedOrigin(nil) == nil, "no origin never normalises")

        // The image lane carries no secret, so it keeps the permissive header.
        check(ApiSchemeHandler.acao(origin: "https://evil.example", serverOrigin: server,
                                    secret: false) == "https://evil.example",
              "image lane still echoes a third-party origin")
        check(ApiSchemeHandler.acao(origin: nil, serverOrigin: server, secret: false) == "*",
              "image lane still answers * with no Origin")
    }

    // MARK: #071 — a disk hit answers with no transport call

    static func imageCacheHit() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 1 << 20, directory: dir)
        let url = URL(string: "https://m.media-amazon.com/images/M/poster.jpg")!
        let request = ApiSchemeHandler.imageRequest(url)

        var fetches = 0
        func fetchOrCache() -> ApiSchemeHandler.CachedImageAnswer? {
            if let hit = ApiSchemeHandler.cachedImageAnswer(cache, request) { return hit }
            fetches += 1
            return nil
        }

        check(fetchOrCache() == nil, "a cold cache has nothing")
        check(fetches == 1, "a cold cache calls the transport once")

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/jpeg",
                                                      "Cache-Control": "public, max-age=3600"])!
        let bytes = Data("fake-poster-bytes".utf8)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes), for: request)

        let first = fetchOrCache()
        check(first?.data == bytes, "the cached bytes are served")
        check(fetches == 1, "a cache hit never calls the transport")

        let second = fetchOrCache()
        check(second?.data == bytes, "a second request for the same URL is also served from disk")
        check(fetches == 1, "still 1: the second request never calls the transport either")
    }

    // MARK: #071 — the willCacheResponse rewrite/veto

    static func imageCachePolicy() {
        let url = URL(string: "https://m.media-amazon.com/images/M/poster.jpg")!
        let data = Data("x".utf8)

        // Upstream sends nothing: our default is stamped on.
        let bare = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        let bareProposal = CachedURLResponse(response: bare, data: data)
        let stamped = ImageTransport.cachePolicy(for: bareProposal)
        let stampedHTTP = stamped?.response as? HTTPURLResponse
        check(stampedHTTP?.value(forHTTPHeaderField: "Cache-Control") == ApiSchemeHandler.defaultImageCacheControl,
              "no upstream Cache-Control gets the #071 default stamped on before caching")

        // Upstream sends its own value: honoured verbatim, no rewrite.
        let own = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                  headerFields: ["Cache-Control": "public, max-age=60"])!
        let ownProposal = CachedURLResponse(response: own, data: data)
        let honoured = ImageTransport.cachePolicy(for: ownProposal)
        check((honoured?.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=60",
              "an explicit upstream Cache-Control is honoured, not overwritten")

        // Upstream says no-store: vetoed, never handed to the cache.
        let noStore = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                      headerFields: ["Cache-Control": "no-store"])!
        let noStoreProposal = CachedURLResponse(response: noStore, data: data)
        check(ImageTransport.cachePolicy(for: noStoreProposal) == nil,
              "Cache-Control: no-store is never cached")

        // A redirect is refused, so it IS the final response of its hop and
        // CFNetwork may still offer it here with no Cache-Control of its own —
        // must never be stamped and stored under the image's URL.
        let redirect = HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: [:])!
        let redirectProposal = CachedURLResponse(response: redirect, data: data)
        check(ImageTransport.cachePolicy(for: redirectProposal) == nil,
              "a 301 with no Cache-Control is never cached")

        // A heuristically-cacheable 404 is the same hazard.
        let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
        let notFoundProposal = CachedURLResponse(response: notFound, data: data)
        check(ImageTransport.cachePolicy(for: notFoundProposal) == nil,
              "a 404 with no Cache-Control is never cached")
    }

    // MARK: #071 — the credential/settings lane and the image lane are different sessions

    static func imageLaneIsolation() {
        check(!Transport.usesDiskCache, "the settings/credential lane (Transport) has no disk cache")
        check(ImageTransport.usesDiskCache, "the image lane (ImageTransport) has a disk cache")
    }

    // MARK: #071 review fix — a non-2xx cache entry is never served as a hit

    static func imageCacheNonSuccessNeverHits() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 1 << 20, directory: dir)
        let url = URL(string: "https://m.media-amazon.com/images/M/missing.jpg")!
        let request = ApiSchemeHandler.imageRequest(url)

        // Stored directly (bypassing cachePolicy) so this check stands on its
        // own even if the store-side veto above is ever weakened.
        let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
        cache.storeCachedResponse(CachedURLResponse(response: notFound, data: Data()), for: request)

        check(ApiSchemeHandler.cachedImageAnswer(cache, request) == nil,
              "a stored 404 is never served as a cache hit")
    }
}
