import Foundation

/// JS injected at document start. Advertises the native bridge to the web app.
///
/// `canPlayNative` gates the playback handoff: while false (phase 1 skeleton) the web
/// app keeps using its own `<video>` element, so the wrapper is verified end-to-end
/// before native playback exists. Phase 2 flips it to true once KSPlayer is wired.
enum BridgeInjection {
    static let canPlayNative = true

    static var script: String {
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
            playNative: function (json) { post('playNative', json); },
            attachSubtitle: function (json) { post('attachSubtitle', json); },
            setSubtitleOffsetMs: function (ref, ms) { post('setSubtitleOffsetMs', { ref: ref, ms: ms }); },
            stop: function (ref) { post('stop', { ref: ref }); },
            // Offline downloads. list/get are synchronous reads of a native-pushed cache.
            _offline: [],
            _setOffline: function (arr) { this._offline = Array.isArray(arr) ? arr : []; },
            downloadNativeOffline: function (json) { post('downloadNativeOffline', json); },
            downloadNativeBook: function (json) { post('downloadNativeBook', json); },
            deleteNativeOffline: function (id) { post('deleteNativeOffline', id); },
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
