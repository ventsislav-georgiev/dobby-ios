import AppKit
import Foundation
import WebKit

// #067, the Mac "Load failed". `ApiSchemeHandlerCheck` proves `acao(...)` returns
// the right string for the right inputs; it cannot prove the handler is reached at
// all. It was not: `dobby-api:` is not a trustworthy scheme, so from the https page
// the Mac loads, every `fetch('dobby-api://…')` was blockable mixed content and
// WebKit refused it before `webView(_:start:)` — the sanitised `TypeError: Load
// failed` the episode list rendered.
//
// So this check drives a real WKWebView, configured as `WebContainer` configures
// it, with a document on the real server origin, and asserts that both lanes answer
// an HTTP status rather than rejecting. It is the thing that fails if a future
// macOS drops the SPI `ApiSchemeHandler.registerAsSecureScheme` leans on.
//
// It touches neither the network nor the Keychain: `loadHTMLString(baseURL:)`
// supplies the origin without a request, and both probes are refused by argument
// checks that run before `SettingsMirrorStore` or any upstream call.
//
// macOS only — `run-checks.sh` skips it elsewhere. A command-line WebKit client
// needs an NSApplication before the first WKWebView, hence AppKit.
@main
enum ApiSchemeWebViewCheck {
    /// Records what the handler was handed, then forwards verbatim — a spy rather
    /// than a subclass, because `ApiSchemeHandler` is `final` and should stay so.
    private final class SpyHandler: NSObject, WKURLSchemeHandler {
        private let inner: ApiSchemeHandler
        private let lock = NSLock()
        private var seen: [(url: String, origin: String?, method: String, body: Data?, stream: Bool)] = []

        init(server: URL) {
            self.inner = ApiSchemeHandler(server: server)
            super.init()
        }

        var started: [(url: String, origin: String?, method: String, body: Data?, stream: Bool)] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            lock.lock()
            // #149 records the body as well. WebKit populating `httpBody` for a
            // scheme-handled POST is the measured premise the whole iOS settings
            // write rests on — it is why this side needs no JS bridge and no 409
            // the way Android does, and if a future WebKit stops doing it, every
            // save on a Pi-less iPhone turns into the handler's 400 with nothing
            // else in the repo noticing.
            seen.append((task.request.url?.absoluteString ?? "<nil>",
                         task.request.value(forHTTPHeaderField: "Origin"),
                         task.request.httpMethod ?? "<nil>",
                         task.request.httpBody,
                         task.request.httpBodyStream != nil))
            lock.unlock()
            inner.webView(webView, start: task)
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
            inner.webView(webView, stop: task)
        }
    }

    /// Same predicate as WebContainer.isAppBound: true when `url`'s host is covered
    /// by WKAppBoundDomains. Duplicated rather than shared because WebContainer.swift
    /// isn't part of this check's compile unit (see run-checks.sh).
    private static func isAppBound(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              let domains = Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") as? [String]
        else { return false }
        return domains.contains { domain in
            let d = domain.lowercased()
            return host == d || host.hasSuffix("." + d)
        }
    }

    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok  " : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    /// Spins the main run loop until `ready()` or the budget expires: a command-line
    /// tool never calls `NSApp.run`, and WebKit's IPC needs the run loop turning.
    private static func pump(_ seconds: TimeInterval, _ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
    }

    private static func evaluate(_ webView: WKWebView, _ body: String) -> String {
        var out: String?
        var done = false
        webView.callAsyncJavaScript("return (async () => { \(body) })();", in: nil, in: .page) { result in
            switch result {
            case .success(let value): out = value as? String ?? "\(value)"
            case .failure(let error): out = "evaluate failed: \(error.localizedDescription)"
            }
            done = true
        }
        pump(20) { done }
        return out ?? "<timed out>"
    }

    /// `status NNN` when the page got a real response, `error …` when the promise
    /// rejected — the difference between a lane that works and the reported bug.
    private static func fetchResult(_ webView: WKWebView, _ url: String) -> String {
        evaluate(webView, """
          try { const r = await fetch('\(url)'); return 'status ' + r.status; }
          catch (e) { return 'error ' + e.name + ': ' + e.message; }
        """)
    }

    /// The same, with a body — `body` is interpolated into a JS string literal, so
    /// every fixture passed here is plain ASCII with no quotes or backslashes.
    private static func postResult(_ webView: WKWebView, _ url: String, _ body: String) -> String {
        evaluate(webView, """
          try {
            const r = await fetch('\(url)', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: '\(body)'
            });
            return 'status ' + r.status;
          }
          catch (e) { return 'error ' + e.name + ': ' + e.message; }
        """)
    }

    static func main() {
        _ = NSApplication.shared

        let server = AppConfig.serverURL
        let handler = SpyHandler(server: server)

        // Mirrors WebContainer.makeWebView, including the order: the scheme is
        // registered as secure before the first WKWebView on this pool exists.
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = AppConfig.userAgentSuffix
        // Same predicate as WebContainer.isAppBound (duplicated here — WebContainer.swift
        // pulls in SwiftUI/EnvironmentObject and isn't part of this check's compile unit).
        // run-checks.sh links this binary with an embedded Info.plist carrying the same
        // WKAppBoundDomains entry as the app, so this evaluates true here exactly as it
        // does for the Mac app — reviewer Mutant F confirmed the fix holds with it on.
        config.limitsNavigationsToAppBoundDomains = isAppBound(server)
        print("appbound:     limitsNavigationsToAppBoundDomains=\(config.limitsNavigationsToAppBoundDomains)")
        check(config.limitsNavigationsToAppBoundDomains,
              "the check runs app-bound like the Mac app (WKAppBoundDomains read from the embedded Info.plist)")
        config.setURLSchemeHandler(handler, forURLScheme: ApiSchemeHandler.scheme)
        let registered = ApiSchemeHandler.registerAsSecureScheme(in: config)
        check(registered, "WebKit still accepts \(ApiSchemeHandler.scheme) being marked a secure scheme")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadHTMLString("<html><body></body></html>", baseURL: server)
        pump(10) { webView.url != nil && !webView.isLoading }

        let context = evaluate(webView, "return location.origin + ' secure=' + window.isSecureContext;")
        print("document:     \(context)")
        check(context == "\(server.absoluteString) secure=true",
              "the document is on the server origin and is a secure context, as in the app")

        // Public lane: serveProxy's `default:` answers 400 with secret: false.
        let publicLane = fetchResult(webView, "\(ApiSchemeHandler.scheme)://proxy?target=nonsense")
        print("public lane:  \(publicLane)")

        // Secret lane: serveGraphQL with no `q` answers 400 with secret: true, which
        // it does before SettingsMirrorStore.imdbAuthToken() — no Keychain, no upstream.
        let secretLane = fetchResult(webView, "\(ApiSchemeHandler.scheme)://proxy?target=imdb-graphql")
        print("secret lane:  \(secretLane)")

        // #149's premise, measured rather than assumed. Deliberately aimed at the
        // PROXY host, not `settings`: `serveProxy`'s `default:` answers 400 on the
        // unknown target before anything reads the Keychain or the mirror, so this
        // check keeps the promise in its own header — it touches neither the
        // network nor the Keychain — while still proving what WebKit hands a scheme
        // handler for a POST. The settings lane's own merge is values, in
        // ApiSchemeHandlerCheck; what cannot be proved there is that a body reaches
        // a scheme handler AT ALL.
        let postBody = "{\"fixture\":\"not-a-secret\"}"
        let postLane = postResult(webView, "\(ApiSchemeHandler.scheme)://proxy?target=nonsense", postBody)
        print("post lane:    \(postLane)")

        // display-only: the assertions are the check(...) calls below, not this loop.
        for task in handler.started {
            let carried = task.origin ?? "<no Origin header>"
            let gate = ApiSchemeHandler.acao(origin: task.origin,
                                             serverOrigin: ApiSchemeHandler.normalizedOrigin(server.absoluteString),
                                             secret: true) ?? "<nil, no ACAO emitted>"
            let carriedBody = task.body.map { "\($0.count) bytes" } ?? "<nil>"
            print("start:        \(task.method) \(task.url)\n              Origin: \(carried) -> acao(secret: true) = \(gate)"
                  + "\n              httpBody: \(carriedBody), httpBodyStream: \(task.stream)")
        }

        check(handler.started.count == 3, "all three fetches reached the scheme handler")
        check(postLane == "status 400", "the POST lane answers an HTTP status, not a network error")
        let posted = handler.started.filter { $0.method == "POST" }
        check(posted.count == 1, "exactly one task arrived as a POST")
        if let post = posted.first {
            // The measurement #149 was designed on. Nil here does not merely fail a
            // test: it means the iOS settings write silently 400s on every save, and
            // the design has to go back to Android's bridge-and-409 shape.
            check(post.body != nil,
                  "WKURLSchemeTask.request.httpBody is populated for a scheme-handled POST "
                      + "(#149's premise; nil here voids the whole iOS settings-write design)")
            check(post.body == Data(postBody.utf8),
                  "the body WebKit delivered is the bytes the page sent, unchanged")
            check(!post.stream,
                  "the body arrives as httpBody, not only as httpBodyStream — the handler "
                      + "reads httpBody and would refuse a stream-only body with a 400")
        }
        check(publicLane == "status 400", "the public lane answers an HTTP status, not a network error")
        // The one that was broken: without the fix this rejects before the handler.
        check(secretLane == "status 400", "the secret lane answers an HTTP status, not a network error")

        print(failures == 0 ? "ApiSchemeWebViewCheck: all good" : "ApiSchemeWebViewCheck: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
