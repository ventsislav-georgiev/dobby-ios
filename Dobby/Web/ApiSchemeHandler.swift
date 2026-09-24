import Foundation
import Security
import WebKit
import os

/// The two API paths the page cannot get from the Pi when the Pi is off, answered
/// natively over `dobby-api://` (plan §9, option (a)).
///
/// Why a custom scheme rather than the Android trick: `WKURLSchemeHandler` is
/// refused for any scheme WebKit handles itself, `https` included, so there is no
/// iOS equivalent of `shouldInterceptRequest` — the page has to address the
/// wrapper explicitly. It does that only for these two paths (`js/01-state-init.js`,
/// `apiUrlFor`); everything else stays on the Pi origin, so localStorage, IndexedDB
/// and the service worker are untouched. Scheme requests never reach the service
/// worker at all — `fetch` events only fire for http(s) — which is exactly what we
/// want for the credential lane.
///
/// `dobby-api://settings` — mirror-first, the rule Android landed in #044: a
/// mirrored body is answered immediately and the Pi is asked again behind the
/// answer; only an empty mirror waits on the Pi. The mirror is one Keychain item
/// holding the whole `/api/settings` payload, secrets included (owner decision
/// #045), so the credential lane below has a token with the Pi unreachable.
///
/// Since #149 (M5-F) it also takes `POST`, so a phone whose Pi is off has
/// somewhere for a settings write to land. The body is merged one key deep into
/// the Keychain document rather than replacing it — the form only sends the
/// fields the user filled in — and the mirror is then marked as ahead of the Pi
/// so a background refresh cannot pull the pre-write body back over it.
///
/// `dobby-api://proxy?target=…` — the same two legs as `ProxyRoutes.swift` and
/// `ApiInterceptor.java`: allowlisted IMDb artwork with nothing injected, and the
/// credential lane, which is the only thing here that spends a secret and is
/// therefore the narrow one — exactly `graphql.imdb.com`, no wildcards, redirects
/// answered as an error rather than followed with the cookie attached.
final class ApiSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = AppConfig.apiScheme

    /// At most this many upstream requests per image, redirects included.
    private static let maxImageRequests = 3
    private static let imdbGraphQL = "https://graphql.imdb.com/"
    private static let imdbSessionID = "132-4567890-1234567"
    static let defaultImageCacheControl = "public, max-age=604800, immutable"
    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "api-scheme")

    /// The origin the WebView actually loaded — the Tailscale name or the LAN
    /// address, whichever `ServerAddresses.resolve()` picked. Not `AppConfig.serverURL`:
    /// on the home network the page is on plain http and a refresh aimed at the
    /// Tailscale name would be a second, slower link to the same box.
    private let server: URL

    /// `server` as an `Origin` header spells it. The only value the secret-carrying
    /// lanes will ever answer `Access-Control-Allow-Origin` with.
    private let serverOrigin: String?

    private let queue = DispatchQueue(label: "com.solarflare.dobby.api-scheme", qos: .userInitiated)
    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    /// One refresh in flight at a time; a boot that reads settings twice must not
    /// hit the Pi twice.
    private let refreshing = NSLock()
    private var refreshInFlight = false

    /// #152: the same single-flight rule for the write-back push. A boot that reads
    /// settings twice must not POST the user's secrets twice either. Its own flag
    /// rather than `refreshInFlight`, because the drain runs BEFORE the ahead guard
    /// and the pull runs only after it — the two are never in flight for the same
    /// reason, so sharing one flag would make a running drain silently skip a
    /// legitimate pull.
    private var drainInFlight = false

    init(server: URL) {
        self.server = server
        self.serverOrigin = Self.normalizedOrigin(server.absoluteString)
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); active.insert(id); lock.unlock()

        guard let url = task.request.url else {
            fail(task, id, 400, "Bad dobby-api request"); return
        }
        let method = (task.request.httpMethod ?? "GET").uppercased()
        let origin = task.request.value(forHTTPHeaderField: "Origin")
        // #149: read off the request here, on the thread WebKit started the task on,
        // for the same reason `url`/`method`/`origin` are — `queue.async` below runs
        // later and `WKURLSchemeTask`'s request is not documented as safe to touch
        // from anywhere. Unlike Android's `WebResourceRequest`, which carries no body
        // at all and is why `MirrorWriteBack` exists over there, WebKit does populate
        // `httpBody` for a scheme-handled POST — measured against a real `WKWebView`
        // before this leg was written (#149 round 1 evidence). `httpBodyStream` was
        // nil in that measurement; a body arriving only as a stream would read here
        // as "no body" and be refused with a 400 rather than stored empty.
        let body = task.request.httpBody

        queue.async { [weak self] in
            guard let self else { return }
            switch url.host?.lowercased() {
            case "settings": self.serveSettings(task, id, url, method, origin, body)
            case "proxy": self.serveProxy(task, id, url, method, origin)
            default: self.fail(task, id, 404, "Unknown dobby-api route", origin)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); active.remove(id); lock.unlock()
    }

    // MARK: - Making the lane reachable at all (#067, the Mac "Load failed")

    /// `dobby-api:` is not one of WebKit's a-priori-trustworthy schemes, so from a
    /// page served over https — which is every Tailscale address, and the only
    /// address the Mac has — a `fetch('dobby-api://…')` is *blockable mixed
    /// content*. WebKit refuses it before `webView(_:start:)` is ever called and
    /// `fetch` rejects with the sanitised `TypeError: Load failed`, which is exactly
    /// what the episode list rendered. Nothing about the response, the ACAO header
    /// or the handler's own logic is involved: the request never leaves the page.
    ///
    /// Over http (the LAN address the iPhone uses) the document is not a secure
    /// context, there is no mixed content, and the same call works — which is why
    /// this only ever showed up on the Mac. Posters kept rendering because they go
    /// straight to the https CDN (#060), and offline audio keeps working because
    /// media elements are *optionally*-blockable and are let through.
    ///
    /// Telling WebKit the scheme is trustworthy is the fix, and this SPI is the only
    /// thing that does it — `WKWebView` refuses to register a handler for https, so
    /// the lane cannot be moved onto a scheme WebKit already trusts. It widens
    /// *reachability* for non-CORS subresource types (classic `<script src>` etc.)
    /// from an https document — those were blocked outright before this call. It
    /// does not widen *read* access: the exact-origin ACAO gate below is what
    /// decides who may read the settings and credential lanes, and it is untouched
    /// (a JSON body is not a valid classic script, and the Mac is app-bound, per
    /// WebContainer.isAppBound).
    ///
    /// ponytail: SPI, guarded by `responds(to:)` and returning whether it took.
    /// `Tests/ApiSchemeWebViewCheck.swift` drives a real `WKWebView` from an https
    /// document, so a macOS that drops this selector fails `run-checks.sh` rather
    /// than shipping a silently dead lane. Upgrade path if it ever goes: move the
    /// two paths onto the `WKScriptMessageHandlerWithReply` bridge, taking the
    /// caller's origin from `WKFrameInfo.securityOrigin` instead of the header.
    ///
    /// #151 passes `OfflineSchemeHandler.scheme` here as well: the Pi-less cold start
    /// addresses the bundled shell's scripts and stylesheet on `dobby-offline:` from a
    /// simulated document on the Pi's https origin, which is the same blockable-mixed-content
    /// refusal this call exists to lift — and for a classic `<script src>` it is a refusal
    /// with no `catch` anywhere, just a blank page.
    @discardableResult
    static func registerAsSecureScheme(in configuration: WKWebViewConfiguration,
                                       scheme: String = ApiSchemeHandler.scheme) -> Bool {
        // `processPool` is deprecated as a configuration *knob* — two fresh
        // configurations hand back different WKProcessPool objects (measured), so
        // pool identity is irrelevant. The registration is process-global: any pool
        // object is just a receiver for the selector, which is why one call from any
        // makeWebView covers every WebView and repeating it per makeWebView is
        // idempotent. `WKProcessPool()` carries the same deprecation, so there is no
        // warning-free spelling — this is the honest one, since the argument is a
        // configuration.
        let pool = configuration.processPool
        let selector = NSSelectorFromString("_registerURLSchemeAsSecure:")
        guard pool.responds(to: selector) else {
            log.error("cannot mark \(scheme, privacy: .public) as a secure scheme; it is unreachable from an https page")
            return false
        }
        _ = pool.perform(selector, with: scheme)
        return true
    }

    // MARK: - dobby-api://settings

    private func serveSettings(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                               _ url: URL, _ method: String, _ origin: String?,
                               _ body: Data?) {
        let startedAt = DispatchTime.now()
        var status = 0
        var length = 0
        var source = "network"
        // #116: Debug-only, mirrors logImage below — route, status, size, source,
        // duration; the body carries settings secrets and must never be logged.
        #if DEBUG
        defer { self.logApi(route: "settings", status: status, length: length, source: source, startedAt: startedAt) }
        #endif
        guard method == "GET" || method == "POST" else {
            status = 405
            fail(task, id, 405, "Settings mirror takes GET and POST", origin, secret: true); return
        }
        if method == "POST" {
            source = "mirror"
            // A write only ever reaches here because the page's own POST to the Pi
            // already failed — `mirroredWrite` (`js/03-storage-net.js`) tries
            // `API + path` first and only then the wrapper's URL. So the Pi is the
            // write side whenever it is up, exactly as before, and this leg is the
            // Pi-off case only.
            //
            // 200, not Android's 409: over there the interceptor cannot see the body,
            // so it must refuse and let the page hand the bytes to the JS bridge
            // instead. Here the handler IS the destination — the merge below is the
            // write — so a 409 would be a lie the page would act on (`mirroredWrite`
            // treats any non-ok as "not taken" and rethrows the Pi's failure, which
            // is the user's save reported as lost while it sat safely in the
            // Keychain). `fetchWithRetry` never retries a 200, so the answer is final.
            // The same argument, turned round, is why a write the Keychain refused must
            // NOT be that 200 (#185): see `settingsWriteAnswer`.
            //
            // #185: the mirror as it was before this save, read once and used twice — as the
            // merge base, and as what goes back if the queue write below is refused.
            //
            // #189: with its status. Only a read that succeeded or found no item (a first save,
            // merged over nil) goes on to the save; any other refusal is the 507 answer, and
            // nothing is written, marked or queued over a mirror this leg could not see.
            let (previous, mirrorRead) = SettingsMirrorStore.loadWithStatus()
            guard let patch = body, !patch.isEmpty,
                  let merged = Self.mergedSettings(base: previous, patch: patch) else {
                // Refused rather than stored: a body we cannot parse is a body we
                // cannot merge, and storing it whole would make a partial or corrupt
                // document indistinguishable from a complete one on the next read.
                // 400 is not in `fetchWithRetry`'s retry list, so the page sees the
                // failure straight away instead of backing off into it.
                status = 400
                fail(task, id, 400, "Settings write needs a JSON object body", origin, secret: true); return
            }
            // #185: every Keychain status on this leg reaches the answer. A refused mirror
            // write marks and queues nothing — nothing changed that a hold would protect.
            var stored = mirrorRead
            if stored == errSecSuccess || stored == errSecItemNotFound { stored = SettingsMirrorStore.save(merged) }
            if stored == errSecSuccess {
                SettingsMirrorStore.markAheadOfServer()
                // #152: the patch bytes, kept so the Pi can be told what changed once it
                // answers. The merged document above cannot stand in for them — the Pi
                // applies the two language keys by body presence, so a stale mirror's
                // explicit nulls would clear live values (see `mergedPatch`). After
                // `markAheadOfServer()` on purpose: a drain that lands and releases the
                // hold in this sliver is one that pushed an OLDER patch, and this call
                // re-takes the hold under the queue's own lock.
                stored = SettingsMirrorStore.queuePatch(patch)
                // #185: the page is about to be told 507 and keep its form open, so the
                // mirror must not keep claiming these values: with no patch queued for them
                // a Pi-off GET would serve them as saved and the next drain would release the
                // hold and let the Pi silently revert them. Keep-going: a refused put-back is
                // logged by the store and the answer stays the queue's status.
                if stored != errSecSuccess { SettingsMirrorStore.restoreMirror(previous) }
            }
            let answer = Self.settingsWriteAnswer(stored)
            status = answer.status
            length = answer.body.count
            respond(task, id, status: answer.status, contentType: "application/json",
                    body: answer.body, origin: origin, secret: true,
                    extra: ["Cache-Control": "no-store"])
            return
        }
        let mirror = SettingsMirrorStore.load()
        source = (mirror?.isEmpty == false) ? "mirror" : "network"
        let outcome = Self.settingsOutcome(mirror: mirror) {
            Self.fetchSettings(from: server)
        }
        // #185: a refused seed of the mirror is logged by the store and does not change
        // this answer — the page is handed the Pi's own body either way.
        if outcome.store { _ = SettingsMirrorStore.save(outcome.body) }
        status = outcome.status
        length = outcome.body.count
        // no-store: this body carries every secret since #045, so nothing that
        // outlives the request is allowed to hold a copy of it but the Keychain item.
        respond(task, id, status: outcome.status, contentType: "application/json",
                body: outcome.body, origin: origin, secret: true,
                extra: ["Cache-Control": "no-store"])
        if outcome.status == 200 && !outcome.store { refreshSettingsInBackground() }
    }

    /// Mirror-first as values, so the rule is checkable without a WebView.
    ///
    /// A mirrored body answers on the spot and `fetch` is never called — the read
    /// the page makes at boot must not hold on a slow-but-reachable Pi (#044). Only
    /// an empty mirror waits, and a cold start with the Pi down has nothing to say.
    ///
    /// #184: both 200 bodies go through `withPresenceFlags` here, so there is no settings
    /// document `serveSettings` can hand the page without its has* flags re-derived. The
    /// mirror hit is the one that needs it; the Pi's own body already carries the flags it
    /// computed, and passes through unchanged.
    static func settingsOutcome(mirror: Data?, fetch: () -> Data?) -> (status: Int, body: Data, store: Bool) {
        if let mirror, !mirror.isEmpty { return (200, withPresenceFlags(mirror), false) }
        if let fresh = fetch(), !fresh.isEmpty { return (200, withPresenceFlags(fresh), true) }
        return (503, Data(#"{"error":"Settings unavailable and nothing mirrored"}"#.utf8), false)
    }

    /// The settings POST's answer from the Keychain's status, as values (#185).
    ///
    /// 200 `{}` only for errSecSuccess. Anything else is 507: non-2xx, so the page's
    /// `appleWrapperWrite` reads it as not taken and `saveSettings` keeps the form open
    /// with no "Settings saved"; and outside `fetchWithRetry`'s retry list (408, 429, 500,
    /// 502, 503, 504), so the first answer is final instead of three more writes into the
    /// same refusing Keychain. Not 409: over there it means "hand it to the bridge"; here
    /// the handler is the destination and the honest answer is "could not store it".
    static func settingsWriteAnswer(_ stored: OSStatus) -> (status: Int, body: Data) {
        if stored == errSecSuccess { return (200, Data("{}".utf8)) }
        return (507, Data(#"{"error":"Settings could not be stored on this device","status":\#(stored)}"#.utf8))
    }

    /// The secrets `GET /api/settings` pairs with a computed has* flag (#184) —
    /// `SettingsRoutes.swift` in the server repo (dobby), six since #174. Android holds the
    /// same six in `SettingsMirror.PRESENCE_FLAGGED_KEYS` (dobby-android, #164). run-checks
    /// reads the server's list out of a sibling dobby checkout and fails on any drift: a
    /// secret missing here answers with no flag and reads Not configured with the Pi off.
    static let presenceFlaggedKeys = [
        "imdbAuthToken",
        "premiumizeApiKey",
        "openSubtitlesUsername",
        "openSubtitlesPassword",
        "subdlApiKey",
        "subsourceApiKey",
    ]

    /// `premiumizeApiKey` -> `hasPremiumizeApiKey`, the server's pairing rule.
    static func presenceFlag(_ key: String) -> String {
        "has" + key.prefix(1).uppercased() + key.dropFirst()
    }

    /// The document with every has* flag re-derived from its own fields (#184).
    ///
    /// The page draws each Configured badge from a has* flag and never from the field
    /// (`js/14-settings.js`), and only the Pi's GET computes those flags as it serves. The
    /// mirror is also written by this device (`mergedSettings` over the seed, which has no
    /// flags) and a write lays raw keys over whatever flag the last pull left. So a key saved
    /// with the Pi off answered with no flag, or a stale one, and read Not configured.
    ///
    /// The rule is the server's: has<X> is true exactly when <x> is a non-empty string. A raw
    /// key the document does not carry leaves its flag alone — absent is not unset. Applied
    /// where the answer is built rather than where the mirror is written, so a document
    /// already in the Keychain from an earlier build heals on its next read. Answers `body`
    /// itself when nothing changes or it is not a JSON object.
    static func withPresenceFlags(_ body: Data) -> Data {
        guard var document = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
        var changed = false
        for key in presenceFlaggedKeys {
            guard let value = document[key] else { continue }
            let configured = (value as? String)?.isEmpty == false
            let flag = presenceFlag(key)
            if let existing = document[flag] as? NSNumber,
               CFGetTypeID(existing) == CFBooleanGetTypeID(), existing.boolValue == configured { continue }
            document[flag] = configured
            changed = true
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else { return body }
        return data
    }

    /// The eight field names `GET /api/settings` always sends as an explicit JSON
    /// `null` when unset, so a client can tell "unset" apart from "field absent"
    /// — `SettingsRoutes.swift:37-44` in the server repo (dobby, main @ c8a504f).
    /// Nine until #174; the ninth key went with the service it belonged to.
    ///
    /// Transcribed rather than read at build time, because the two repos build
    /// separately with nothing enforcing they stay in step; a mismatch between
    /// this list and the Swift one on the Pi is exactly the drift
    /// `ApiSchemeHandlerCheck.settingsSeedCoversEveryNullKey` exists to catch on
    /// this side, by naming the count and every literal so a future edit to
    /// either list has to touch this comment too. Android holds the same eight in
    /// `SettingsMirror.SETTINGS_NULL_KEYS` (dobby-android, #174 @ c6525be13).
    static let settingsNullKeys = [
        "imdbAuthToken",
        "premiumizeApiKey",
        "openSubtitlesUsername",
        "openSubtitlesPassword",
        "subdlApiKey",
        "subsourceApiKey",
        "preferredSubtitleLanguage",
        "preferredAudioLanguage",
    ]

    /// The document a merge starts from when nothing better exists: every
    /// `settingsNullKeys` name present with an explicit `null`, and nothing else.
    ///
    /// iOS needs this for the same reason Android does (#145, M5-A), and the
    /// decision is not inherited — it was re-taken here. §11f puts the Pi-less
    /// *cold start* out of scope (that is #151), so a never-paired iPhone cannot
    /// reach this code at all, which is the case the Android seed was written
    /// for. But an *empty mirror on a loaded page* is still reachable on iOS: the
    /// Pi served `index.html` and went away before the settings GET, or
    /// `settingsOutcome` answered 503 and stored nothing, or the Keychain did not
    /// survive a device restore. In that state a one-key POST merged into `{}`
    /// would be stored as the whole document, and the page's `applyServerSettings`
    /// (`js/14-settings.js:121-170`) treats a key it does not see as cleared — so
    /// the next read would blank every sibling secret. Seeding with explicit nulls
    /// is what makes a partial POST impossible to mistake for a complete document.
    ///
    /// Deliberately not the non-secret settings a box already has (theme, subtitle
    /// sizing, ...): those live in the page's own localStorage and a second copy
    /// here would only be one more thing to keep in step.
    static var settingsSeed: [String: Any] {
        var seed: [String: Any] = [:]
        for key in settingsNullKeys { seed[key] = NSNull() }
        return seed
    }

    static func seedSettingsJson() -> Data {
        (try? JSONSerialization.data(withJSONObject: settingsSeed)) ?? Data("{}".utf8)
    }

    /// `patch` laid over `base` one key deep — the whole point of the write leg,
    /// and the property most worth being wrong about.
    ///
    /// The settings form omits every secret left blank (`js/14-settings.js:490-499`
    /// only sets a key when its field is non-empty) and `savePreferredSubtitleLanguage`
    /// posts a single key on its own (`js/17-video-playback.js:123-127`), so a POST
    /// body is a patch, never a document. Storing one whole would drop
    /// `imdbAuthToken` and `premiumizeApiKey` out of the mirror precisely while the
    /// Pi is unreachable and the mirror is the only copy of them. The Pi's own
    /// `POST /api/settings` applies keys by presence for the same reason
    /// (`SettingsRoutes.swift:83-106`), so this matches the server it stands in for.
    ///
    /// Shallow on purpose: every settings value is a scalar or an array the page
    /// replaces whole (`serverAddresses`, `sourceOrder`), so there is no nested
    /// object a deep merge would be needed for, and a deep merge would make an
    /// array impossible to shorten.
    ///
    /// `nil` when `patch` is not a JSON object — the caller refuses the write
    /// rather than storing something it could not read.
    ///
    /// A `null` in the patch is a value, not an omission: it lands as `NSNull` and
    /// the key stays present, which is how "cleared on this device" survives a read
    /// that distinguishes null from absent.
    static func mergedSettings(base: Data?, patch: Data) -> Data? {
        shallowMerge(onto: settingsSeed, base: base, patch: patch)
    }

    /// The write-back queue's own accumulation (#152), and deliberately **not**
    /// `mergedSettings`: same shallow rule, but it starts from `[:]` rather than
    /// `settingsSeed`, and that one difference is the whole safety argument.
    ///
    /// `POST /api/settings` on the Pi is not symmetric across its keys. The seven
    /// secrets are each assigned inside an `if let sanitizedSecret(...)`
    /// (`SettingsRoutes.swift:63-76`), so a `null` for one of those no-ops — but
    /// `preferredSubtitleLanguage` and `preferredAudioLanguage` are gated on
    /// `rawObject?.keys.contains(...)`, body *presence* (`:86-90`), and
    /// `sanitizedLanguage(nil)` is nil, so a body carrying either key as an
    /// explicit null **clears** the Pi's value for it. A queued body built on the
    /// seed would therefore wipe both language fields off a Pi for a device that
    /// has never touched them. Only keys this device actually wrote are ever
    /// pushed, which keeps the push purely additive.
    ///
    /// A `null` the user themselves put in a patch is kept: that is a clear made
    /// here, and it is meant to reach the Pi as a clear.
    static func mergedPatch(pending: Data?, patch: Data) -> Data? {
        shallowMerge(onto: [:], base: pending, patch: patch)
    }

    private static func shallowMerge(onto start: [String: Any], base: Data?, patch: Data) -> Data? {
        guard let patchObject = (try? JSONSerialization.jsonObject(with: patch)) as? [String: Any] else {
            return nil
        }
        var document = start
        if let base, !base.isEmpty,
           let existing = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] {
            for (key, value) in existing { document[key] = value }
        }
        for (key, value) in patchObject { document[key] = value }
        return try? JSONSerialization.data(withJSONObject: document)
    }

    private func refreshSettingsInBackground() {
        // #149: the mirror is AHEAD of the Pi once a write has landed here, and a
        // pull now would be carrying the Pi's pre-write body — the same direction
        // Android's `MirrorWriteBack` class doc spells out ("while a write is
        // queued, the mirror wins"). Without this, the sequence the milestone is
        // actually about — Pi off, key saved on the phone, Pi comes back — loses
        // the key on the next GET.
        //
        // #152 made it "drain, then pull". #149 landed only the "mirror wins"
        // half: the bit below was set at write time and nothing could clear it, so
        // one save made with the Pi off stopped this phone auto-refreshing from the
        // Pi for the life of the install — a change made on the Pi, on the Shield
        // or in a browser never reached it again. The drain is what releases it.
        //
        // The push runs behind this call, so the guard is still true on the way
        // past and THIS refresh is still skipped; the next mirror-served GET finds
        // the hold released and pulls. That is the same convergence step as
        // Android's `dirty` flag, which also only makes the *next* read go to the
        // Pi rather than re-reading inside the push.
        drainPendingSettings()
        if SettingsMirrorStore.isAheadOfServer { return }
        refreshing.lock()
        if refreshInFlight { refreshing.unlock(); return }
        refreshInFlight = true
        refreshing.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            // #185: nothing waits on this pull; a refused write is logged by the store,
            // the mirror keeps its last body and the next mirror-served GET pulls again.
            if let fresh = Self.fetchSettings(from: self.server) { _ = SettingsMirrorStore.save(fresh) }
            self.refreshing.lock(); self.refreshInFlight = false; self.refreshing.unlock()
        }
    }

    /// The half #149 did not build: push what this device wrote while the Pi was
    /// unreachable, and release the hold the moment the Pi takes it.
    ///
    /// **Only the queued patch bytes are ever sent.** The mirrored *document*
    /// cannot stand in for them at any point — `POST /api/settings` applies
    /// `preferredSubtitleLanguage` and `preferredAudioLanguage` by body presence
    /// (`SettingsRoutes.swift:86-90`), so a stale mirror's explicit nulls would
    /// clear both on the Pi for a device that never touched them. That is the
    /// whole reason a queue exists here rather than a re-POST of what is stored.
    ///
    /// Reachability is an answer from the Pi, never a probe of our own — the same
    /// rule as Android's `drain()`. This runs off a mirror-served GET, which the
    /// page makes at every boot and after every save, so a phone that has been
    /// holding a patch pushes it on the first page load the Pi answers.
    private func drainPendingSettings() {
        guard SettingsMirrorStore.isAheadOfServer else { return }
        guard let pending = SettingsMirrorStore.pendingPatch() else {
            // Held with nothing to push. Every phone already running the #149 build
            // is in exactly this state — the bit was set at write time and there was
            // no queue behind it — and so is the sliver between `markAheadOfServer()`
            // and `queuePatch(_:)` in the POST leg. Nothing to send and nothing to
            // protect, so let the Pi win again rather than hold forever.
            SettingsMirrorStore.releaseHold()
            return
        }
        refreshing.lock()
        if drainInFlight { refreshing.unlock(); return }
        drainInFlight = true
        refreshing.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            switch Self.pushSettings(pending, to: self.server) {
            case .landed, .refused:
                // Landed: the Pi applied the patch to its whole document, which is
                // more than was sent, so the Pi is now the fresher of the two and
                // the next GET's refresh goes and takes that body.
                //
                // Refused shares the branch on purpose. A 4xx that is not 408 or 429
                // is not "cannot reach the Pi" but "the Pi will never take this
                // body", and no number of retries changes that; holding it would pin
                // the mirror for the life of the install, which is exactly the
                // permanent degradation this entry exists to close. The change is
                // already lost — what is left is to stop holding the mirror hostage
                // to it. Android drops a 4xx and marks the path dirty for the same
                // reason; releasing the hold IS "ask the Pi" on this side.
                SettingsMirrorStore.clearPending(ifStill: pending)
            case .held:
                // No answer, a 5xx, or a 408/429. The patch stays queued, the mirror
                // stays ahead and keeps answering, and the next mirror-served GET
                // runs this again. The queue is in the Keychain, so it also survives
                // the app being killed.
                break
            }
            self.refreshing.lock(); self.drainInFlight = false; self.refreshing.unlock()
        }
    }

    enum PushOutcome { case landed, refused, held }

    /// What a push attempt means for the queue, as a pure rule so the decision is
    /// checkable without a socket.
    ///
    /// `nil` is "the Pi never answered". 408 and 429 are the two 4xx that are about
    /// timing rather than about the body, so they hold like a 5xx does instead of
    /// throwing the user's change away.
    static func pushOutcome(status: Int?) -> PushOutcome {
        guard let status else { return .held }
        if (200...299).contains(status) { return .landed }
        if (400...499).contains(status) && status != 408 && status != 429 { return .refused }
        return .held
    }

    /// Blocking on purpose: this runs on `queue`, never on the WebView's thread.
    /// The queued patch bytes, with the method and content type the page would have
    /// sent, to the Pi's own settings route.
    private static func pushSettings(_ patch: Data, to server: URL) -> PushOutcome {
        // #149 device round: DOBBY_NO_SERVER removes the Pi from this leg too, not only
        // from the probe, so a Pi-off round cannot push its test patch to a real Pi the
        // phone can still reach. Held, exactly as a Pi that never answered.
        #if DEBUG
        if ServerAddresses.noServerSeamActive() { log.info("pi leg skipped: push held (DOBBY_NO_SERVER seam)"); return .held }
        #endif
        // #181: the user setting, in every configuration. Held, not refused: the patch
        // stays queued and the first mirror-served GET after the Pi is turned back on
        // pushes it (Android's MirrorWriteBack.run, same rule). The settings document is
        // the credential store, so "no Pi" means it never leaves the device.
        if !ServerAddresses.piEnabled() { log.info("pi leg skipped: push held (Pi disabled by the user setting)"); return .held }
        var request = URLRequest(url: server.appendingPathComponent("api/settings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = patch
        request.timeoutInterval = 8
        let (_, http) = Transport.sendSync(request)
        return pushOutcome(status: http?.statusCode)
    }

    /// Blocking on purpose: this runs on `queue`, never on the WebView's thread.
    private static func fetchSettings(from server: URL) -> Data? {
        // #149 device round: same seam, same reason as pushSettings above. Nil is a Pi
        // that never answered.
        #if DEBUG
        if ServerAddresses.noServerSeamActive() { log.info("pi leg skipped: fetch (DOBBY_NO_SERVER seam)"); return nil }
        #endif
        // #181: same setting, same reason as pushSettings above.
        if !ServerAddresses.piEnabled() { log.info("pi leg skipped: fetch (Pi disabled by the user setting)"); return nil }
        var request = URLRequest(url: server.appendingPathComponent("api/settings"))
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        let (data, http) = Transport.sendSync(request)
        guard let http, (200...299).contains(http.statusCode), let data, !data.isEmpty else { return nil }
        return data
    }

    // MARK: - dobby-api://proxy

    private func serveProxy(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                            _ url: URL, _ method: String, _ origin: String?) {
        let query = Self.query(of: url)
        switch query["target"] {
        case "image": serveImage(task, id, query["url"], method, origin)
        case "imdb-graphql": serveGraphQL(task, id, query["q"], method, origin)
        default: fail(task, id, 400, "Unknown proxy target", origin)
        }
    }

    /// #071: the image lane is the only one with a disk cache — a poster is
    /// public artwork, nothing injected, exactly what belongs in a plaintext
    /// `Caches/` directory, unlike the settings/credential bodies above. Cache
    /// checked directly against `ImageTransport.cache` before any request (the
    /// "or ask `urlCache.cachedResponse(for:)`" option), so a disk hit never
    /// reaches `ImageTransport.stream` at all — no transport call, no log-line
    /// "upstream" for what is actually free.
    private func serveImage(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                            _ raw: String?, _ method: String, _ origin: String?) {
        guard method == "GET" else { fail(task, id, 405, "Image proxy is GET only", origin); return }
        guard var current = Self.allowedImageURL(raw) else {
            fail(task, id, 400, "Missing or invalid image url", origin); return
        }

        for _ in 0..<Self.maxImageRequests {
            let request = Self.imageRequest(current)
            let startedAt = DispatchTime.now()

            if let hit = Self.cachedImageAnswer(ImageTransport.cache, request) {
                let contentType = hit.response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                logImage(path: current.path, status: 200, contentType: contentType,
                         length: "\(hit.data.count)", startedAt: startedAt, diskHit: true)
                // Content-Type passed through, not inspected: Amazon serves posters as
                // binary/octet-stream often enough that an "image/* only" rule refuses
                // artwork every browser renders. The allowlist is what bounds this lane.
                respond(task, id, status: 200, contentType: contentType, body: hit.data, origin: origin,
                        extra: ["Cache-Control": hit.response.value(forHTTPHeaderField: "Cache-Control")
                                    ?? Self.defaultImageCacheControl])
                return
            }

            switch streamImageHop(task, id, request, origin, path: current.path, startedAt: startedAt) {
            case .served:
                return
            case .redirect(let location):
                // Re-validated every hop: an allowlisted host may still point
                // somewhere that is not, and the check is worth nothing if it only
                // ever runs on the URL the page supplied.
                guard let next = Self.nextImageHop(from: current, location: location) else {
                    fail(task, id, 502, "Image redirect target is not allowlisted", origin); return
                }
                current = next
            case .failed(let status, let message):
                fail(task, id, status, message, origin); return
            }
        }
        fail(task, id, 502, "Image proxy followed too many redirects", origin)
    }

    private enum ImageHopOutcome {
        case served
        case redirect(String?)
        case failed(Int, String)
    }

    /// One upstream hop, delivered to `task` as bytes arrive (`ImageStreamSink`
    /// forwards straight from `StreamDelegate.urlSession(_:dataTask:didReceive:)`)
    /// rather than the old buffer-then-256KB-chunk `respond(...)` did against a
    /// `Transport.sendSync` result that was already fully downloaded before any
    /// chunk left this process.
    private func streamImageHop(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ request: URLRequest,
                                _ origin: String?, path: String, startedAt: DispatchTime) -> ImageHopOutcome {
        let sink = ImageStreamSink(handler: self, task: task, id: id, origin: origin,
                                   path: path, startedAt: startedAt)
        ImageTransport.stream(request, sink: sink)
        return sink.outcome
    }

    /// Bridges one streamed hop to the `WKURLSchemeTask`. Nested so it can call
    /// the handler's private `respond`/`send`/`finish` machinery directly — see
    /// `streamImageHop` for why this replaces the old buffered `respond(...)`
    /// call for the network path (the disk-cache hit above still uses it, since
    /// that body is already fully in memory and chunking it further buys nothing).
    private final class ImageStreamSink: ImageSink {
        // weak, not unowned: StreamDelegate holds this sink independently of
        // the handler's own lifetime, so a WebView torn down mid-stream can
        // deallocate the handler while a callback from the URLSession
        // delegate queue is still pending — `unowned` would trap on that
        // dereference instead of harmlessly no-oping.
        private weak var handler: ApiSchemeHandler?
        private let task: WKURLSchemeTask
        private let id: ObjectIdentifier
        private let origin: String?
        private let path: String
        private let startedAt: DispatchTime
        private(set) var outcome: ImageHopOutcome = .failed(502, "Image proxy failed")

        init(handler: ApiSchemeHandler, task: WKURLSchemeTask, id: ObjectIdentifier, origin: String?,
             path: String, startedAt: DispatchTime) {
            self.handler = handler; self.task = task; self.id = id
            self.origin = origin; self.path = path; self.startedAt = startedAt
        }

        func respond(_ response: HTTPURLResponse) -> Bool {
            if (300...399).contains(response.statusCode) {
                // Redirects are refused by StreamDelegate, so this IS the final
                // response for this hop; its body (if any) is drained and
                // discarded in receive(), never forwarded to the task.
                outcome = .redirect(response.value(forHTTPHeaderField: "Location"))
                return true
            }
            guard let finalURL = response.url, ApiSchemeHandler.isAllowedImageURL(finalURL) else {
                outcome = .failed(502, "Image response came from a non-allowlisted host")
                return false
            }
            guard (200...299).contains(response.statusCode) else {
                outcome = .failed(502, "Image proxy upstream failed")
                return false
            }
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            // expectedContentLength mirrors the upstream Content-Length, which
            // for a Content-Encoding response is the *encoded* size — but
            // URLSession hands this delegate the already-decoded bytes, so
            // forwarding that number would tell WKURLSchemeTask to expect a
            // byte count nothing here ever produces, and WebKit fails the
            // load. Omit the header rather than guess the decoded size.
            let length = response.value(forHTTPHeaderField: "Content-Encoding") == nil
                && response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil
            let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") ?? ApiSchemeHandler.defaultImageCacheControl
            guard let handler else {
                outcome = .failed(502, "Image proxy failed")
                return false
            }
            handler.logImage(path: path, status: 200, contentType: contentType,
                             length: length.map { "\($0)" } ?? "?", startedAt: startedAt, diskHit: false)
            guard handler.beginImageStream(task, id, contentType: contentType, contentLength: length,
                                           origin: origin, cacheControl: cacheControl) else {
                outcome = .failed(502, "Image proxy failed")
                return false
            }
            outcome = .served
            return true
        }

        func receive(_ data: Data) {
            guard case .served = outcome, let handler else { return } // a redirect's body, not the image
            _ = handler.send(task, id) { $0.didReceive(data) }
        }

        func complete(error: Error?) {
            guard case .served = outcome, let handler else { return } // redirect/failure: streamImageHop's caller decides
            if let error {
                handler.failMidStream(task, id, error)
            } else {
                handler.finish(task, id)
            }
        }
    }

    private func logImage(path: String, status: Int, contentType: String, length: String,
                          startedAt: DispatchTime, diskHit: Bool) {
        let ms = (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        Self.log.info("answered \(path, privacy: .public) image \(status) \(contentType, privacy: .public) \(length, privacy: .public)B head \(ms)ms \(diskHit ? "disk-hit" : "upstream", privacy: .public)")
    }

    /// #116: Debug-only, settings/graphql equivalent of `logImage` above — status-only,
    /// same Logger/category. Never the body, never a header value, never a token.
    #if DEBUG
    private func logApi(route: String, status: Int, length: Int, source: String, startedAt: DispatchTime) {
        let ms = (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        Self.log.info("answered \(route, privacy: .public) \(status) \(length, privacy: .public)B \(source, privacy: .public) \(ms)ms")
    }
    #endif

    private func beginImageStream(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, contentType: String,
                                  contentLength: Int?, origin: String?, cacheControl: String) -> Bool {
        guard let url = task.request.url else { return false }
        var headerFields = ["Content-Type": contentType, "Cache-Control": cacheControl]
        if let contentLength { headerFields["Content-Length"] = "\(contentLength)" }
        if let acao = Self.acao(origin: origin, serverOrigin: serverOrigin, secret: false) {
            headerFields["Access-Control-Allow-Origin"] = acao
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: headerFields) else { return false }
        return send(task, id) { $0.didReceive(response) }
    }

    private func serveGraphQL(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                              _ document: String?, _ method: String, _ origin: String?) {
        let startedAt = DispatchTime.now()
        var status = 0
        var length = 0
        // #116: Debug-only, same shape as logApi("settings", ...) above.
        #if DEBUG
        defer { self.logApi(route: "graphql", status: status, length: length, source: "network", startedAt: startedAt) }
        #endif
        let noStore = ["Cache-Control": "no-store"]
        guard method == "GET" else {
            status = 405
            fail(task, id, 405, "Credential lane is GET only", origin, noStore, secret: true); return
        }
        guard let document, !document.isEmpty else {
            status = 400
            fail(task, id, 400, "Missing graphql document", origin, noStore, secret: true); return
        }
        guard let token = SettingsMirrorStore.imdbAuthToken() else {
            status = 401
            fail(task, id, 401, "IMDb auth token not configured", origin, noStore, secret: true); return
        }
        let upstream = Self.credentialRequest(document: document, token: token)
        guard let url = upstream.url, Self.isAllowedCredentialURL(url) else {
            status = 502
            fail(task, id, 502, "Credential lane upstream is not allowlisted", origin, noStore, secret: true); return
        }

        let (data, http) = Transport.sendSync(upstream)
        guard let http else {
            status = 502
            fail(task, id, 502, "IMDb proxy failed", origin, noStore, secret: true); return
        }
        if (300...399).contains(http.statusCode) {
            status = 502
            fail(task, id, 502, "IMDb redirected; refusing to carry the credential", origin, noStore, secret: true); return
        }
        guard let finalURL = http.url, Self.isAllowedCredentialURL(finalURL) else {
            status = 502
            fail(task, id, 502, "IMDb response came from a non-allowlisted host", origin, noStore, secret: true); return
        }
        // Upstream failures collapse to 502 the way the Pi reports them: copying
        // IMDb's 401 through would make the page read "no token configured" for an
        // expired one and blame the settings.
        guard (200...299).contains(http.statusCode), let data else {
            status = 502
            fail(task, id, 502, "IMDb proxy upstream failed", origin, noStore, secret: true); return
        }
        status = 200
        length = data.count
        // Only Content-Type is answered, so an upstream Set-Cookie cannot reach the page.
        respond(task, id, status: 200, contentType: "application/json", body: data,
                origin: origin, secret: true, extra: noStore)
    }

    // MARK: - The rules, as pure functions (see Tests/ApiSchemeHandlerCheck.swift)

    /// Keeps the Swift `isAllowedImageURL` rule verbatim: https, no port,
    /// leading-dot suffixes, so `media-amazon.com.attacker.tld` cannot match.
    static func isAllowedImageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "m.media-amazon.com" || host.hasSuffix(".media-amazon.com")
            || host == "m.media-amazon.co.uk" || host.hasSuffix(".media-amazon.co.uk")
    }

    /// One parser, one decision: either the URL to fetch or nil. Deciding with one
    /// parser and fetching with another is how an allowlist gets walked past.
    static func allowedImageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw), isAllowedImageURL(url) else { return nil }
        return url
    }

    static func nextImageHop(from current: URL, location: String?) -> URL? {
        guard let location, !location.isEmpty,
              let next = URL(string: location, relativeTo: current)?.absoluteURL,
              isAllowedImageURL(next) else { return nil }
        return next
    }

    struct CachedImageAnswer {
        let data: Data
        let response: HTTPURLResponse
    }

    /// Cache-first, checked as a value: a real (temp-directory) `URLCache` in
    /// `Tests/ApiSchemeHandlerCheck.swift` proves a populated cache answers
    /// here with no upstream call, the #071 unit check, without a socket in
    /// the loop.
    ///
    /// A non-2xx entry is never served as a hit even if something once stored
    /// one (belt-and-braces alongside `ImageTransport.cachePolicy`, which is
    /// what should stop it from ever being stored) — `serveImage` always
    /// answers a hit as 200, so a cached 404 must not become one.
    ///
    /// ponytail: no max-age/freshness check on this path — a poster is
    /// immutable at its URL (Amazon's own contract, not just our default), so
    /// "present" is treated as "fresh" for as long as `URLCache`'s own LRU
    /// keeps it. Upgrade path if that assumption ever breaks: compare the
    /// stored response's `Date` header plus its `Cache-Control: max-age`
    /// against now, same as a real HTTP cache would.
    static func cachedImageAnswer(_ cache: URLCache, _ request: URLRequest) -> CachedImageAnswer? {
        guard let cached = cache.cachedResponse(for: request),
              let http = cached.response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return CachedImageAnswer(data: cached.data, response: http)
    }

    static func isAllowedCredentialURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "graphql.imdb.com" && url.port == nil
    }

    /// The only request that carries the IMDb cookie, and it is built against a
    /// fixed URL — nothing the page sends picks the host or the headers.
    static func credentialRequest(document: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: imdbGraphQL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("at-main=\(token); ubid-main=\(imdbSessionID)", forHTTPHeaderField: "Cookie")
        request.setValue(imdbSessionID, forHTTPHeaderField: "x-amzn-sessionid")
        // IMDb's edge (CloudFront/WAF) 403s anything without a client-name header.
        request.setValue("imdb-web-next", forHTTPHeaderField: "x-imdb-client-name")
        request.httpBody = Data(document.utf8)
        return request
    }

    /// The public lane: no credential, no page-supplied header.
    static func imageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        return request
    }

    static func query(of url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if out[item.name] == nil { out[item.name] = item.value }
        }
        return out
    }

    // MARK: - Answering the task

    /// `Access-Control-Allow-Origin` is needed at all because the page is on https
    /// (or LAN http) and the response is on `dobby-api:` — a cross-origin fetch as
    /// far as WebKit is concerned, refused without it.
    ///
    /// The boundary is the WebView, NOT the page. The handler is registered on the
    /// `WKWebViewConfiguration`, so every document that WebView loads can issue
    /// `dobby-api:` requests — an iframe, an ad, any page it navigated to — and
    /// navigation is not restricted (`limitsNavigationsToAppBoundDomains` is false
    /// on the LAN path). So echoing the caller's `Origin`, or falling back to `*`,
    /// would hand the settings body — `imdbAuthToken` and the rest of #045 — to
    /// whichever document asked for it.
    ///
    /// Hence two lanes. The settings and credential lanes answer the header only
    /// when the caller IS the origin the WebView was pointed at, compared as
    /// normalised `scheme://host[:port]`, and answer no ACAO at all otherwise —
    /// no `*`, no echo. The image lane carries no secret (allowlisted artwork,
    /// nothing injected), so it keeps the permissive header and images still load
    /// for a page on whichever address `ServerAddresses.resolve()` picked.
    static func acao(origin: String?, serverOrigin: String?, secret: Bool) -> String? {
        guard secret else { return origin ?? "*" }
        guard let serverOrigin, let origin = normalizedOrigin(origin),
              origin == serverOrigin else { return nil }
        return serverOrigin
    }

    /// `scheme://host[:port]`, lowercased, default ports dropped — the shape a
    /// browser puts in `Origin`. Both sides of the compare go through this one
    /// parser, so a spelled-out `:443` on either side cannot make two spellings of
    /// the same origin read as different origins. Anything unparseable (`null`,
    /// an opaque origin, empty) is nil and therefore never matches.
    static func normalizedOrigin(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if let port = url.port, port != defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    private func headers(_ contentType: String, _ length: Int, _ origin: String?,
                         _ secret: Bool, _ extra: [String: String]) -> [String: String] {
        var out = [
            "Content-Type": contentType,
            "Content-Length": "\(length)",
        ]
        if let value = Self.acao(origin: origin, serverOrigin: serverOrigin, secret: secret) {
            out["Access-Control-Allow-Origin"] = value
        }
        for (key, value) in extra { out[key] = value }
        return out
    }

    private func respond(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, status: Int,
                         contentType: String, body: Data, origin: String?,
                         secret: Bool = false, extra: [String: String] = [:]) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: headers(contentType, body.count, origin,
                                                                   secret, extra)) else {
            finish(task, id); return
        }
        guard send(task, id, { $0.didReceive(response) }) else { return }

        var offset = 0
        let chunkSize = 256 * 1024
        while offset < body.count {
            let end = min(offset + chunkSize, body.count)
            let chunk = body.subdata(in: offset..<end)
            guard send(task, id, { $0.didReceive(chunk) }) else { return }
            offset = end
        }
        finish(task, id)
    }

    private func fail(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ status: Int,
                      _ message: String, _ origin: String? = nil, _ extra: [String: String] = [:],
                      secret: Bool = false) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        respond(task, id, status: status, contentType: "application/json",
                body: Data("{\"error\":\"\(escaped)\"}".utf8), origin: origin,
                secret: secret, extra: extra)
    }

    /// The check-then-call is atomic with `lock` held across `body(task)`, not
    /// just across the check: `webView(_:stop:)` also takes `lock` to remove
    /// `id`, so a `stop` racing a WebKit call on this task now either happens
    /// fully before or fully after it, never in between. Before #071 the two
    /// were separate critical sections, which was already a live crash window
    /// (a `stop` landing between the check and the call raises
    /// `NSInternalInconsistencyException` on a torn-down `WKURLSchemeTask`,
    /// uncatchable in Swift) — #071's streamed delivery calls this once per
    /// network chunk from the `URLSession` delegate queue, running
    /// concurrently with the handler's own serial queue, which turned an
    /// occasional window into one per chunk. `didReceive`/`didFinish`/
    /// `didFailWithError` are all fast, non-reentrant WebKit calls, so holding
    /// `lock` across them is cheap and never risks a deadlock back into this
    /// class.
    private func send(_ task: WKURLSchemeTask, _ id: ObjectIdentifier,
                      _ body: (WKURLSchemeTask) -> Void) -> Bool {
        onMain {
            lock.lock(); defer { lock.unlock() }
            guard active.contains(id) else { return false }
            body(task)
            return true
        }
    }

    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier) {
        onMain {
            lock.lock(); defer { lock.unlock() }
            guard active.contains(id) else { return }
            task.didFinish()
            active.remove(id)
        }
    }

    private func failMidStream(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ error: Error) {
        onMain {
            lock.lock(); defer { lock.unlock() }
            guard active.contains(id) else { return }
            task.didFailWithError(error)
            active.remove(id)
        }
    }

    /// Every WebKit call on a `WKURLSchemeTask` goes through here, on the MAIN THREAD —
    /// the same rule and the same reason as `OfflineSchemeHandler.onMain`, which is
    /// where it was measured: off the main thread, against a `loadSimulatedRequest`
    /// document, `didReceive` never returned and the held `lock` wedged the main thread
    /// at the next `webView(_:start:)`.
    ///
    /// This handler is on that same document — the bundled shell's `js/01-state-init.js`
    /// addresses `dobby-api:` for `/api/settings`, which is the whole point of #151 — so
    /// it carries the identical hang, reached a moment later. It has never been the
    /// reported symptom only because the shell's scripts wedge the page first.
    ///
    /// `Thread.isMainThread` is load-bearing: `webView(_:start:)` and `webView(_:stop:)`
    /// are already on main and reach these, so an unconditional `main.sync` deadlocks.
    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }
}

// MARK: - Transport

/// One hop, redirects refused and cookies off, so the IMDb cookie can never be
/// replayed onto a `Location` and no upstream `Set-Cookie` is kept. Callers decide
/// what a 3xx means — the image lane re-validates and follows, the credential lane
/// gives up.
enum Transport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    /// #071's "the credential lane never touches the image session" check: the
    /// two lanes' sessions differ in exactly this, this one has no disk cache
    /// at all (ephemeral: `urlCache` is a real, non-nil `URLCache` with
    /// `diskCapacity == 0` — memory-only, nothing ever reaches
    /// `Caches/image-proxy`), `ImageTransport`'s has a positive disk capacity.
    /// Actual isolation is that `serveSettings`/`serveGraphQL` call only
    /// `Transport.sendSync`, never `ImageTransport.stream` — not something a
    /// value-level check can observe directly, so this is the closest
    /// structural proof.
    static var usesDiskCache: Bool { (session.configuration.urlCache?.diskCapacity ?? 0) > 0 }

    /// Blocking. Every caller already runs on the handler's own queue, and a
    /// semaphore here is a great deal less code than threading async/await through
    /// a delegate-based scheme handler for three call sites.
    /// ponytail: semaphore hop, swap for async/await if this ever runs on an actor.
    static func sendSync(_ request: URLRequest) -> (Data?, HTTPURLResponse?) {
        let semaphore = DispatchSemaphore(value: 0)
        var out: (Data?, HTTPURLResponse?) = (nil, nil)
        session.dataTask(with: request) { data, response, _ in
            out = (data, response as? HTTPURLResponse)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return out
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

// MARK: - ImageTransport

/// The image lane's session (#071, the #060 grey-splash fix mirrored from
/// Android's `imageClient()`): unlike `Transport`, NOT ephemeral — a disk
/// `URLCache` is the entire point, so a second open of a grid answers posters
/// from `Caches/image-proxy` instead of media-amazon. The settings and
/// credential lanes stay on `Transport`'s ephemeral, no-store session; nothing
/// that spends a secret or carries `/api/settings` ever touches this one.
enum ImageTransport {
    /// 8 MB memory / 64 MB disk under `Caches/image-proxy`, so the OS may
    /// purge it under storage pressure — a purged poster costs one more
    /// upstream fetch, never a crash. Matches Android's 64 MB `image-proxy`
    /// `okhttp3.Cache` sizing.
    static let cache: URLCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("image-proxy", isDirectory: true)
        return URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024, directory: dir)
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // timeoutIntervalForRequest is an inactivity timeout, not a transfer
        // bound — a server that trickles bytes never trips it. The 25 s wait
        // in stream() below is a transfer bound, so timeoutIntervalForResource
        // must be under it or a slow poster can still be running past the
        // semaphore's timeout with outcome left at its .failed default.
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = cache
        return URLSession(configuration: config, delegate: StreamDelegate.shared, delegateQueue: nil)
    }()

    static var usesDiskCache: Bool { (session.configuration.urlCache?.diskCapacity ?? 0) > 0 }

    /// One hop, streamed to `sink` as bytes arrive rather than buffered whole
    /// and re-chunked afterwards. Redirects are refused by `StreamDelegate`
    /// exactly as `Transport.RefuseRedirects` does, so a 3xx completes as its
    /// own final response with no further body — `ApiSchemeHandler`'s per-hop
    /// allowlist re-check is unchanged, it just reads the outcome differently.
    /// The 25 s wait here is comfortably above `timeoutIntervalForResource`
    /// (20 s) on `session`, so the transfer itself — not just the connection
    /// going idle — is what's actually bounded below this call returning.
    static func stream(_ request: URLRequest, sink: ImageSink) {
        let semaphore = DispatchSemaphore(value: 0)
        StreamDelegate.shared.run(session.dataTask(with: request), sink: sink) { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 25)
    }

    /// Applied in `StreamDelegate`'s `willCacheResponse` before a response is
    /// allowed into `cache`. An explicit upstream `Cache-Control` is honoured
    /// as-is, `no-store` included — the URL Loading System typically never
    /// offers a no-store response to this delegate method at all, so the
    /// explicit veto here is defence in depth, not the only thing standing in
    /// the way. Only when upstream sends no header at all does this invent
    /// `ApiSchemeHandler.defaultImageCacheControl`, via a `CachedURLResponse`
    /// rewrite (fewer lines than calling `URLCache.storeCachedResponse`
    /// directly, and it runs through the same callback the real session uses).
    static func cachePolicy(for proposed: CachedURLResponse) -> CachedURLResponse? {
        guard let http = proposed.response as? HTTPURLResponse else { return proposed }
        // Redirects are refused (StreamDelegate), so a 3xx IS the final response
        // of its hop and CFNetwork may still offer it here; a 404/410 is
        // heuristically cacheable too. None of those are the poster — caching
        // any of them under the image's URL would poison it until eviction.
        guard (200...299).contains(http.statusCode) else { return nil }
        if let cacheControl = http.value(forHTTPHeaderField: "Cache-Control") {
            return cacheControl.lowercased().contains("no-store") ? nil : proposed
        }
        guard let url = http.url else { return proposed }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { headers[key] = "\(value)" }
        }
        headers["Cache-Control"] = ApiSchemeHandler.defaultImageCacheControl
        guard let rewritten = HTTPURLResponse(url: url, statusCode: http.statusCode,
                                              httpVersion: "HTTP/1.1", headerFields: headers) else {
            return proposed
        }
        return CachedURLResponse(response: rewritten, data: proposed.data,
                                 userInfo: proposed.userInfo, storagePolicy: proposed.storagePolicy)
    }
}

/// What one streamed image hop tells its caller, as it happens: a response
/// (return false to cancel before any body is spent), then chunks, then done.
protocol ImageSink: AnyObject {
    func respond(_ response: HTTPURLResponse) -> Bool
    func receive(_ data: Data)
    func complete(error: Error?)
}

/// One instance shared by every `ImageTransport.stream` call, keyed by task
/// identifier so concurrent hops (should the handler's queue ever stop being
/// serial) do not cross-deliver to the wrong sink.
private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    static let shared = StreamDelegate()

    private let lock = NSLock()
    private var sinks: [Int: (sink: ImageSink, done: () -> Void)] = [:]

    func run(_ task: URLSessionDataTask, sink: ImageSink, done: @escaping () -> Void) {
        lock.lock(); sinks[task.taskIdentifier] = (sink, done); lock.unlock()
        task.resume()
    }

    private func entry(for task: URLSessionTask) -> (sink: ImageSink, done: () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return sinks[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // refused, same as Transport.RefuseRedirects
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let entry = entry(for: dataTask), let http = response as? HTTPURLResponse,
              entry.sink.respond(http) else {
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        entry(for: dataTask)?.sink.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = entry(for: task) else { return }
        entry.sink.complete(error: error)
        lock.lock(); sinks.removeValue(forKey: task.taskIdentifier); lock.unlock()
        entry.done()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(ImageTransport.cachePolicy(for: proposedResponse))
    }
}

// MARK: - The mirror

/// The last body the Pi gave for `GET /api/settings`, in one Keychain item.
///
/// The Keychain rather than `UserDefaults` because since #045 that payload carries
/// every secret — `imdbAuthToken` and `premiumizeApiKey` included — and secrets may
/// persist on clients but not in a plist an iTunes backup hands over in the clear.
/// `AfterFirstUnlock` so a launch into a locked phone (background audio, a Live
/// Activity tap) can still read it.
///
/// Stored as the raw body, as Android does: the page reads it back verbatim, and
/// parsing it here would invent a second schema to keep in step with the Swift one.
enum SettingsMirrorStore {
    private static let service = "eu.illegible.dobbyios.api-mirror"
    private static let account = "api/settings"

    /// #152: the queued patch, in a **second Keychain item** beside the mirror and
    /// not in `UserDefaults`. A patch IS a settings body — it is the secret the
    /// user just typed — so it belongs exactly where the mirror is, and for the
    /// same #045 reason: not in a plist an iTunes backup hands over in the clear.
    private static let pendingAccount = "api/settings.pending"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static var baseQuery: [String: Any] { query(account) }
    private static var pendingQuery: [String: Any] { query(pendingAccount) }

    /// #189: the bytes and the status of the read that produced them. nil data is "no item"
    /// only when the status is errSecItemNotFound; any other non-success is a refusal.
    private static func readWithStatus(_ base: [String: Any]) -> (data: Data?, status: OSStatus) {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return (status == errSecSuccess ? item as? Data : nil, status)
    }

    private static func read(_ base: [String: Any]) -> Data? { readWithStatus(base).data }

    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "api-mirror")

    /// #185: the status of the call that decided the outcome — the update's on success, else
    /// the add's. Before this it returned nothing, so an unsigned build (-34018 on every call),
    /// a locked device or a full keychain dropped the save while the page was told 200.
    /// Logged here, once for every caller, as the OSStatus number only: the item is a secret.
    ///
    /// Added only when the update found no item. Any other refusal (a locked device, entitlement
    /// drift, a full keychain) leaves the item exactly as it was: the add would be refused for
    /// the same reason, and deleting first — what this did until #185 — destroyed the one good
    /// copy, the whole mirror or a patch queued and answered 200 earlier. There is no class
    /// migration for a delete to serve: the item has been AfterFirstUnlock since it was created.
    private static func write(_ base: [String: Any], _ body: Data) -> OSStatus {
        guard !body.isEmpty else { return errSecParam }
        let attributes: [String: Any] = [
            kSecValueData as String: body,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updated = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return updated }
        guard updated == errSecItemNotFound else {
            log.error("keychain write failed: OSStatus \(updated, privacy: .public)")
            return updated
        }
        var insert = base
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added != errSecSuccess { log.error("keychain write failed: OSStatus \(added, privacy: .public)") }
        return added
    }

    static func load() -> Data? { read(baseQuery) }

    /// #189: the settings POST's read. `load()` answers nil for a refused read as well as for
    /// no item, and a POST merging over that nil stores a patch-only document over the whole
    /// mirror, every secret the page did not re-send gone. Logged here as the number only.
    static func loadWithStatus() -> (data: Data?, status: OSStatus) {
        let (data, status) = readWithStatus(baseQuery)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("keychain mirror read refused: OSStatus \(status, privacy: .public)")
        }
        return (data, status)
    }

    /// errSecSuccess or the OSStatus the Keychain refused the write with (#185).
    static func save(_ body: Data) -> OSStatus { write(baseQuery, body) }

    /// #185: put the mirror back to what `load()` read before a settings POST whose queue write
    /// was then refused — nil is "there was no mirror item", so the saved one is removed. Keep
    /// going: a refused put-back is logged (write logs its own, the delete here) and nothing
    /// else changes, the page is answered from the queue's status either way.
    static func restoreMirror(_ previous: Data?) {
        guard let previous else {
            let removed = SecItemDelete(baseQuery as CFDictionary)
            if removed != errSecSuccess { log.error("keychain mirror put-back failed: OSStatus \(removed, privacy: .public)") }
            return
        }
        _ = write(baseQuery, previous)
    }

    /// Whether this device holds a settings change the Pi has never seen (#149).
    ///
    /// `UserDefaults` and not the Keychain item: it is one bit, it is not a
    /// secret, and keeping it out of the item means the item stays exactly the
    /// raw body the page reads back verbatim. It has to outlive a force-stop for
    /// the same reason the mirror does — the write it guards was made with the Pi
    /// off, so the next launch is the first chance anything has to get it wrong.
    private static let aheadKey = "eu.illegible.dobbyios.api-mirror.aheadOfServer"

    static var isAheadOfServer: Bool { UserDefaults.standard.bool(forKey: aheadKey) }

    static func markAheadOfServer() { UserDefaults.standard.set(true, forKey: aheadKey) }

    // MARK: - #152: the write-back queue
    //
    // One pending patch, not Android's per-path queue. `MirrorWriteBack` keeps one
    // line per path in a `<path> <METHOD> <body>` format, with a guard refusing a
    // path carrying a space or a newline, because it has four mirrored paths
    // reached over a JS bridge. iOS has exactly one write path — `dobby-api://settings`
    // — so there is no path to delimit, no line format, and no per-path push set.

    /// One lock over the whole queue. `queuePatch` read-merge-writes it from the
    /// WebView's thread while `clearPending(ifStill:)` compares-and-deletes it from
    /// the handler's own queue, and the two must never interleave: a clear landing
    /// between a read and its write drops the newer patch AND releases the hold, so
    /// the user's change is pushed nowhere and the mirror stops protecting it.
    ///
    /// ponytail: one lock over one item, contended by a page write and one push
    /// thread. Per-item locks if a second mirrored write path ever arrives on iOS.
    private static let pendingLock = NSLock()

    /// Take a patch into the queue, accumulated over whatever is already there —
    /// two saves made across two Pi-less sessions must both reach the Pi, and the
    /// later value of a key the user set twice is the one they meant.
    ///
    /// The hold is re-taken here, under the lock, so a drain that landed and
    /// released it between `markAheadOfServer()` and this call cannot leave a
    /// queued patch with nothing holding the mirror for it.
    ///
    /// #185: returns the queue write's status, which the POST answers with. The hold is
    /// re-taken either way: a failed write left any OLDER queued patch in place, and that one
    /// still needs the mirror held for it (with nothing queued, the drain releases it).
    static func queuePatch(_ patch: Data) -> OSStatus {
        pendingLock.lock(); defer { pendingLock.unlock() }
        guard let accumulated = ApiSchemeHandler.mergedPatch(pending: read(pendingQuery), patch: patch) else { return errSecParam }
        let queued = write(pendingQuery, accumulated)
        UserDefaults.standard.set(true, forKey: aheadKey)
        return queued
    }

    static func pendingPatch() -> Data? {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return read(pendingQuery)
    }

    /// Drop the queued patch and release the hold — but only while what is queued
    /// is still the exact bytes that were pushed.
    ///
    /// A save that landed while the push was in flight left a NEWER accumulated
    /// patch under the same item. Clearing that with the confirmation of the older
    /// one would lose the user's latest change and release the hold in the same
    /// step, which is the worst of both: the mirror stops winning and the Pi never
    /// heard the change. Android's `dequeueIf` is the same compare-and-remove.
    static func clearPending(ifStill pushed: Data) {
        pendingLock.lock(); defer { pendingLock.unlock() }
        guard read(pendingQuery) == pushed else { return }
        // #185: logged, not acted on. Keeping the hold over a delete the Keychain refused
        // would pin the mirror for the life of the install, the degradation #152 closed.
        let deleted = SecItemDelete(pendingQuery as CFDictionary)
        if deleted != errSecSuccess { log.error("keychain queue clear failed: OSStatus \(deleted, privacy: .public)") }
        UserDefaults.standard.set(false, forKey: aheadKey)
    }

    /// The hold with nothing behind it, released — a phone upgrading from the #149
    /// build, whose bit was set before a queue existed. Re-checked under the lock,
    /// so a patch queued since the caller looked is never thrown away.
    static func releaseHold() {
        pendingLock.lock(); defer { pendingLock.unlock() }
        guard read(pendingQuery) == nil else { return }
        UserDefaults.standard.set(false, forKey: aheadKey)
    }

    static func imdbAuthToken() -> String? {
        imdbAuthToken(from: load())
    }

    #if DEBUG
    // #184 simulator seam only (`SettingsSelfTest` cred-write / cred-restore): a byte-exact
    // copy of both items and the ahead bit, held in Keychain items beside them, so a round
    // that overwrites a configured field puts the device back exactly as found and no value
    // it held ever leaves the Keychain. Presence bits are not secrets and go to UserDefaults.
    private static let backupMark = "eu.illegible.dobbyios.api-mirror.selftest184"

    static func selfTestBackup() -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        guard UserDefaults.standard.object(forKey: backupMark) == nil else { return false }
        let mirror = read(baseQuery), pending = read(pendingQuery)
        // Verified read-back: a backup that did not land must refuse the round, never let it
        // overwrite a field it cannot put back.
        for (held, item) in [(mirror, query(account + ".selftest184")), (pending, query(pendingAccount + ".selftest184"))] {
            guard let held else { continue }
            guard write(item, held) == errSecSuccess, read(item) == held else { return false }
        }
        UserDefaults.standard.set(["mirror": mirror != nil, "pending": pending != nil, "ahead": isAheadOfServer],
                                  forKey: backupMark)
        return true
    }

    /// A summary of booleans only: whether a backup was held and each item now equals it.
    static func selfTestRestore() -> String {
        pendingLock.lock(); defer { pendingLock.unlock() }
        guard let mark = UserDefaults.standard.dictionary(forKey: backupMark) as? [String: Bool] else { return "none held" }
        var exact: [String] = []
        for (item, live, key) in [(query(account + ".selftest184"), baseQuery, "mirror"),
                                  (query(pendingAccount + ".selftest184"), pendingQuery, "pending")] {
            let held = read(item)
            if mark[key] != true {
                SecItemDelete(live as CFDictionary)
            } else if let held {
                _ = write(live, held)   // the read-back below is what reports it
            } else {
                exact.append("\(key)BackupMissing=true")   // the live item is left as it is
                continue
            }
            exact.append("\(key)Exact=\(read(live) == (mark[key] == true ? held : nil))")
            SecItemDelete(item as CFDictionary)
        }
        UserDefaults.standard.set(mark["ahead"] == true, forKey: aheadKey)
        UserDefaults.standard.removeObject(forKey: backupMark)
        return (exact + ["ahead=\(isAheadOfServer)"]).joined(separator: " ")
    }
    #endif

    /// The JSON-null trap Android hit: since #045 the Pi sends the key with a
    /// literal `null` when it is cleared, which decodes to `NSNull` — `as? String`
    /// is what makes that read as "no token" rather than the string "<null>".
    static func imdbAuthToken(from json: Data?) -> String? {
        guard let json, !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let token = object["imdbAuthToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
