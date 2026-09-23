import Foundation
import WebKit

/// JS injected at document start. Advertises the native bridge to the web app.
///
/// `canPlayNative` gates the playback handoff: while false (phase 1 skeleton) the web
/// app keeps using its own `<video>` element, so the wrapper is verified end-to-end
/// before native playback exists. Phase 2 flips it to true once KSPlayer is wired.
enum BridgeInjection {
    static let canPlayNative = true

    /// What `WebContainer` installs, and what `WebBridge` re-installs after the page flips
    /// the Pi setting, so a reload reads the new value rather than the launch one.
    static func userScript() -> WKUserScript {
        WKUserScript(source: script(piEnabled: ServerAddresses.piEnabled()),
                     injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// #181: `piEnabled` is the "Use a Pi server" answer at injection time. WKWebView has
    /// no synchronous JS-to-native call and the PWA's gate (`piEnabledBridge()` in
    /// js/12-service-worker-offline.js) calls `piEnabled()` synchronously, so the value
    /// rides in the literal; `setPiEnabled` updates it in place before posting, so the
    /// page's own re-probe right after the save already reads the new answer.
    static func script(piEnabled: Bool) -> String {
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
            // Audio is routed to a car head unit. Pushed by the wrapper on every
            // route change (and once after 'ready'); read it, don't set it.
            isCarAudio: false,
            setServerAddresses: function (json) { post('setServerAddresses', json); },
            // #181 "Use a Pi server". The PWA shows its settings row only when BOTH of
            // these are functions; piEnabled() must answer synchronously.
            _piEnabled: \(piEnabled ? "true" : "false"),
            piEnabled: function () { return this._piEnabled === true; },
            setPiEnabled: function (on) { this._piEnabled = on === true; post('setPiEnabled', this._piEnabled); },
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
            // Offline downloads. list/get are synchronous reads of a native-pushed cache.
            _offline: [],
            _setOffline: function (arr) { this._offline = Array.isArray(arr) ? arr : []; },
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
