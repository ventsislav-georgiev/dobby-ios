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

    fileprivate func makeWebView(_ coordinator: WebBridge) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // Opt into App-Bound Domains (see WKAppBoundDomains in Info.plist) so
        // Service Workers are available in the WKWebView — without this,
        // navigator.serviceWorker is undefined and the web hides offline download.
        config.limitsNavigationsToAppBoundDomains = true
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
