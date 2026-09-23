import SwiftUI
import WebKit

/// Cross-platform WKWebView host. Native macOS + iOS share this; only the
/// representable conformance differs.
struct WebContainer {
    let url: URL
    /// #151: no address answered, so the app comes up out of its own bundle instead of
    /// off the Pi — the analogue of Android's `loadBundledShell()`. See `load(_:in:)`.
    var offlineShell = false
    @EnvironmentObject var playback: PlaybackCoordinator
    @EnvironmentObject var offline: OfflineStore

    func makeCoordinator() -> WebBridge {
        WebBridge(playback: playback, offline: offline)
    }

    /// True when `url`'s host is covered by WKAppBoundDomains (the entry matches the
    /// host or a suffix of it). LAN IPs never are — that list only takes domains.
    static func isAppBound(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              let domains = Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") as? [String]
        else { return false }
        return domains.contains { domain in
            let d = domain.lowercased()
            return host == d || host.hasSuffix("." + d)
        }
    }

    fileprivate func makeWebView(_ coordinator: WebBridge) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // Opt into App-Bound Domains (see WKAppBoundDomains in Info.plist) so
        // Service Workers are available in the WKWebView — without this,
        // navigator.serviceWorker is undefined and the web hides offline download.
        // WKAppBoundDomains is a static Info.plist list that cannot hold a
        // user-configured LAN address, and opting in would block navigating to
        // one, so the opt-in only applies when the resolved origin is listed.
        config.limitsNavigationsToAppBoundDomains = WebContainer.isAppBound(url)
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        // Appends " Dobby/0.1" to the default UA → web wrapper detection.
        config.applicationNameForUserAgent = AppConfig.userAgentSuffix

        let ucc = WKUserContentController()
        ucc.add(coordinator, name: AppConfig.bridgeName)
        ucc.addUserScript(BridgeInjection.userScript())
        config.userContentController = ucc

        // Serve natively-downloaded offline files (the https page can't load file://).
        config.setURLSchemeHandler(OfflineSchemeHandler(), forURLScheme: OfflineSchemeHandler.scheme)
        // The page addresses this one explicitly (js/01-state-init.js, `apiUrlFor`) for
        // GET /api/settings and /api/proxy — the two paths that must survive the Pi
        // being off. `url` and not AppConfig.serverURL: the refresh belongs on whichever
        // address actually answered.
        config.setURLSchemeHandler(ApiSchemeHandler(server: url), forURLScheme: ApiSchemeHandler.scheme)
        // Before the first WKWebView is created — the safe order, not a required one
        // (registering after the WKWebView, or even after its load completes, measured
        // green too), so it cannot be missed by a WebView created later. Over https
        // (every Tailscale address, and the only one the Mac has) the page's
        // dobby-api: fetches are otherwise blockable mixed content, refused before the
        // handler is called — #067, see ApiSchemeHandler.registerAsSecureScheme.
        ApiSchemeHandler.registerAsSecureScheme(in: config)
        // #151, same SPI and the same reason, for the other scheme an https document has to
        // address: the bundled shell's `<script src="dobby-offline://shell/js/…">` tags are
        // blockable mixed content until this lands, and a blocked classic script is a blank
        // page with nothing logged. Harmless when the Pi is up — nothing addresses the
        // scheme until `offlineShell` puts a simulated document on the screen.
        ApiSchemeHandler.registerAsSecureScheme(in: config, scheme: OfflineSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        #if os(iOS)
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        #endif
        coordinator.attach(webView: webView)
        var loadURL = url
        #if DEBUG
        // #116 device round 3 test seam: DOBBY_START_PATH opens a route at launch
        // (see AppConfig.startURL) so a series detail page can be reached headlessly.
        loadURL = AppConfig.startURL(origin: url)
        #endif
        // #181: Android's ApiInterceptor refuses every request to the server origin while
        // the Pi is disabled; the iOS lever is a content rule list, and it has to be in
        // place before the first byte of the page asks for anything.
        guard !ServerAddresses.piEnabled() else {
            load(loadURL, in: webView)
            return webView
        }
        Task { @MainActor in
            await PiRequestBlock.install(in: ucc, origin: url)
            load(loadURL, in: webView)
        }
        return webView
    }

    /// Pi-backed: an ordinary request to the origin that answered. Pi-less: the bundled
    /// shell, *synthesized under that same origin* by `loadSimulatedRequest`.
    ///
    /// The origin is the whole point and is why this is not `loadHTMLString` or a
    /// `file://` load. #150 measured that the simulated document lands in the REAL
    /// storage partition for that origin — `location.origin`, `document.baseURI` and
    /// `isSecureContext` all report the Pi, and the localStorage/IndexedDB/Cache Storage
    /// a previous *networked* load of the Pi wrote read back inside it. So progress,
    /// bookmarks, the gallery cache and the service worker are the ones the app already
    /// has, and no cross-origin migration is needed (§9 option (b) is off the table for
    /// iOS because of this).
    ///
    /// No shell in this build → the ordinary load, which is exactly what "Continue
    /// offline" did before #151 and still the right behaviour on a box that has paired:
    /// nothing answers, but the service worker's cache is keyed to this origin.
    /// Same three-outcome shape as Android's `loadBundledShell()` returning false.
    private func load(_ loadURL: URL, in webView: WKWebView) {
        guard offlineShell, let html = BundledShell.indexHTML() else {
            webView.load(URLRequest(url: loadURL))
            return
        }
        webView.loadSimulatedRequest(URLRequest(url: loadURL), responseHTML: html)
    }
}

/// #181: with the Pi turned off, nothing the page asks for may reach the origin it is
/// on — the probe, `/sw.js`, `/api/…`, the icons. The Pi-less shell itself is a simulated
/// document and its scripts come over `dobby-offline:`, so neither is a load this rule sees.
enum PiRequestBlock {
    /// url-filter is a regex over the whole URL: this host, any scheme, any port.
    static func rules(for origin: URL) -> String? {
        guard let host = origin.host, !host.isEmpty else { return nil }
        let filter = "^https?://" + NSRegularExpression.escapedPattern(for: host) + "[:/]"
        let rules: [[String: Any]] = [["trigger": ["url-filter": filter], "action": ["type": "block"]]]
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @MainActor
    static func install(in ucc: WKUserContentController, origin: URL) async {
        guard let json = rules(for: origin),
              let list = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "dobby.pi-disabled", encodedContentRuleList: json) else {
            NSLog("%@", "Dobby: Pi request block failed to compile")
            return
        }
        ucc.add(list)
        NSLog("%@", "Dobby: Pi disabled by the user setting; requests to the page origin blocked")
    }
}

#if os(macOS)
extension WebContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension WebContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
