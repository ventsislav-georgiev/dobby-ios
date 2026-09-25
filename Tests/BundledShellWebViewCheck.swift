import AppKit
import Foundation
import WebKit

// #151, the measurement half. `BundledShellCheck` proves the rewrite rule and the
// handler's routing agree as VALUES; it cannot prove WebKit does any of it. The
// Pi-less cold start rests on four WebKit behaviours that no pure function reaches:
//
//   1. `loadSimulatedRequest` really puts the document on the requested origin —
//      `location.origin`, `document.baseURI` and `isSecureContext` (the #151 done
//      condition's three), with no server behind it.
//   2. A classic `<script src="dobby-offline://shell/…">` in that https document is
//      fetched at all. It is blockable mixed content until the scheme is marked
//      secure, and a blocked classic script is a blank page with nothing logged —
//      no `catch`, no `decidePolicyFor` (#150 measured that sub-resources produce
//      none), nothing.
//   3. …and EXECUTES in the document's own realm, so the app's globals are the https
//      origin's, not the scheme's.
//   4. The Content-Type the handler emits is one WebKit will run. Before #151
//      everything fell through to `application/octet-stream`.
//
// The host is deliberately a name that does not resolve but IS covered by
// WKAppBoundDomains: that is a genuinely dead network — the never-paired case — while
// keeping the App-Bound Domains opt-in that Service Workers need, and it never touches
// the real Pi. #150 found a `WKContentRuleList` block is HARSHER than a dead Pi (it
// pre-empts service-worker interception entirely), so it is not used here.
//
// It also settles the question #151 carried as open: whether such a document can
// REGISTER `sw.js` when the registration fetch has nowhere to go. That one is REPORTED,
// not asserted — either answer is information, and the shell does not need it to boot.
//
// macOS only — `run-checks.sh` skips it elsewhere, same as ApiSchemeWebViewCheck.
@main
enum BundledShellWebViewCheck {
    /// Not a real host. A sibling of AppConfig.serverURL's host under the same
    /// app-bound domain, so `isAppBound` is true and nothing reaches the Pi.
    private static let origin = URL(string: "https://never-paired.solarflare-tarpon.ts.net")!

    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok  " : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    /// Same predicate as WebContainer.isAppBound (duplicated for the same reason
    /// ApiSchemeWebViewCheck duplicates it: WebContainer.swift pulls in SwiftUI).
    private static func isAppBound(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              let domains = Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") as? [String]
        else { return false }
        return domains.contains { host == $0.lowercased() || host.hasSuffix("." + $0.lowercased()) }
    }

    private static func pump(_ seconds: TimeInterval, _ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
    }

    private static func evaluate(_ webView: WKWebView, _ body: String, timeout: TimeInterval = 20) -> String {
        var out: String?
        var done = false
        webView.callAsyncJavaScript("return (async () => { \(body) })();", in: nil, in: .page) { result in
            switch result {
            case .success(let value): out = value as? String ?? "\(value)"
            case .failure(let error): out = "evaluate failed: \(error.localizedDescription)"
            }
            done = true
        }
        pump(timeout) { done }
        return out ?? "<timed out>"
    }

    /// A fixture shell, not the 46-file real one: the real one would run 26 scripts that
    /// immediately go looking for a Pi. The MARKUP still goes through the shipped
    /// `BundledShell.rewritingSubresources`, and the bytes are served by the shipped
    /// `OfflineSchemeHandler`, so what is under test is the app's own code either way.
    /// `BundledShellCheck` is what holds the rewrite against the real index.html.
    private static func makeFixtureShell() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dobby-shell-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("js"),
                                                 withIntermediateDirectories: true)
        // A classic script — the shape all 26 boot scripts have, and the shape that is
        // silently dropped when the scheme is not secure or the MIME type is wrong.
        try? "window.__shellBooted = location.origin;".write(
            to: root.appendingPathComponent("js/01-state-init.js"), atomically: true, encoding: .utf8)
        try? "body { --shell-booted: 42; }".write(
            to: root.appendingPathComponent("styles.css"), atomically: true, encoding: .utf8)
        return root
    }

    private static let fixtureHTML = """
    <!DOCTYPE html><html><head>
    <link rel="stylesheet" href="/styles.css">
    <script src="/js/01-state-init.js"></script>
    </head><body><div id="grid">grid</div></body></html>
    """

    static func main() {
        _ = NSApplication.shared

        let shellRoot = makeFixtureShell()
        let html = BundledShell.rewritingSubresources(fixtureHTML, root: shellRoot)
        check(html.contains("src=\"\(OfflineSchemeHandler.scheme)://\(BundledShell.host)/js/01-state-init.js\""),
              "the fixture's script tag was rewritten onto the scheme by the shipped rewrite")

        // Mirrors WebContainer.makeWebView, including the order: both schemes are marked
        // secure before the first WKWebView on this pool exists.
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = AppConfig.userAgentSuffix
        config.limitsNavigationsToAppBoundDomains = isAppBound(origin)
        check(config.limitsNavigationsToAppBoundDomains,
              "the dead host is still covered by WKAppBoundDomains, so Service Workers stay available")
        config.setURLSchemeHandler(OfflineSchemeHandler(shellRoot: shellRoot),
                                   forURLScheme: OfflineSchemeHandler.scheme)
        let secure = ApiSchemeHandler.registerAsSecureScheme(in: config, scheme: OfflineSchemeHandler.scheme)
        check(secure, "WebKit still accepts \(OfflineSchemeHandler.scheme) being marked a secure scheme")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadSimulatedRequest(URLRequest(url: origin), responseHTML: html)
        pump(20) { webView.url != nil && !webView.isLoading }

        // (1) The origin the whole design rests on — synthesized, with nothing behind it.
        let context = evaluate(webView, """
          return location.origin + ' | baseURI=' + document.baseURI + ' | secure=' + window.isSecureContext;
        """)
        print("document:     \(context)")
        check(context == "\(origin.absoluteString) | baseURI=\(origin.absoluteString)/ | secure=true",
              "loadSimulatedRequest puts the document on the requested origin, with that baseURI, secure")

        // (3) and (2): the script was fetched over the scheme AND ran in the https realm.
        // It reports `location.origin`, which is the document's, not the scheme's — a
        // classic script runs in its document's realm wherever its bytes came from.
        let booted = evaluate(webView, "return String(window.__shellBooted);")
        print("script:       window.__shellBooted = \(booted)")
        check(booted == origin.absoluteString,
              "the dobby-offline: script executed, in the https document's own realm (#151's never-paired path)")

        // (4) The stylesheet applied, which it only does when served as text/css.
        let styled = evaluate(webView, """
          return getComputedStyle(document.body).getPropertyValue('--shell-booted').trim() || '<unset>';
        """)
        print("stylesheet:   --shell-booted = \(styled)")
        check(styled == "42", "the dobby-offline: stylesheet was applied (so its Content-Type was text/css)")

        // The control that makes the three above mean what they say: the network really is
        // dead, so nothing above can have come from a server. This is the never-paired box.
        let network = evaluate(webView, """
          try { const r = await fetch('/js/01-state-init.js'); return 'status ' + r.status; }
          catch (e) { return 'error ' + e.name; }
        """, timeout: 30)
        print("network:      same-origin fetch('/js/01-state-init.js') -> \(network)")
        check(network.hasPrefix("error "),
              "the origin genuinely has no server behind it — a same-origin sub-resource fetch fails")

        // The open question, REPORTED not asserted: can a never-paired simulated document
        // register sw.js when the registration fetch has nowhere to go? A shell whose
        // sub-resources are on the scheme does not need it to boot, but the answer decides
        // whether such a box can ever gain offline caching.
        let swAvailable = evaluate(webView, "return String('serviceWorker' in navigator);")
        print("sw api:       'serviceWorker' in navigator = \(swAvailable)")
        if swAvailable == "true" {
            let registration = evaluate(webView, """
              try { const r = await navigator.serviceWorker.register('/sw.js'); return 'registered scope ' + r.scope; }
              catch (e) { return 'rejected ' + e.name + ': ' + e.message; }
            """, timeout: 40)
            print("sw register:  navigator.serviceWorker.register('/sw.js') -> \(registration)")
        } else {
            print("sw register:  NOT MEASURED — navigator.serviceWorker is unavailable in this host")
        }

        try? FileManager.default.removeItem(at: shellRoot)
        print(failures == 0 ? "BundledShellWebViewCheck: all good" : "BundledShellWebViewCheck: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
