import Foundation
import WebKit

/// The web view's navigation delegate and the one place the bundled shell is loaded (#540).
///
/// Its own object rather than a WebBridge extension so `Tests/WebContentTerminationWebViewCheck.swift`
/// runs the shipped load and the shipped termination handler without the rest of the bridge.
final class ShellNavigation: NSObject, WKNavigationDelegate {
    /// At most this many reloads in `window` seconds; past that a crashing page stays down
    /// instead of spinning the WebContent process in a loop.
    static let maxReloads = 3
    static let window: TimeInterval = 60

    /// #614: the launch cover's release (ContentView), called once. The Android TV rule (MainActivity.awaitPaint,
    /// #458): after the page finishes, poll `window.dobbyPainted` (js/26-skins.js: the boot restore settled and its
    /// window drawn) and hold only while it reads false, at most `paintWait`; anything else releases at once.
    /// `loadWait` from the first load covers a page that never finishes.
    var onPainted: (() -> Void)?
    var paintWait: TimeInterval = 6
    var loadWait: TimeInterval = 15
    static let paintPoll: TimeInterval = 0.1
    private var paintDeadline: Date?

    private let shellRoot: URL?
    /// The first URL `load` was given, the reload target when the page's own URL is unusable.
    private var shellURL: URL?
    private(set) var reloads: [Date] = []

    init(shellRoot: URL? = BundledShell.root) {
        self.shellRoot = shellRoot
        super.init()
    }

    /// The bundled shell, *synthesized under the origin* by `loadSimulatedRequest`.
    ///
    /// The origin is the whole point and is why this is not `loadHTMLString` or a
    /// `file://` load. #150 measured that the simulated document lands in the REAL
    /// storage partition for that origin — `location.origin`, `document.baseURI` and
    /// `isSecureContext` all report the Pi, and the localStorage/IndexedDB/Cache Storage
    /// a previous *networked* load of the Pi wrote read back inside it. So progress,
    /// bookmarks, the gallery cache and the service worker are the ones the app already
    /// has, and no cross-origin migration is needed (§9 option (b) is off the table for
    /// iOS because of this). #508: ContentView shows WebContainer only when the build has
    /// a shell, so there is no network fallback here.
    func load(_ loadURL: URL, in webView: WKWebView) {
        if shellURL == nil {
            shellURL = loadURL
            DispatchQueue.main.asyncAfter(deadline: .now() + loadWait) { [weak self] in self?.releaseLaunch("no page") }
        }
        guard let html = BundledShell.indexHTML(root: shellRoot) else { return }
        webView.loadSimulatedRequest(URLRequest(url: loadURL), responseHTML: html)
    }

    /// #540: iOS kills the WebContent process under memory pressure (the native player decoding
    /// beside it) and the page goes white for good unless the app loads it again. `reload()` would
    /// not do: the document is synthesized, so the shell load runs again, on the page's current
    /// URL. Its hash is the PWA's route, and with `bp_last_route` matching it the PWA restores the
    /// view and back stack (js/00-router.js restoreSession). The user scripts, message handlers
    /// and content rule list live in the configuration and come back with the new process.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let shellURL else { return }   // nothing loaded yet; the first load is still on its way
        let now = Date()
        reloads.removeAll { now.timeIntervalSince($0) >= Self.window }
        guard reloads.count < Self.maxReloads else {
            NSLog("%@", "Dobby: web content process terminated \(reloads.count + 1) times in a minute, not reloading the shell")
            return
        }
        reloads.append(now)
        NSLog("%@", "Dobby: web content process terminated, reloading shell")
        load(Self.sameOrigin(webView.url, as: shellURL) ?? shellURL, in: webView)
    }

    /// `url` when it is on the shell's origin, else nil: the reload never synthesizes the shell
    /// under any other origin.
    static func sameOrigin(_ url: URL?, as shell: URL) -> URL? {
        guard let url, url.scheme == shell.scheme, url.host == shell.host, url.port == shell.port else { return nil }
        return url
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard onPainted != nil, paintDeadline == nil else { return }
        paintDeadline = Date().addingTimeInterval(paintWait)
        pollPaint(webView)
    }

    private func pollPaint(_ webView: WKWebView) {
        webView.evaluateJavaScript("window.dobbyPainted") { [weak self, weak webView] painted, _ in
            guard let self, let deadline = self.paintDeadline else { return }
            if let webView, Self.launchHolds(painted, timedOut: Date() >= deadline) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.paintPoll) { self.pollPaint(webView) }
                return
            }
            self.releaseLaunch("painted=\(painted.map { "\($0)" } ?? "nil")")
        }
    }

    /// Android's launchHolds: only an explicit false with time left holds; true, an older page's
    /// undefined or a failed read releases.
    static func launchHolds(_ painted: Any?, timedOut: Bool) -> Bool {
        (painted as? Bool) == false && !timedOut
    }

    private func releaseLaunch(_ why: String) {
        guard let release = onPainted else { return }
        onPainted = nil
        let after = paintDeadline.map { String(format: "%.0f", (Date().timeIntervalSince($0) + paintWait) * 1000) } ?? "-"
        NSLog("%@", "Dobby: launch cover off: \(why) afterMs=\(after)")
        release()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("%@", "Dobby: navigation failed: \(error.localizedDescription)")
        releaseLaunch("load failed")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("%@", "Dobby: provisional navigation failed: \(error.localizedDescription)")
        releaseLaunch("load failed")
    }
}
