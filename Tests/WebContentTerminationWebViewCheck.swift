import AppKit
import Foundation
import WebKit

// #540: when the WebContent process dies (iOS reclaims it under memory pressure while the native
// player decodes, or it crashes) the page goes white and stays white unless the navigation
// delegate loads the shell again. This drives the shipped ShellNavigation in a real WKWebView:
// the shell is loaded through its `load`, the process is killed, and the page must come back
// live, on the same route, with the user script and the message handler working again.
//
// Two ways to kill it: `_killWebContentProcess` (WebKit's testing SPI, used here only, never in
// the app) and SIGKILL to the process, which WebKit sees as a crash, the device's case.
// Then the loop guard: kills past ShellNavigation.maxReloads inside a minute are not reloaded.
//
// macOS only — `run-checks.sh` skips it elsewhere, same as the other WebView checks.
@main
enum WebContentTerminationWebViewCheck {
    private static let origin = URL(string: "https://shell-origin.example")!
    private static let route = "#title/tt0000001"

    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok  " : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    private static func pump(_ seconds: TimeInterval, _ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
    }

    private static func evaluate(_ webView: WKWebView, _ body: String, timeout: TimeInterval = 10) -> String {
        var out: String?
        webView.callAsyncJavaScript("return (async () => { \(body) })();", in: nil, in: .page) { result in
            switch result {
            case .success(let value): out = value as? String ?? "\(value)"
            case .failure(let error): out = "evaluate failed: \(error.localizedDescription)"
            }
        }
        pump(timeout) { out != nil }
        return out ?? "<timed out>"
    }

    /// Counts the user script's `ready` posts: one per document the bridge reached.
    final class Recorder: NSObject, WKScriptMessageHandler {
        var readies = 0
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if (message.body as? [String: Any])?["action"] as? String == "ready" { readies += 1 }
        }
    }

    private static func pid(_ webView: WKWebView) -> pid_t {
        (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }

    /// Never kill(0, …): that is this whole process group, the check runner included.
    private static func killWebContent(_ webView: WKWebView) {
        let target = pid(webView)
        check(target > 0, "the web view reports its WebContent pid (\(target))")
        if target > 0 { Darwin.kill(target, SIGKILL) }
    }

    private static func makeFixtureShell() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dobby-termination-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("js"),
                                                 withIntermediateDirectories: true)
        try? "<!DOCTYPE html><html><head><script src=\"/js/boot.js\"></script></head><body>shell</body></html>"
            .write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try? "window.__shellBooted = 'booted';"
            .write(to: root.appendingPathComponent("js/boot.js"), atomically: true, encoding: .utf8)
        return root
    }

    /// One kill: the delegate must reload, and the reloaded page must be the shell, live, on the
    /// route, with the bridge attached. `expectReload` false is the loop guard's give-up.
    private static func killAndCheck(_ how: String, _ webView: WKWebView, _ nav: ShellNavigation,
                                     _ recorder: Recorder, expectReload: Bool, kill: () -> Void) {
        let before = (pid: pid(webView), reloads: nav.reloads.count, readies: recorder.readies)
        kill()
        pump(10) { nav.reloads.count > before.reloads || (!expectReload && pid(webView) == 0) }
        if expectReload {
            pump(10) { recorder.readies > before.readies && !webView.isLoading }
            let state = evaluate(webView, "return [window.__shellBooted, location.origin, location.hash, String(window.__userScript)].join(' ');")
            print("\(how): pid \(before.pid) -> \(pid(webView)), reloads \(nav.reloads.count), readies \(recorder.readies), page: \(state)")
            check(nav.reloads.count == before.reloads + 1, "\(how): the delegate's termination handler reloaded once")
            check(pid(webView) != before.pid && pid(webView) != 0, "\(how): a new WebContent process hosts the page")
            check(state == "booted \(origin.absoluteString) \(route) 1",
                  "\(how): the page is live again, the shell's script ran on its origin, the route hash kept, the user script ran")
            check(recorder.readies == before.readies + 1, "\(how): the message handler received the reloaded page's post")
        } else {
            pump(3) { false }
            let state = evaluate(webView, "return String(window.__shellBooted);", timeout: 3)
            print("\(how): reloads \(nav.reloads.count), readies \(recorder.readies), page: \(state)")
            check(nav.reloads.count == before.reloads && recorder.readies == before.readies && state != "booted",
                  "\(how): past \(ShellNavigation.maxReloads) reloads in a minute the shell is not reloaded again")
        }
    }

    static func main() {
        _ = NSApplication.shared
        let shellRoot = makeFixtureShell()

        let config = WKWebViewConfiguration()
        let recorder = Recorder()
        let ucc = WKUserContentController()
        ucc.add(recorder, name: AppConfig.bridgeName)
        ucc.addUserScript(WKUserScript(source: """
          window.__userScript = (window.__userScript || 0) + 1;
          window.webkit.messageHandlers.\(AppConfig.bridgeName).postMessage({action: 'ready'});
          """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc
        config.setURLSchemeHandler(OfflineSchemeHandler(shellRoot: shellRoot), forURLScheme: OfflineSchemeHandler.scheme)
        ApiSchemeHandler.registerAsSecureScheme(in: config, scheme: OfflineSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        let nav = ShellNavigation(shellRoot: shellRoot)
        webView.navigationDelegate = nav
        nav.load(origin, in: webView)
        pump(20) { recorder.readies == 1 && !webView.isLoading }
        let hash = evaluate(webView, "history.replaceState(null, '', '\(route)'); return location.hash;")
        check(evaluate(webView, "return String(window.__shellBooted);") == "booted" && hash == route,
              "the shell loaded through ShellNavigation.load and the page set its route hash")

        // SIGKILL is what jetsam sends a WebContent process under memory pressure, and what a crash
        // amounts to. The private _killWebContentProcess was tried first and is no substitute: on
        // this host it leaves the process alive and never calls the delegate (#540).
        for n in 0..<ShellNavigation.maxReloads {
            killAndCheck("SIGKILL #\(n + 1)", webView, nav, recorder, expectReload: true) {
                killWebContent(webView)
            }
        }
        killAndCheck("SIGKILL past the limit", webView, nav, recorder, expectReload: false) {
            killWebContent(webView)
        }

        try? FileManager.default.removeItem(at: shellRoot)
        if failures > 0 {
            print("FAIL: \(failures) WebContent termination check(s) failed (#540)")
            exit(1)
        }
        print("PASS: a killed WebContent process reloads the bundled shell through ShellNavigation, live, on its route, "
              + "with the user script and message handler back, and stops after \(ShellNavigation.maxReloads) reloads a minute (#540)")
    }
}
