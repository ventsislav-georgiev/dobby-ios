import AppKit
import Foundation
import JavaScriptCore
import Network
import Security
import WebKit

/// #237 Type on TV, the pure parts: the pair answer, the Keychain decisions (a 401 drops the item,
/// a refusal never does, a refused read is not "not paired"), and the URL the TV's Host check
/// accepts. Fake values only: a token of 64 'a', code 123456, addresses from the documentation
/// ranges. The store is a fake that records what it was asked; the real Keychain is not touched.
@main
enum TvLinkCheck {
    static func main() {
        let checks: [(String, () -> Void)] = [
            ("pairAnswerTakesOnlyAWellFormedToken", pairAnswerTakesOnlyAWellFormedToken),
            ("pairRefusalsLeaveTheStoreAlone", pairRefusalsLeaveTheStoreAlone),
            ("aTokenCall401DropsTheItem", aTokenCall401DropsTheItem),
            ("onlyItemNotFoundIsNotPaired", onlyItemNotFoundIsNotPaired),
            ("urlIsAnIpLiteralTheTvAccepts", urlIsAnIpLiteralTheTvAccepts),
            ("codeIsSixAsciiDigits", codeIsSixAsciiDigits),
            ("pageWatcherPostsOnlyA401ToTvLink", pageWatcherPostsOnlyA401ToTvLink),
            ("pageConfigurationInjectsTheWatcherAtDocumentStart", pageConfigurationInjectsTheWatcherAtDocumentStart),
            ("onlyA401MessageUnpairs", onlyA401MessageUnpairs),
        ]
        let only = Set(CommandLine.arguments.dropFirst())
        for (name, run) in checks where only.isEmpty || only.contains(name) { run() }
        print("TvLinkCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what) (#237)\n".utf8))
            exit(1)
        }
    }

    static let token = String(repeating: "a", count: 64)

    /// A store that records every call and answers with the given statuses.
    final class Fake {
        var saved: [(String, Data)] = []
        var dropped: [String] = []
        var dropStatus: OSStatus = errSecSuccess
        var store: TvLinkStore {
            TvLinkStore(read: { _ in (nil, errSecItemNotFound) },
                        save: { self.saved.append(($0, $1)); return errSecSuccess },
                        drop: { self.dropped.append($0); return self.dropStatus })
        }
    }

    static func body(_ json: String) -> Data { Data(json.utf8) }

    static func pairAnswerTakesOnlyAWellFormedToken() {
        check(TvLink.pairAnswer(status: 200, body: body("{\"ok\":true,\"token\":\"\(token)\"}")) == .paired(token),
              "a 200 with ok true and a 64 lower-case hex token must pair")
        check(TvLink.pairAnswer(status: 200, body: body("{\"ok\":true,\"token\":\"\(token)\",\"tv\":\"x\",\"v\":2}")) == .paired(token),
              "extra fields in a 200 pair answer must be ignored")
        let refused: [(String, String)] = [
            ("{\"ok\":true,\"token\":\"\(String(token.dropLast()))\"}", "a 63-digit token"),
            ("{\"ok\":true,\"token\":\"\(token)a\"}", "a 65-digit token"),
            ("{\"ok\":true,\"token\":\"\(token.uppercased())\"}", "an upper-case hex token"),
            ("{\"ok\":true,\"token\":\"\(String(repeating: "g", count: 64))\"}", "a non-hex token"),
            ("{\"ok\":true,\"token\":\"\(String(repeating: "a", count: 63)) \"}", "a token with a space"),
            ("{\"ok\":false,\"token\":\"\(token)\"}", "ok false"),
            ("{\"token\":\"\(token)\"}", "no ok"),
            ("{\"ok\":true}", "no token"),
            ("{\"ok\":true,\"token\":7}", "a number token"),
            ("[\"\(token)\"]", "an array"),
            ("not json", "a non-JSON body"),
            ("", "an empty body"),
        ]
        for (json, what) in refused {
            check(TvLink.pairAnswer(status: 200, body: body(json)) == .refused, "a 200 pair answer with \(what) must be refused")
        }
        let good = body("{\"ok\":true,\"token\":\"\(token)\"}")
        for status in [201, 204, 400, 403, 404, 405, 429, 500] {
            check(TvLink.pairAnswer(status: status, body: good) == .refused, "a \(status) pair answer must be refused, token or not")
        }
        check(TvLink.pairAnswer(status: 401, body: body("{\"ok\":false,\"error\":\"code\"}")) == .wrongCode, "401 is a wrong code")
        check(TvLink.pairAnswer(status: 409, body: body("{\"ok\":false,\"error\":\"closed\"}")) == .closed, "409 is a closed guide")
        check(TvLink.pairAnswer(status: 400, body: body("{\"ok\":false,\"error\":\"json\"}")) == .refused, "400 is refused")
    }

    static func pairRefusalsLeaveTheStoreAlone() {
        for answer in [TvLink.Pair.wrongCode, .closed, .refused] {
            let fake = Fake()
            check(TvLink.settle(answer, tv: "Dobby Fake TV", store: fake.store) == nil, "\(answer) must not pair")
            check(fake.saved.isEmpty && fake.dropped.isEmpty, "\(answer) must leave the store as it was")
        }
        for (status, json) in [(409, "{\"ok\":false,\"error\":\"closed\"}"), (400, "{\"ok\":false,\"error\":\"host\"}"),
                               (401, "{\"ok\":false,\"error\":\"code\"}")] {
            let fake = Fake()
            let answer = TvLink.pairAnswer(status: status, body: body(json))
            check(TvLink.settle(answer, tv: "Dobby Fake TV", store: fake.store) == nil && fake.saved.isEmpty && fake.dropped.isEmpty,
                  "a \(status) from /v1/pair must be not paired, with nothing saved or dropped")
        }
        let fake = Fake()
        check(TvLink.settle(.paired(token), tv: "Dobby Fake TV", store: fake.store) == token, "a pairing hands the token back")
        check(fake.saved.count == 1 && fake.saved[0].0 == "Dobby Fake TV" && fake.saved[0].1 == Data(token.utf8) && fake.dropped.isEmpty,
              "a pairing saves the token under the TV's name and drops nothing")
    }

    static func aTokenCall401DropsTheItem() {
        let fake = Fake()
        check(!TvLink.answered(401, tv: "Dobby Fake TV", store: fake.store), "a 401 must say ask for a new code")
        check(fake.dropped == ["Dobby Fake TV"] && fake.saved.isEmpty, "a 401 must drop that TV's item and save nothing")
        let refusing = Fake()
        refusing.dropStatus = errSecInteractionNotAllowed
        check(!TvLink.answered(401, tv: "Dobby Fake TV", store: refusing.store) && refusing.dropped == ["Dobby Fake TV"],
              "a 401 asks for a new code even when the drop is refused")
        for status in [200, 204, 400, 403, 404, 405, 409, 429, 500] {
            let kept = Fake()
            check(TvLink.answered(status, tv: "Dobby Fake TV", store: kept.store) && kept.dropped.isEmpty && kept.saved.isEmpty,
                  "a \(status) must keep the token")
        }
    }

    static func onlyItemNotFoundIsNotPaired() {
        check(TvLink.saved((nil, errSecItemNotFound)) == .none, "errSecItemNotFound is not paired")
        check(TvLink.saved((Data(token.utf8), errSecSuccess)) == .token(token), "a stored token is read back")
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement, errSecNotAvailable, OSStatus(-1)] {
            check(TvLink.saved((nil, status)) == .refused, "a read refused with \(status) must not read as not paired")
        }
    }

    static func urlIsAnIpLiteralTheTvAccepts() {
        // PhoneLink.IP_LITERAL_HOST, the TV's Host check, transcribed.
        let hostRule = try! NSRegularExpression(pattern: #"^(\d{1,3}(\.\d{1,3}){3}|\[[0-9A-Fa-f:.]+\])(:\d{1,5})?$"#)
        func hostHeader(_ url: URL) -> String {
            String(url.absoluteString.dropFirst("http://".count).prefix { $0 != "/" })
        }
        func accepted(_ url: URL) -> Bool {
            let h = hostHeader(url)
            return hostRule.firstMatch(in: h, range: NSRange(h.startIndex..., in: h)) != nil
        }
        let port = NWEndpoint.Port(rawValue: 8080)!
        let v4 = TvLink.Address(host: .ipv4(IPv4Address("192.0.2.1")!), port: port)
        check(TvLink.url(v4, token: token)?.absoluteString == "http://192.0.2.1:8080/#\(token)",
              "IPv4: http://<literal>:<port>/#<token>")
        check(TvLink.url(v4, path: "/v1/pair")?.absoluteString == "http://192.0.2.1:8080/v1/pair", "IPv4 route, no fragment")
        let v6 = TvLink.Address(host: .ipv6(IPv6Address("2001:db8::1")!), port: port)
        check(TvLink.url(v6, token: token)?.absoluteString == "http://[2001:db8::1]:8080/#\(token)",
              "IPv6: bracketed literal, no zone")
        for url in [TvLink.url(v4, token: token), TvLink.url(v6, path: "/v1/pair")].compactMap({ $0 }) {
            check(accepted(url), "the TV's Host rule must accept the URL's host and port")
        }
        check(TvLink.url(v4, token: token)?.fragment == token && TvLink.url(v4, token: token)?.path == "/",
              "the token rides only in the fragment")
        for (host, what) in [(NWEndpoint.Host.ipv6(IPv6Address("fe80::1%lo0")!), "a zone-id link-local IPv6"),
                             (.ipv6(IPv6Address("fe80::1")!), "a link-local IPv6 (it needs a zone)"),
                             (.ipv6(IPv6Address("2001:db8::1%lo0")!), "an IPv6 with a zone"),
                             (.name("dobby-tv.example", nil), "a host name")] {
            check(TvLink.hostLiteral(host) == nil && TvLink.url(TvLink.Address(host: host, port: port), token: token) == nil,
                  "\(what) must be refused")
        }
        check(TvLink.url(v4, token: token.uppercased()) == nil && TvLink.url(v4, token: "a") == nil,
              "a malformed token never reaches the fragment")
    }

    static func codeIsSixAsciiDigits() {
        check(TvLink.isCode("123456"), "six digits is a code")
        for bad in ["12345", "1234567", "12345a", "", " 12345", "１２３４５６", "12 456"] {
            check(!TvLink.isCode(bad), "\(bad.debugDescription) is not a code")
        }
    }

    // MARK: the TV page's own 401s (review round 1)

    /// TvLinkPage.watch401 run in JavaScriptCore against a stub page: the fetch it wraps answers
    /// with the given status, and every message handler records what reached it by name.
    static func watched(_ status: Int) -> (posts: [String], passedThrough: Bool) {
        let ctx = JSContext()!
        var thrown: [String] = []
        ctx.exceptionHandler = { _, e in thrown.append(e?.toString() ?? "?") }
        ctx.evaluateScript("""
            var window = this, posts = [], passed = false;
            var handler = function (name) { return { postMessage: function (b) { posts.push(name + ':' + b); } }; };
            window.webkit = { messageHandlers: new Proxy({}, { get: function (_, name) { return handler(name); } }) };
            window.fetch = function () { return Promise.resolve({ status: \(status) }); };
            """)
        ctx.evaluateScript(TvLinkPage.watch401)
        ctx.evaluateScript("window.fetch('/v1/search').then(function (r) { passed = r.status === \(status); });")
        check(thrown.isEmpty, "watch401 threw in a stub page: \(thrown)")
        let posts = ctx.evaluateScript("posts.join(',')")?.toString() ?? ""
        return (posts.isEmpty ? [] : posts.components(separatedBy: ","), ctx.evaluateScript("passed")?.toBool() == true)
    }

    static func pageWatcherPostsOnlyA401ToTvLink() {
        let seen = watched(401)
        check(seen.posts == ["tvLink:401"], "a 401 from the page's fetch must post '401' to the tvLink handler once; got \(seen.posts)")
        check(seen.passedThrough, "the watcher must hand the 401 response on to the page")
        for status in [200, 400, 403, 404, 409, 429, 500] {
            let other = watched(status)
            check(other.posts.isEmpty, "a \(status) from the page's fetch must post nothing; got \(other.posts)")
            check(other.passedThrough, "the watcher must hand a \(status) response on to the page")
        }
    }

    static func pageConfigurationInjectsTheWatcherAtDocumentStart() {
        let config = TvLinkPage.configuration(TvLinkPage.Coordinator(unpaired: {}))
        let scripts = config.userContentController.userScripts
        check(scripts.count == 1 && scripts[0].source == TvLinkPage.watch401, "the page's one user script must be watch401")
        check(scripts.first?.injectionTime == .atDocumentStart, "watch401 must be injected at document start, before the page's first fetch")
        check(scripts.first?.isForMainFrameOnly == true, "watch401 must be injected in the main frame only")
        check(!config.websiteDataStore.isPersistent, "the TV page must not persist anything")
    }

    /// A real WKWebView on TvLinkPage.configuration: the tvLink handler is registered, and only the
    /// string "401" reaches unpaired.
    static func onlyA401MessageUnpairs() {
        _ = NSApplication.shared
        final class Count { var n = 0 }
        let count = Count()
        let webView = WKWebView(frame: .zero, configuration: TvLinkPage.configuration(TvLinkPage.Coordinator(unpaired: { count.n += 1 })))
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while !loaded.done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03)) }
        check(loaded.done, "test setup: the stub page did not load")
        func post(_ body: String) -> Int {
            let before = count.n
            var answered = false
            webView.evaluateJavaScript("typeof window.webkit.messageHandlers.tvLink === 'object' && (window.webkit.messageHandlers.tvLink.postMessage(\(body)), true)") { value, _ in
                check(value as? Bool == true, "the tvLink message handler must be registered on the page's configuration")
                answered = true
            }
            // A round trip after the post, so the handler has run before counting.
            let until = Date().addingTimeInterval(10)
            while !answered && Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03)) }
            var flushed = false
            webView.evaluateJavaScript("1") { _, _ in flushed = true }
            while !flushed && Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03)) }
            check(answered && flushed, "test setup: the page did not answer")
            return count.n - before
        }
        for body in ["'403'", "401", "'401 '", "{status: 401}", "'unpaired'", "''"] {
            check(post(body) == 0, "a tvLink message \(body) must not unpair")
        }
        check(post("'401'") == 1, "the tvLink message '401' must unpair once")
    }
}
