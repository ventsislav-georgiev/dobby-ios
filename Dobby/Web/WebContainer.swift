import SwiftUI
import WebKit

/// Cross-platform WKWebView host. Native macOS + iOS share this; only the
/// representable conformance differs.
struct WebContainer {
    let url: URL
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
        ucc.addUserScript(WKUserScript(
            source: BridgeInjection.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = ucc

        // Serve natively-downloaded offline files (the https page can't load file://).
        config.setURLSchemeHandler(OfflineSchemeHandler(), forURLScheme: OfflineSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        #if os(iOS)
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        #endif
        coordinator.attach(webView: webView)
        webView.load(URLRequest(url: url))
        return webView
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
