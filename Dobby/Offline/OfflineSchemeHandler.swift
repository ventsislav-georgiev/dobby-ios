import Foundation
import WebKit

/// Serves natively-downloaded offline files to the web's `<audio>`/`<video>` over a
/// custom scheme, because a WKWebView page loaded over https cannot load `file://`
/// resources (cross-scheme), and natively-downloaded books are NOT in the SW cache.
///
/// URL shape: `dobby-offline:///<bookId>/<fileName>` (each segment percent-encoded by
/// the web). Honors HTTP `Range` so audio scrubbing works. Streams in chunks so a
/// large .m4b never loads fully into memory.
///
/// Since #151 it has a second root, picked by the URL's *host*: `dobby-offline://shell/…`
/// serves the bundled app shell out of the app bundle, which is how a never-paired
/// device's simulated document (`BundledShell`) reaches its own scripts and stylesheet.
/// The empty-host form above is unchanged and still means Documents/Offline.
final class OfflineSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "dobby-offline"

    private let root: URL
    private let shellRoot: URL?
    private let queue = DispatchQueue(label: "com.solarflare.dobby.offline-scheme", qos: .userInitiated)
    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    /// `shellRoot` is injectable only so `Tests/BundledShellWebViewCheck.swift` can point
    /// a real WKWebView at a real directory; the app always takes the default.
    init(shellRoot: URL? = BundledShell.root) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Offline", isDirectory: true)
        self.shellRoot = shellRoot
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); active.insert(id); lock.unlock()

        guard let url = task.request.url, let file = fileURL(for: url),
              FileManager.default.fileExists(atPath: file.path) else {
            finish(task, id, notFound: true); return
        }
        let rangeHeader = task.request.value(forHTTPHeaderField: "Range")

        queue.async { [weak self] in
            self?.serve(task: task, id: id, file: file, rangeHeader: rangeHeader)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); active.remove(id); lock.unlock()
    }

    // MARK: - Serving

    private func serve(task: WKURLSchemeTask, id: ObjectIdentifier, file: URL, rangeHeader: String?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            finish(task, id, notFound: true); return
        }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let total = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mime = Self.mime(for: file.pathExtension)

        var start: Int64 = 0
        var end: Int64 = total - 1
        let partial = parseRange(rangeHeader, total: total, start: &start, end: &end)

        var headers = [
            "Content-Type": mime,
            "Accept-Ranges": "bytes",
            "Content-Length": "\(max(0, end - start + 1))",
            "Access-Control-Allow-Origin": "*",
        ]
        if partial {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        }
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: partial ? 206 : 200,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            finish(task, id, notFound: true); return
        }
        guard send(task, id, { $0.didReceive(response) }) else { return }

        if start > 0 { try? handle.seek(toOffset: UInt64(start)) }
        var remaining = end - start + 1
        let chunkSize = 256 * 1024
        while remaining > 0 {
            lock.lock(); let stillActive = active.contains(id); lock.unlock()
            guard stillActive else { return }   // web cancelled (seek/teardown)
            let want = Int(min(Int64(chunkSize), remaining))
            let data = handle.readData(ofLength: want)
            if data.isEmpty { break }
            remaining -= Int64(data.count)
            guard send(task, id, { $0.didReceive(data) }) else { return }
        }
        finish(task, id, notFound: false)
    }

    /// WKURLSchemeTask throws an ObjC exception if touched after stop — guard every call.
    /// The check-then-call is atomic with `lock` held across `body(task)`, not
    /// just across the check: `webView(_:stop:)` also takes `lock` to remove
    /// `id`, so a `stop` racing a WebKit call on this task now either happens
    /// fully before or fully after it, never in between (same fix as #071 in
    /// ApiSchemeHandler.send/finish). `didReceive`/`didFinish` are fast,
    /// non-reentrant WebKit calls, so holding `lock` across them is cheap and
    /// never risks a deadlock back into this class.
    private func send(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ body: (WKURLSchemeTask) -> Void) -> Bool {
        onMain {
            lock.lock(); defer { lock.unlock() }
            guard active.contains(id) else { return false }
            body(task)
            return true
        }
    }

    /// Every WebKit call on a `WKURLSchemeTask` goes through here, on the MAIN THREAD.
    ///
    /// Measured on an iPhone (iOS 18.7, Debug build, `DOBBY_NO_SERVER=1
    /// DOBBY_AUTO_OFFLINE=1`): serving the bundled shell from `queue`,
    /// `task.didReceive(response)` for the FIRST subresource never returned. It was
    /// holding `lock`, so the main thread wedged on the next `webView(_:start:)`, the
    /// remaining 26 scripts were never requested, and the app was a black screen with
    /// nothing logged — the reported TestFlight symptom for build 202609200452.
    /// With the same binary and the same bytes, hopping to main turned 3-of-27
    /// subresources started / 0 finished into 27 started / 27 finished plus
    /// `didFinish`, and the shell rendered.
    ///
    /// Note the failure is document-shaped, not scheme-shaped: this same handler serves
    /// downloaded media off `queue` on a NETWORKED document without hanging, which is
    /// why it survived every round before #151 put a `loadSimulatedRequest` document in
    /// front of it. Do not read "media still plays" as proof this is safe.
    ///
    /// `Thread.isMainThread` is load-bearing and not an optimisation: `webView(_:start:)`
    /// and `webView(_:stop:)` are already on main and both call in here, so an
    /// unconditional `DispatchQueue.main.sync` would deadlock on the not-found path.
    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }


    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, notFound: Bool) {
        onMain {
            lock.lock(); defer { lock.unlock() }
            guard active.contains(id) else { return }
            if notFound, let url = task.request.url,
               let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) {
                task.didReceive(resp)
            }
            task.didFinish()
            active.remove(id)
        }
    }

    // MARK: - Helpers

    /// `dobby-offline:///<bookId>/<fileName>` → Offline/<bookId>/<fileName>, and
    /// `dobby-offline://shell/<path>` → the bundled shell's <path>. Both reject `..`.
    ///
    /// The two roots differ in their minimum depth on purpose: a downloaded file is always
    /// `<bookId>/<fileName>`, while the shell has `/styles.css` at depth one.
    ///
    /// #156. The `..` guard below is NOT enough on its own, measured: `url.path` has
    /// already decoded once, so a DOUBLE-encoded separator survives the split as one
    /// component (`/js/..%252f..%252fsecret` → path `/js/..%2f..%2fsecret` → parts
    /// `["js", "../../secret"]`) and the `map` only turns it back into separators after
    /// the guard has looked at it. `appendingPathComponent` then embeds those separators
    /// and the result lands outside the root. That is a decoding subtlety, and any string
    /// check invites the next one, so the load-bearing guard is `contained(_:in:)` on the
    /// RESOLVED path instead. The `..` guard stays because it costs one line and refuses
    /// the single-encoded forms earlier.
    ///
    /// Decoding itself is load-bearing and must not be dropped: the web percent-encodes
    /// every segment, so real book ids and filenames arrive encoded (see the doc comment
    /// on this type). Measured, as mutant 2b of #156: take the decode away entirely
    /// (`url.path(percentEncoded: true)` with no `map`) and both positive cases below go
    /// red — `The%20Hobbit%20%232` stops naming a directory on disk.
    ///
    /// But note WHICH decode is load-bearing, because there used to be two. `url.path`
    /// already decodes once; the `removingPercentEncoding` that used to sit in the `map`
    /// was a SECOND decode, and it is now gone. The producer settles it: the only thing
    /// that mints these URLs is `BridgeInjection.swift:60`,
    ///
    ///     return 'dobby-offline:///' + encodeURIComponent(id) + '/' + encodeURIComponent(name);
    ///
    /// which encodes exactly once, so one decode is exactly right and the second had no
    /// caller that needed it. What it DID do was turn `%252f` into a separator, and
    /// mis-resolve any name genuinely containing the literal text `%2F` — `a%252Fb` on the
    /// wire is the file `a%2Fb`, and the second decode split it into `a/b`. Pinned below.
    func fileURL(for url: URL) -> URL? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.contains("..") else { return nil }
        if url.host == BundledShell.host {
            guard let shellRoot, !parts.isEmpty else { return nil }
            return Self.contained(parts.reduce(shellRoot) { $0.appendingPathComponent($1) }, in: shellRoot)
        }
        guard parts.count >= 2 else { return nil }
        return Self.contained(parts.reduce(root) { $0.appendingPathComponent($1) }, in: root)
    }

    /// The candidate, or nil if it does not lexically resolve to something under `root`.
    /// `standardizedFileURL` is what collapses `..`, so this is a check on where the path
    /// actually LANDS, not on what it looked like going in. The separator in the prefix is
    /// deliberate: without it `…/Offline-secrets` would pass as "under" `…/Offline`.
    /// Internal rather than private only so `Tests/BundledShellCheck.swift` can reach it.
    /// It has to: once the redundant second decode was removed, no URL can carry a
    /// separator past the `..` guard any more, so the separator clause below is
    /// unreachable through `fileURL` and would sit unpinned if it were only tested from
    /// there. It stays because it is what holds if a future caller hands this a component
    /// it built some other way — measured, a supervisor mutant that dropped it left the
    /// whole suite green.
    static func contained(_ candidate: URL, in root: URL) -> URL? {
        let base = root.standardizedFileURL.path
        let landed = candidate.standardizedFileURL.path
        guard landed.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        return candidate
    }

    private func parseRange(_ header: String?, total: Int64, start: inout Int64, end: inout Int64) -> Bool {
        guard let header, header.hasPrefix("bytes="), total > 0 else { return false }
        let spec = header.dropFirst("bytes=".count)
        let comps = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = comps.first else { return false }
        if let s = Int64(first) {
            start = s
            if comps.count > 1, let e = Int64(comps[1]), e >= s { end = min(e, total - 1) }
            else { end = total - 1 }
        } else if comps.count > 1, let suffix = Int64(comps[1]) {   // bytes=-N (last N)
            start = max(0, total - suffix); end = total - 1
        } else { return false }
        start = max(0, min(start, total - 1))
        end = max(start, min(end, total - 1))
        return true
    }

    /// #151 added the shell's types, and the two that matter were measured rather than
    /// assumed (`Tests/BundledShellWebViewCheck.swift`, supervisor mutants 3 and 3b):
    ///
    /// - `text/css` is LOAD-BEARING. Serve the stylesheet as `application/octet-stream`
    ///   and WebKit does not apply it — the measured mutant left the page's custom
    ///   property unset, i.e. the shell boots unstyled.
    /// - `text/javascript` is NOT enforced here. Deleting the `js` case left the
    ///   classic `<script src="dobby-offline://shell/js/…">` executing anyway, so WebKit
    ///   is lenient about a custom scheme's script MIME type. It is emitted regardless,
    ///   because it is the correct type and nothing should rest on that leniency —
    ///   `BundledShellCheck` is what holds it, not the WKWebView.
    ///
    /// Everything else here is ordinary correctness; before #151 all of it fell through
    /// to `application/octet-stream`.
    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "m4a", "m4b", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "opus", "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        default: return "application/octet-stream"
        }
    }
}
