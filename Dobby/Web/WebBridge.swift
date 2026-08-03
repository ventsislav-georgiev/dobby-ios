import Foundation
import WebKit

/// Receives web → native messages and forwards native → web callbacks.
/// One instance per WKWebView (the SwiftUI representable Coordinator).
final class WebBridge: NSObject {
    private let playback: PlaybackCoordinator
    private let offline: OfflineStore
    private(set) weak var webView: WKWebView?

    /// Title the web audiobook lane last reported — a change means a new item.
    private var webNowPlayingTitle: String?

    init(playback: PlaybackCoordinator, offline: OfflineStore) {
        self.playback = playback
        self.offline = offline
        super.init()
    }

    @MainActor
    func attach(webView: WKWebView) {
        self.webView = webView
        playback.bridge = self
        playback.carRoute.onChange = { [weak self] isCar in self?.pushCarRoute(isCar) }
        // `deliver` is wired on `ready`, not here: a command handed over while the
        // page is still loading has nothing to run it and would vanish.
        VoiceCommandQueue.shared.deliver = nil
        offline.activate()   // create bg session + reclaim downloads from a prior launch
        offline.pushIndex = { [weak self] json in
            self?.callJS("window.Dobby && window.Dobby._setOffline(\(json));")
        }
        offline.reportProgress = { [weak self] json in
            self?.callJS("window.bookPlayNativeDownloadProgress && window.bookPlayNativeDownloadProgress(\(json));")
        }
    }

    /// Tell the web app the audio route entered/left a car head unit, so it can drop
    /// into a car-friendly mode (no CarPlay entitlement is involved — this is just
    /// the audio route). Latched on `window.Dobby` so late readers see it too.
    private func pushCarRoute(_ isCar: Bool) {
        callJS("window.Dobby && (window.Dobby.isCarAudio = \(isCar));"
             + "window.bookPlayNativeAudioRoute && window.bookPlayNativeAudioRoute({car:\(isCar)});")
    }

    /// Hand a Siri command to the web app (see `js/23-voice.js`).
    private func pushVoiceCommand(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window.bookPlayNativeVoiceCommand && window.bookPlayNativeVoiceCommand(\(json));")
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
            pushCarRoute(playback.carRoute.isCar)   // page reload lost the latched value
            // Siri may have launched us with a command; the page can run it now.
            VoiceCommandQueue.shared.deliver = { [weak self] command in self?.pushVoiceCommand(command) }
            VoiceCommandQueue.shared.flush()
            // Headless e2e: DOBBY_SELFTEST_URL drives the real web→playNative→decode path.
            if let u = ProcessInfo.processInfo.environment["DOBBY_SELFTEST_URL"] {
                // artist/album/poster included so the Now Playing merge path is
                // exercised too, not just decode-and-open.
                let env = ProcessInfo.processInfo.environment
                let poster = env["DOBBY_SELFTEST_POSTER"] ?? ""
                let json = """
                {"ref":"selftest","url":"\(u)","title":"selftest",\
                "artist":"selftest artist","album":"selftest album","poster":"\(poster)"}
                """
                if let req = PlayNativePayload.decode(json) { playback.play(req) }
            }
        // Web app pushes the canonical address list (Settings → Dobby server
        // addresses) on every load. Cached so the next cold start finds the server
        // on a different network without anyone touching a setting.
        case "setServerAddresses":
            if let json = payload as? String { ServerAddresses.store(json: json) }
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
        case "setSubtitleCatalog":
            if let json = payload as? String { playback.setSubtitleCatalog(json) }
        case "setSubtitleOffsetMs":
            if let dict = payload as? [String: Any],
               let ref = dict["ref"] as? String,
               let ms = (dict["ms"] as? NSNumber)?.intValue {
                playback.setSubtitleOffset(ref: ref, ms: ms)
            }
        case "stop":
            playback.stop()
        case "setNowPlaying":
            #if os(iOS)
            guard let json = payload as? String,
                  let data = json.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if d["ended"] as? Bool == true { NowPlayingActivity.shared.end(); return }
            let title = d["title"] as? String ?? "Dobby"
            let subtitle = d["subtitle"] as? String ?? ""
            let elapsed = (d["elapsed"] as? NSNumber)?.doubleValue ?? 0
            let duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
            let playing = d["isPlaying"] as? Bool ?? false
            // A new title means a new item — restart rather than update, so the
            // dashboard card doesn't keep the previous book's timeline.
            if webNowPlayingTitle != title {
                webNowPlayingTitle = title
                NowPlayingActivity.shared.start(title: title, subtitle: subtitle, kind: "book",
                                                elapsed: elapsed, duration: duration, isLive: false)
            } else {
                NowPlayingActivity.shared.update(title: title, subtitle: subtitle,
                                                 elapsed: elapsed, duration: duration,
                                                 isLive: false, isPlaying: playing)
            }
            #endif
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
