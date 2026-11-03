import Foundation
import WebKit

/// JS injected at document start. Advertises the native bridge to the web app.
///
/// `canPlayNative` gates the playback handoff: while false (phase 1 skeleton) the web
/// app keeps using its own `<video>` element, so the wrapper is verified end-to-end
/// before native playback exists. Phase 2 flips it to true once KSPlayer is wired.
enum BridgeInjection {
    static let canPlayNative = true

    /// #197: only the iOS build installs the left-edge recognizer (WebContainer.makeWebView).
    #if os(iOS)
    static let edgeBack = true
    #else
    static let edgeBack = false
    #endif

    /// #483: `window.Dobby.onDeviceSearch`, the PWA's switch for the on-device lanes (`apiUrlFor`,
    /// #484). WebContainer sets it from `PythonRuntime.bundled` before the first injection and takes
    /// it back through `withdrawOnDeviceSearch` if the interpreter then fails to start, so it stays
    /// true only while `PythonRuntime.shared` is non-nil, without the main thread ever starting Python.
    static var onDeviceSearch = false

    /// #486: what openExternal may open: an https link with a host, posted by the app page's main frame (a sub-frame
    /// reaches the message handler too). nil refuses it. No host list: this repo names no server.
    static func externalURL(_ payload: Any?, mainFrame: Bool) -> URL? {
        guard mainFrame, let text = payload as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// #483: the interpreter would not start. The page's live flag and every later injection go false.
    static func withdrawOnDeviceSearch(from webView: WKWebView?) {
        onDeviceSearch = false
        guard let webView else { return }
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(userScript())
        webView.evaluateJavaScript("if (window.Dobby) window.Dobby.onDeviceSearch = false;")
    }

    /// What `WebContainer` installs, and what `withdrawOnDeviceSearch` re-installs.
    static func userScript() -> WKUserScript {
        WKUserScript(source: script(), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static func script() -> String {
        """
        (function () {
          if (window.Dobby) return;
          var post = function (action, payload) {
            try {
              window.webkit.messageHandlers.dobby.postMessage({ action: action, payload: payload });
            } catch (e) { console.warn('Dobby bridge post failed', e); }
          };
          window.Dobby = {
            platform: 'native',
            version: '0.1',
            canPlayNative: \(canPlayNative ? "true" : "false"),
            // #483: this build answers the search and subtitle routes itself (dobby-api://streaming, ://subtitles).
            onDeviceSearch: \(onDeviceSearch ? "true" : "false"),
            // Audio is routed to a car head unit. Pushed by the wrapper on every
            // route change (and once after 'ready'); read it, don't set it.
            isCarAudio: false,
            // #197: the wrapper's left-edge swipe sends Back itself (WebBridge.edgeBack), so
            // the PWA's own flick handler leaves touches that start at the edge alone.
            edgeBack: \(edgeBack ? "true" : "false"),
            // #181, #508: the Pi is retired, so the answer is always no. The PWA reads it
            // (piEnabledBridge in js/12-service-worker-offline.js) to keep every Pi route closed.
            // The no-op setter keeps the pair the PWA requires (both, or it reads no bridge as Pi on).
            piEnabled: function () { return false; },
            setPiEnabled: function () {},
            playNative: function (json) { post('playNative', json); },
            attachSubtitle: function (json) { post('attachSubtitle', json); },
            setSubtitleCatalog: function (json) { post('setSubtitleCatalog', json); },
            setSubtitleOffsetMs: function (ref, ms) { post('setSubtitleOffsetMs', { ref: ref, ms: ms }); },
            stop: function (ref) { post('stop', { ref: ref }); },
            // Now Playing state for the web-driven audiobook lane, so it also gets a
            // Live Activity (lock screen / Dynamic Island / CarPlay Dashboard). Native
            // playback pushes its own; call this only for <audio>-element playback.
            // { title, subtitle, elapsed, duration, isPlaying, ended }
            setNowPlaying: function (json) { post('setNowPlaying', json); },
            openTvLink: function () { post('openTvLink', null); },
            openExternal: function (url) { post('openExternal', url); },
            // Offline downloads. list/get are synchronous reads of a native-pushed cache.
            // #243: a tab or Offline Books pass that ran before this push read an empty cache,
            // so the push re-renders; an older PWA without the function is skipped. Only when the
            // finished set (complete entries by id, cover and meta, the #210 backfill) changes:
            // every saveIndex pushes, and each re-render shuts an open Offline Books group.
            _offline: [],
            _setOffline: function (arr) {
              var done = function (a) { return a.filter(function (e) { return e && e.status === 'complete'; }).map(function (e) { return [e.id, e.cover || '', e.meta || ''].join('\\t'); }).sort().join('\\n'); };
              var before = done(this._offline);
              this._offline = Array.isArray(arr) ? arr : [];
              if (done(this._offline) !== before && typeof window.refreshOfflineBooksSection === 'function') window.refreshOfflineBooksSection();
            },
            downloadNativeOffline: function (json) { post('downloadNativeOffline', json); },
            downloadNativeBook: function (json) { post('downloadNativeBook', json); },
            removeNativeOffline: function (id) { post('removeNativeOffline', id); },
            cancelNativeOfflineDownload: function (id) { post('cancelNativeOfflineDownload', id); },
            // Offline playback URL for a natively-downloaded file (custom scheme; the
            // https page can't load file://). Segments are percent-encoded.
            offlineFileURL: function (id, name) {
              return 'dobby-offline:///' + encodeURIComponent(id) + '/' + encodeURIComponent(name);
            },
            listNativeOffline: function () { return JSON.stringify(this._offline || []); },
            getNativeOffline: function (id) {
              var l = this._offline || [];
              for (var i = 0; i < l.length; i++) { if (l[i] && l[i].videoId === id) return JSON.stringify(l[i]); }
              return '';
            }
          };
          console.log('Dobby native bridge injected (canPlayNative=' + window.Dobby.canPlayNative + ')');
          post('ready', { canPlayNative: window.Dobby.canPlayNative, ua: navigator.userAgent });
        })();
        """
    }
}
