import SwiftUI
import WebKit

/// Cross-platform WKWebView host. Native macOS + iOS share this; only the
/// representable conformance differs.
struct WebContainer {
    /// #508: the origin the bundled shell is synthesized under (ServerAddresses.origin()), never fetched.
    let url: URL
    @EnvironmentObject var playback: PlaybackCoordinator
    @EnvironmentObject var offline: OfflineStore

    func makeCoordinator() -> WebBridge {
        WebBridge(playback: playback, offline: offline)
    }

    /// True when `url`'s host is covered by WKAppBoundDomains (the entry matches the
    /// host or a suffix of it). LAN IPs never are — that list only takes domains.
    /// #245: the one predicate, shared with ServerAddresses' iOS origin rule.
    static func isAppBound(_ url: URL) -> Bool {
        ServerAddresses.AppBound.current.covers(url)
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

        // #483: advertised from the bundle (a file check, no interpreter start on main), then taken
        // back below if the interpreter will not start.
        BridgeInjection.onDeviceSearch = PythonRuntime.bundled
        let ucc = WKUserContentController()
        ucc.add(coordinator, name: AppConfig.bridgeName)
        ucc.addUserScript(BridgeInjection.userScript())
        config.userContentController = ucc

        // Serve natively-downloaded offline files (the https page can't load file://).
        config.setURLSchemeHandler(OfflineSchemeHandler(), forURLScheme: OfflineSchemeHandler.scheme)
        // The page addresses this one explicitly (js/01-state-init.js, `apiUrlFor`) for
        // GET /api/settings and /api/proxy. `url` only names the page's origin for its
        // Access-Control-Allow-Origin answers; nothing is fetched from it (#508).
        config.setURLSchemeHandler(ApiSchemeHandler(server: url), forURLScheme: ApiSchemeHandler.scheme)
        // #483: the on-device lanes on that scheme, and the offline sidecars they cache.
        ApiSchemeHandler.onDeviceLane = OnDeviceLane.answer
        OfflineStore.laneSidecar = OnDeviceLane.sidecarFile
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
        // page with nothing logged.
        ApiSchemeHandler.registerAsSecureScheme(in: config, scheme: OfflineSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        if BridgeInjection.onDeviceSearch {
            PythonRuntime.warmUp { [weak webView] in BridgeInjection.withdrawOnDeviceSearch(from: webView) }
        }
        webView.navigationDelegate = coordinator.navigation
        webView.uiDelegate = coordinator
        #if os(iOS)
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        // #197: a left-edge swipe is the Android TV Back key. Not the WebKit history gesture
        // above: most views (settings, pickers, the web player, books) push no history entry,
        // and Android Back is the page's Escape keydown, not history.back (WebBridge.edgeBack).
        let edgeBack = UIScreenEdgePanGestureRecognizer(target: coordinator, action: #selector(WebBridge.edgeBack(_:)))
        edgeBack.edges = .left
        webView.addGestureRecognizer(edgeBack)
        #endif
        coordinator.attach(webView: webView)
        var loadURL = url
        #if DEBUG
        // #116 device round 3 test seam: DOBBY_START_PATH opens a route at launch
        // (see AppConfig.startURL) so a series detail page can be reached headlessly.
        loadURL = AppConfig.startURL(origin: url)
        #endif
        // #181, #508: nothing the page asks for may reach its origin, which is the retired Pi's
        // name. The lever is a content rule list, in place before the page asks for anything.
        Task { @MainActor in
            await PiRequestBlock.install(in: ucc, origin: url)
            coordinator.navigation.load(loadURL, in: webView)
        }
        return webView
    }
}

/// #181, #508: nothing the page asks for may reach the origin it is on (the retired Pi's name)
/// — `/sw.js`, `/api/…`, the icons. The shell itself is a simulated document and its
/// scripts come over `dobby-offline:`, so neither is a load this rule sees.
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
        NSLog("%@", "Dobby: requests to the page origin blocked")
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
