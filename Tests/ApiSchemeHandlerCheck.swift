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
}
