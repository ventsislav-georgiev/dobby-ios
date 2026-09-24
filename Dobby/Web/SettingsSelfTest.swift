#if DEBUG
import CryptoKit
import Foundation
import WebKit

/// Debug-only device seam (#149 iPhone round): prove the Pi-off settings write lane end to
/// end on a physical phone that nothing can tap. There is no touch injector for an iPhone
/// and no XCUITest target, so `DOBBY_SETTINGS_SELFTEST=<step>` runs one of three FIXED
/// steps in the page after it loads. The environment picks a step name out of the set
/// below and nothing else — no script, no value, no URL is ever read from it.
///
/// The setting is `preferredSubtitleLanguage`, the one a subtitle-track pick saves, and
/// the write goes through the page's own `savePreferredSubtitleLanguage` →
/// `mirroredWrite` → `apiUrlFor` → `dobby-api://settings` path, i.e. the same code a user
/// action runs. For the duration of a step the page's `fetch` refuses the Pi origin, so
/// the save's first leg fails the way it does with the Pi off and the wrapper leg is what
/// takes the write. The native half of "Pi removed" is `DOBBY_NO_SERVER=1`, which also
/// keeps `ApiSchemeHandler`'s own Pi legs off the network.
///
/// - `write`: stash the current value in page localStorage (refusing if one is already
///   stashed, so a rerun cannot overwrite the real original), save the fixed test list,
///   read it back.
/// - `read`: read the value back, for after a force-stop.
/// - `restore`: save the stashed original back, read it back, drop the stash on a match.
/// - `pi` (#181): open Settings and report whether the "Use a Pi server" row is shown and
///   what it reads. `pi-on` / `pi-off` first flip it exactly the way `saveSettings` does
///   (`setPiEnabledOnWrapper`, then `probeNetworkStates`), without posting the form. The
///   flag is the one value these steps print: it is the wrapper's switch, not settings data.
/// - `cred-write` / `cred-read` / `cred-restore` (#184): the same Pi-off write lane for a
///   credential-shaped field, `premiumizeApiKey`, whose Settings badge is drawn from
///   `hasPremiumizeApiKey` alone. `cred-write` first takes a byte-exact Keychain backup of
///   the mirror, the queued patch and the ahead bit (refusing if one is already held), then
///   saves a throwaway key it generates together with `hasPremiumizeApiKey: false` — the flag
///   a Pi pull leaves when the key was unset there — and reports the flag and the badge.
///   `cred-read` reports them after a force-stop. `cred-restore` puts the backup back
///   natively, so the value it held never passes through the page, then reports them. Only
///   shapes, a length, the flag and the badge's leading words are returned, never a value.
///
/// Values never reach the log: the page hands them to Swift, which prints only a length
/// and a sha256 prefix for each.
enum SettingsSelfTest {
    static let steps: Set<String> = ["read", "write", "restore", "pi", "pi-on", "pi-off",
                                     "cred-write", "cred-read", "cred-restore"]
    private static var ran = false

    @MainActor
    static func run(_ step: String, in webView: WKWebView?) {
        guard steps.contains(step) else {
            NSLog("%@", "Dobby selftest149 refused: unknown step")
            return
        }
        guard !ran, let webView else { return }
        ran = true
        if step == "cred-write" && !SettingsMirrorStore.selfTestBackup() {
            NSLog("%@", "Dobby selftest184 refused: a backup is already held; run cred-restore first")
            return
        }
        if step == "cred-restore" {
            NSLog("%@", "Dobby selftest184 restore \(SettingsMirrorStore.selfTestRestore())")
        }
        webView.callAsyncJavaScript(script, arguments: ["step": step], in: nil, in: .page) { result in
            switch result {
            case .success(let value): NSLog("%@", "Dobby selftest149 \(summary(value))")
            case .failure(let error): NSLog("%@", "Dobby selftest149 \(step) threw: \(error.localizedDescription)")
            }
        }
    }

    /// `meta` is counts, statuses and paths the script builds itself; `v` holds values and
    /// is only ever fingerprinted.
    static func summary(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return "unexpected result" }
        var out = (dict["meta"] as? [String: Any]) ?? [:]
        for (key, val) in (dict["v"] as? [String: Any]) ?? [:] { out["v." + key] = fingerprint(val) }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "unencodable result" }
        return text
    }

    static func fingerprint(_ value: Any) -> String {
        guard let text = value as? String else { return value is NSNull ? "null" : "non-string" }
        let hex = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "len=\(text.count) sha=\(hex)"
    }

    private static let script = #"""
    const TEST = 'is,fo';
    const STASH = 'dobby.selftest149.original';
    const meta = { step: step };
    const v = {};
    const pause = (ms) => new Promise((r) => setTimeout(r, ms));
    // `ready` is posted at document start, before the page's own scripts run.
    for (let i = 0; i < 120 && typeof savePreferredSubtitleLanguage !== 'function'; i++) await pause(250);
    if (typeof savePreferredSubtitleLanguage !== 'function') { meta.error = 'page never booted'; return { meta, v }; }
    try { if (settingsLoadedPromise) await settingsLoadedPromise; } catch (e) {}
    await pause(3000);
    meta.origin = location.protocol + '//' + location.host;
    meta.simulated = document.querySelector('script[src^="dobby-offline:"]') ? 'bundled-shell' : 'network-shell';
    if (step.indexOf('pi') === 0) {
      meta.supported = typeof piEnabledSupported === 'function' && piEnabledSupported();
      if (step !== 'pi' && meta.supported) {
        setPiEnabledOnWrapper(step === 'pi-on');
        probeNetworkStates();
        await pause(2000);
      }
      openSettings();
      await pause(1000);
      const row = document.getElementById('settings-row-pi-enabled');
      meta.rowShown = !!row && !row.hidden;
      if (meta.rowShown) row.scrollIntoView({ block: 'center' });
      meta.piEnabled = meta.supported ? getPiEnabled() : null;
      meta.checked = document.getElementById('settings-pi-enabled')?.checked === true;
      meta.noServer = isNoServer();
      return { meta, v };
    }

    const read = async (label) => {
      const r = await fetch(apiUrlFor('/api/settings'), { cache: 'no-store' });
      meta[label + 'Status'] = r.status;
      const doc = await r.json();
      meta[label + 'Keys'] = Object.keys(doc).length;
      meta[label + 'HasKey'] = 'preferredSubtitleLanguage' in doc;
      return doc.preferredSubtitleLanguage === undefined ? null : doc.preferredSubtitleLanguage;
    };
    const local = () => { const e = lsGet('subtitleLanguage'); return e && e.language !== undefined ? e.language : null; };

    const realFetch = window.fetch;
    meta.piBlocked = 0; meta.piRequests = []; meta.wrapperCalls = [];
    const removePi = () => {
      window.fetch = function (input, init) {
        const url = new URL(typeof input === 'string' ? input : input.url, location.href);
        const method = ((init && init.method) || 'GET').toUpperCase();
        if (url.protocol === 'dobby-api:') {
          return realFetch.apply(this, arguments).then(
            (r) => { meta.wrapperCalls.push(method + ' ' + url.host + ' ' + r.status); return r; },
            (e) => { meta.wrapperCalls.push(method + ' ' + url.host + ' threw'); throw e; });
        }
        if (url.origin === location.origin) {
          meta.piBlocked++; meta.piRequests.push(method + ' ' + url.pathname);
          return Promise.reject(new TypeError('Pi removed (selftest149)'));
        }
        return realFetch.apply(this, arguments);
      };
    };
    const awaitWrite = async () => {
      for (let i = 0; i < 240 && !meta.wrapperCalls.some((c) => c.indexOf('POST settings') === 0); i++) await pause(250);
      await pause(1000);
    };

    if (step.indexOf('cred-') === 0) {
      const PREFIX = 'selftest184-';
      const readCred = async (label) => {
        const r = await fetch(apiUrlFor('/api/settings'), { cache: 'no-store' });
        meta[label + 'Status'] = r.status;
        const doc = r.ok ? await r.json() : {};
        const key = doc.premiumizeApiKey;
        meta[label + 'KeyShape'] = key === undefined ? 'absent' : key === null ? 'null'
          : typeof key !== 'string' ? 'non-string' : key === '' ? 'empty' : 'string';
        meta[label + 'KeyLen'] = typeof key === 'string' ? key.length : null;
        meta[label + 'KeyIsPlaceholder'] = typeof key === 'string' && key.indexOf(PREFIX) === 0;
        meta[label + 'HasFlag'] = 'hasPremiumizeApiKey' in doc ? doc.hasPremiumizeApiKey : 'absent';
      };
      const badge = async () => {
        settingsLoadedPromise = null;
        openSettings();
        await pause(2000);
        const text = (document.getElementById('settings-pm-state') || {}).textContent || '';
        meta.badge = text.indexOf('Configured') === 0 ? 'Configured'
          : text.indexOf('Not configured') === 0 ? 'Not configured' : 'other';
      };
      await readCred(step === 'cred-write' ? 'before' : 'now');
      if (step === 'cred-write') {
        const bytes = crypto.getRandomValues(new Uint8Array(12));
        removePi();
        // #185: what saveSettings keys "Settings saved" on — mirroredWrite resolving
        // ok — or its silent catch when the save was not taken.
        meta.saveOutcome = 'pending';
        mirroredWrite('/api/settings', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            premiumizeApiKey: PREFIX + Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join(''),
            hasPremiumizeApiKey: false
          })
        }, fetchWithRetry).then(
          (r) => { meta.saveOutcome = (r && r.ok ? 'saved ' : 'not-ok ') + (r && r.status); },
          () => { meta.saveOutcome = 'rejected'; });
        await awaitWrite();
        window.fetch = realFetch;
        await readCred('after');
      }
      await badge();
      return { meta, v };
    }

    const stashed = localStorage.getItem(STASH);
    v.test = TEST;
    if (step === 'write') {
      if (stashed !== null) { meta.error = 'an original is already stashed; restore first'; return { meta, v }; }
      const original = await read('before');
      v.original = original;
      v.localBefore = local();
      if (original === TEST) { meta.error = 'original equals the test value'; return { meta, v }; }
      localStorage.setItem(STASH, JSON.stringify({ value: original }));
      removePi();
      savePreferredSubtitleLanguage(TEST, { list: true });
      await awaitWrite();
      v.readback = await read('after');
      v.localAfter = local();
    } else if (step === 'read') {
      if (stashed !== null) v.original = JSON.parse(stashed).value;
      meta.stashed = stashed !== null;
      v.readback = await read('now');
      v.local = local();
    } else {
      if (stashed === null) { meta.error = 'nothing stashed to restore'; return { meta, v }; }
      const original = JSON.parse(stashed).value;
      v.original = original;
      v.before = await read('before');
      removePi();
      if (typeof original === 'string' && normalizeSubtitleLanguageList(original).length) {
        meta.restoreVia = 'savePreferredSubtitleLanguage';
        savePreferredSubtitleLanguage(original, { list: true });
      } else {
        // The pick path refuses an empty list, so an unset original goes back the way
        // saveSettings sends one: an explicit null through the same mirroredWrite.
        meta.restoreVia = 'mirroredWrite-null';
        lsRemove('subtitleLanguage');
        mirroredWrite('/api/settings', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ preferredSubtitleLanguage: null })
        }, fetchWithRetry).catch(() => {});
      }
      await awaitWrite();
      v.readback = await read('after');
      v.localAfter = local();
      meta.restored = v.readback === original;
      if (meta.restored) localStorage.removeItem(STASH);
    }
    window.fetch = realFetch;
    return { meta, v };
    """#
}
#endif
