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
        private var seen: [(url: String, origin: String?)] = []

        init(server: URL) {
            self.inner = ApiSchemeHandler(server: server)
            super.init()
        }

        var started: [(url: String, origin: String?)] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            lock.lock()
            seen.append((task.request.url?.absoluteString ?? "<nil>",
                         task.request.value(forHTTPHeaderField: "Origin")))
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

        // display-only: the assertions are the three check(...) calls below, not this loop.
        for task in handler.started {
            let carried = task.origin ?? "<no Origin header>"
            let gate = ApiSchemeHandler.acao(origin: task.origin,
                                             serverOrigin: ApiSchemeHandler.normalizedOrigin(server.absoluteString),
                                             secret: true) ?? "<nil, no ACAO emitted>"
            print("start:        \(task.url)\n              Origin: \(carried) -> acao(secret: true) = \(gate)")
        }

        check(handler.started.count == 2, "both fetches reached the scheme handler")
        check(publicLane == "status 400", "the public lane answers an HTTP status, not a network error")
        // The one that was broken: without the fix this rejects before the handler.
        check(secretLane == "status 400", "the secret lane answers an HTTP status, not a network error")

        print(failures == 0 ? "ApiSchemeWebViewCheck: all good" : "ApiSchemeWebViewCheck: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
