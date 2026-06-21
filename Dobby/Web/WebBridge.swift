import Foundation
import WebKit

/// Receives web → native messages and forwards native → web callbacks.
/// One instance per WKWebView (the SwiftUI representable Coordinator).
final class WebBridge: NSObject {
    private let playback: PlaybackCoordinator
    private let offline: OfflineStore
    private(set) weak var webView: WKWebView?

    init(playback: PlaybackCoordinator, offline: OfflineStore) {
        self.playback = playback
        self.offline = offline
        super.init()
    }

    @MainActor
    func attach(webView: WKWebView) {
        self.webView = webView
        playback.bridge = self
        offline.activate()   // create bg session + reclaim downloads from a prior launch
        offline.pushIndex = { [weak self] json in
            self?.callJS("window.Dobby && window.Dobby._setOffline(\(json));")
        }
        offline.reportProgress = { [weak self] json in
            self?.callJS("window.bookPlayNativeDownloadProgress && window.bookPlayNativeDownloadProgress(\(json));")
        }
    }

    /// Evaluate a JS expression in the web app (native → web callback).
    func callJS(_ js: String) {
        guard let webView else { return }
        if Thread.isMainThread {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            DispatchQueue.main.async { webView.evaluateJavaScript(js, completionHandler: nil) }
        }
    }
}

// MARK: - Web → Native

extension WebBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == AppConfig.bridgeName,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        let payload = body["payload"]

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.dispatch(action: action, payload: payload) }
        }
    }

    @MainActor
    private func dispatch(action: String, payload: Any?) {
        switch action {
        case "ready":
            NSLog("%@", "Dobby ready bridge \(String(describing: payload))")
            callJS("window.Dobby && window.Dobby._setOffline(\(offline.indexJSON()));")
            // Headless e2e: DOBBY_SELFTEST_URL drives the real web→playNative→decode path.
            if let u = ProcessInfo.processInfo.environment["DOBBY_SELFTEST_URL"] {
                let json = "{\"ref\":\"selftest\",\"url\":\"\(u)\",\"title\":\"selftest\"}"
                if let req = PlayNativePayload.decode(json) { playback.play(req) }
            }
        case "downloadNativeOffline":
            if let json = payload as? String { offline.startDownload(json) }
        case "downloadNativeBook":
            if let json = payload as? String { offline.startBookDownload(json) }
        case "deleteNativeOffline":
            if let id = payload as? String { offline.delete(id) }
        case "cancelNativeOfflineDownload":
            if let id = payload as? String { offline.cancel(id) }
        case "playNative":
            guard let json = payload as? String,
                  let req = PlayNativePayload.decode(json) else {
                NSLog("%@", "Dobby: playNative bad payload: \(String(describing: payload))")
                return
            }
            playback.play(req)
        case "attachSubtitle":
            if let json = payload as? String { playback.attachSubtitle(json) }
        case "setSubtitleOffsetMs":
            if let dict = payload as? [String: Any],
               let ref = dict["ref"] as? String,
               let ms = (dict["ms"] as? NSNumber)?.intValue {
                playback.setSubtitleOffset(ref: ref, ms: ms)
            }
        case "stop":
            playback.stop()
        default:
            NSLog("%@", "Dobby: unhandled bridge action \(action)")
        }
    }
}

// MARK: - UI panels (JS alert/confirm/prompt)
// WKWebView drops these unless a WKUIDelegate is set — confirm() returns false,
// silently breaking the app's confirm dialogs (e.g. "remove offline download").

#if os(iOS)
import UIKit

extension WebBridge: WKUIDelegate {
    private func topVC() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
        var vc = root
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let vc = topVC() else { completionHandler(); return }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        vc.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let vc = topVC() else { completionHandler(false); return }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        vc.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let vc = topVC() else { completionHandler(defaultText); return }
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        vc.present(a, animated: true)
    }
}
#else
import AppKit

extension WebBridge: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK")
        a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.stringValue = defaultText ?? ""
        a.accessoryView = tf
        completionHandler(a.runModal() == .alertFirstButtonReturn ? tf.stringValue : nil)
    }
}
#endif

// MARK: - Navigation (kept minimal; log failures)

extension WebBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("%@", "Dobby: navigation failed: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("%@", "Dobby: provisional navigation failed: \(error.localizedDescription)")
    }
}
