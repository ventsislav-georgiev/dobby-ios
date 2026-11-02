import Foundation
import os

/// #483: the Pi's a4k routes answered on the device, the Apple counterpart of dobby-android's
/// FullSearchLane and SubtitlesLane. The page reaches them through `apiUrlFor` (js/01-state-init.js,
/// #484) as `dobby-api://streaming/fullsearch[/partial]` and `dobby-api://subtitles/{a4k-search,
/// fetch, file/<key>/<name>}` once `window.Dobby.a4k` is true, and reads the same bodies and status
/// codes the Pi and Android give it. Decisions and bodies are A4kRouting (pure); this file is the
/// I/O: the settings mirror, Python, Premiumize and the cache directories.
///
/// Threading: `answer` blocks (a full search waits up to a minute) and runs only on
/// ApiSchemeHandler's concurrent a4k queue, never on main, so `PythonRuntime.shared` is never
/// first touched there; ApiSchemeHandler answers the WKURLSchemeTask on main (#169).
/// A `/partial` poll calls into Python while a search waits in it: the waiting call has the GIL
/// released (thread join), so the poll is served in milliseconds.
enum A4kLane {
    typealias Answer = A4kRouting.Answer

    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "a4k")

    /// The settings document (the dobby-api://settings mirror). A seam so a proof can run the lane
    /// without the Keychain.
    static var settings: () -> [String: Any] = {
        SettingsMirrorStore.load().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// Premiumize's cache/check, one flag per hash. A seam for the same reason.
    static var cacheCheck: ([String], String) -> [Bool] = premiumizeCacheCheck

    /// One a4k download at a time across every row (SubtitlesLane.downloadLock, #105): a4kSubtitles
    /// shares one scratch directory and rmtree's it at the start of every download.
    /// ponytail: one global lock, per-row needs a per-call scratch directory in Python first.
    private static let downloadLock = NSLock()
    private static let lockWait = 12.0
    private static let subsWait = 60.0

    /// Caches/<bundle id>/…: the Mac app is not sandboxed, so plain Caches is the user's shared one.
    private static let root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dobby", isDirectory: true)
    static let searchCache = root.appendingPathComponent("a4k-cache", isDirectory: true)
    static let subtitleCache = root.appendingPathComponent("subtitles", isDirectory: true)
    static let profileDir = root.appendingPathComponent("a4k-subs", isDirectory: true)

    /// The answer for one `dobby-api://streaming/…` or `dobby-api://subtitles/…` request.
    static func answer(_ url: URL, _ method: String, _ body: Data?) -> (status: Int, contentType: String, body: Data, cacheControl: String) {
        let path = url.path
        let query = A4kRouting.query(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let started = Date()
        let a: Answer
        switch (url.host?.lowercased() ?? "", path) {
        case ("streaming", "/fullsearch"): a = fullSearch(query)
        case ("streaming", "/fullsearch/partial"): a = partial(query)
        case ("subtitles", "/a4k-search"): a = subSearch(query)
        case ("subtitles", "/fetch"): a = fetch(A4kRouting.fetchFields(query: query, body: method == "POST" ? body : nil))
        case ("subtitles", _) where path.hasPrefix("/file/"): a = file(String(path.dropFirst("/file/".count)))
        default: a = .error(404, "Unknown dobby-api route")
        }
        if path != "/fullsearch/partial" {
            log.info("a4k \(path, privacy: .public) \(a.status) \(Int(Date().timeIntervalSince(started) * 1000))ms bytes=\(a.body.count)")
        }
        // The file route is content-addressed (its name is a hash of the row id); the rest change per call.
        let cacheControl = path.hasPrefix("/file/") && a.status == 200 ? "public, max-age=31536000, immutable" : "no-store"
        return (a.status, a.contentType, a.body, cacheControl)
    }

    /// The lane's cached copy of an offline a4k sidecar URL (OfflineStore.a4kSidecar), or nil.
    static func sidecarFile(_ url: URL) -> URL? {
        let query = A4kRouting.query(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let named = A4kRouting.sidecar(host: url.host, path: url.path, query: query)
        if let id = named.id { return cachedSubtitle(id) }
        guard let name = named.fileName else { return nil }
        let file = subtitleCache.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    // MARK: - Full search

    private static func fullSearch(_ query: [String: String]) -> Answer {
        let settings = settings()
        let apiKey = settings["premiumizeApiKey"] as? String
        let cacheKey: String, params: [String: String], refresh: Bool
        switch A4kRouting.fullSearchPlan(query, apiKey: apiKey) {
        case .answer(let refused): return refused
        case let .search(k, p, r): (cacheKey, params, refresh) = (k, p, r)
        }
        let key = apiKey ?? ""
        // Only the slow scrape is cached; the Premiumize split is recomputed on every answer.
        let cacheFile = searchCache.appendingPathComponent(A4kRouting.cacheFileName(cacheKey))
        if !refresh, let text = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let hit = A4kRouting.parseTsv(text)
            if !hit.isEmpty {
                // LRU by mtime: a hit is touched so the trim keeps it.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheFile.path)
                return .json(200, A4kRouting.streamsJson(hit, cacheCheck(hashes(hit), key), fromCache: true))
            }
        }
        guard let python = PythonRuntime.shared else { return .error(503, "Full search is not in this build") }
        var call: [String: Any] = params
        call["timeout"] = A4kRouting.budgetSeconds
        call["wait"] = A4kRouting.waitSeconds
        let result = parse(python.call("search", json(call)))
        let found = torrents(result["rows"])
        log.info("a4k fullsearch providers=\(progress(result["progress"])?.last ?? 0) results=\(found.count) timedOut=\(result["timedOut"] as? Bool ?? false)")
        guard !found.isEmpty else { return .json(200, "{\"streams\":[]}") }
        writeCache(cacheFile, found, limit: A4kRouting.cacheLimit(settings["a4kCacheSize"]))
        return .json(200, A4kRouting.streamsJson(found, cacheCheck(hashes(found), key), fromCache: false))
    }

    /// Live progress of the running (or last) search; with `cache=1` its rows split by Premiumize.
    private static func partial(_ query: [String: String]) -> Answer {
        guard let python = PythonRuntime.shared else { return .json(200, "{\"exists\":false}") }
        let snapshot = parse(python.call("search_partial", "{}"))
        guard snapshot["exists"] as? Bool == true else { return .json(200, "{\"exists\":false}") }
        let found = torrents(snapshot["rows"])
        var cached: [Bool]?
        if query["cache"] == "1" {
            guard let key = settings()["premiumizeApiKey"] as? String, !key.isEmpty else {
                return .error(401, "Premiumize API key not configured")
            }
            cached = cacheCheck(hashes(found), key)
        }
        return .json(200, A4kRouting.partialJson(found, progress: progress(snapshot["progress"]), cached: cached))
    }

    private static func writeCache(_ file: URL, _ found: [A4kRouting.Torrent], limit: Int) {
        guard limit > 0 else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: searchCache, withIntermediateDirectories: true)
        guard (try? A4kRouting.tsv(found).write(to: file, atomically: true, encoding: .utf8)) != nil else {
            log.error("a4k cache write failed"); return
        }
        let files = (try? fm.contentsOfDirectory(at: searchCache, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "tsv" } ?? []
        guard files.count > limit else { return }
        func mtime(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for old in files.sorted(by: { mtime($0) > mtime($1) }).dropFirst(limit) { try? fm.removeItem(at: old) }
    }

    /// PremiumizeCacheCheck: all false on any failure, so a result just lands on the uncached side.
    /// The key never reaches a log line.
    static func premiumizeCacheCheck(_ hashes: [String], _ apiKey: String) -> [Bool] {
        guard !hashes.isEmpty, !apiKey.isEmpty,
              let key = apiKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://www.premiumize.me/api/cache/check?apikey=" + key) else {
            return [Bool](repeating: false, count: hashes.count)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(hashes.map { "items%5B%5D=" + $0 }.joined(separator: "&").utf8)
        let (data, response) = Transport.sendSync(request)
        guard let status = response?.statusCode, (200..<300).contains(status) else {
            log.info("premiumize cache/check \(response?.statusCode ?? 0), treating all as uncached")
            return [Bool](repeating: false, count: hashes.count)
        }
        return A4kRouting.cachedFlags(data, count: hashes.count)
    }

    // MARK: - Subtitles

    private static func subSearch(_ query: [String: String]) -> Answer {
        let plan = A4kRouting.subSearchPlan(query)
        if let refused = plan.answer { return refused }
        guard let python = PythonRuntime.shared else { return .error(503, "a4k subtitles are not in this build") }
        var params: [String: Any] = ["profileDir": profileDir.path, "settings": subSettings(), "type": plan.type,
                                     "imdb": query["imdbId"] ?? "", "title": query["title"] ?? "", "year": query["year"] ?? "",
                                     "filename": query["filename"] ?? "", "languages": plan.languages]
        if plan.type == "series" {
            params["season"] = query["season"] ?? ""
            params["episode"] = query["episode"] ?? ""
            params["tvshow"] = query["title"] ?? ""  // the Pi's --tvshow, under the addon's own name
        }
        // A search that overran answers an empty list, as the Pi does on a failed script: this leg
        // never holds the picker's gate.
        let result = parse(bounded(subsWait) { python.call("subs", json(params)) } ?? nil)
        let rows = (result["rows"] as? [[Any]] ?? []).compactMap { A4kRouting.Sub(row: $0.map { "\($0)" }) }
        let shapes = rows.map { A4kRouting.subShape($0, cached: cachedSubtitle($0.id) != nil) }
        return .json(200, "{\"subtitles\":[" + shapes.joined(separator: ",") + "]}")
    }

    private static func fetch(_ fields: [String: String]) -> Answer {
        // The Pi's other provider has no lane here; the page sends only a4k rows to this scheme.
        guard fields["provider"] == "a4k" else { return .error(404, "Only a4k subtitles are fetched on this device") }
        let id = fields["id"] ?? ""
        guard let service = fields["a4kService"], !service.isEmpty, let args = fields["a4kArgs"], !args.isEmpty else {
            return .error(400, "Missing a4k service or args")
        }
        let lang = A4kRouting.normalizeLanguage(fields["lang"] ?? "")
        let label = fields["label"]
        if let hit = cachedSubtitle(id) {
            return .json(200, A4kRouting.cachedResponse(hit.lastPathComponent, lang: lang, label: label, fromCache: true))
        }
        // Refused rather than queued: the page retries a 503 on this endpoint and the retry finds
        // the holder's file in the cache above.
        guard downloadLock.lock(before: Date().addingTimeInterval(lockWait)) else {
            log.info("a4k download busy, refused service=\(service, privacy: .public)")
            return .error(503, "Subtitle download busy")
        }
        defer { downloadLock.unlock() }
        if let hit = cachedSubtitle(id) {
            return .json(200, A4kRouting.cachedResponse(hit.lastPathComponent, lang: lang, label: label, fromCache: true))
        }
        guard let python = PythonRuntime.shared else { return .error(503, "a4k subtitles are not in this build") }
        let params: [String: Any] = ["profileDir": profileDir.path, "settings": subSettings(),
                                     "serviceName": service, "actionArgs": args]
        var file = "", reason = ""
        if let out = bounded(subsWait, { python.call("download", json(params)) }) {
            let result = parse(out)
            file = result["file"] as? String ?? ""
            reason = result["error"] as? String ?? ""
        } else {
            reason = "timed out after \(Int(subsWait * 1000))ms"
        }
        let data = file.isEmpty ? nil : FileManager.default.contents(atPath: file)
        // An empty file is not a subtitle: cached, the /file route would serve it for a year (#105).
        guard let data, !data.isEmpty else {
            let why = !reason.isEmpty ? reason : (data == nil ? "no output" : "empty subtitle file")
            log.error("a4k download failed service=\(service, privacy: .public) reason=\(why, privacy: .public)")
            return .error(502, "Subtitle download failed: " + why)
        }
        let name = A4kRouting.fnv1a(id) + "." + A4kRouting.extensionOf(file)
        do {
            try FileManager.default.createDirectory(at: subtitleCache, withIntermediateDirectories: true)
            try data.write(to: subtitleCache.appendingPathComponent(name))
        } catch {
            return .error(500, "Subtitle cache failed: " + error.localizedDescription)
        }
        return .json(200, A4kRouting.cachedResponse(name, lang: lang, label: label, fromCache: false))
    }

    private static func file(_ rest: String) -> Answer {
        guard let name = A4kRouting.fileName(forFilePath: rest),
              let data = FileManager.default.contents(atPath: subtitleCache.appendingPathComponent(name).path) else {
            return .notFound
        }
        return Answer(status: 200, contentType: A4kRouting.contentType(name), body: data)
    }

    /// The first cached file for a row id (SubtitleCache.firstCachedFile), or nil.
    private static func cachedSubtitle(_ id: String) -> URL? {
        let prefix = A4kRouting.fnv1a(id) + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: subtitleCache.path)) ?? []
        return names.sorted().first { $0.hasPrefix(prefix) }.map { subtitleCache.appendingPathComponent($0) }
    }

    private static func subSettings() -> [String: String] {
        let s = settings()
        return A4kRouting.subSettings(osUser: s["openSubtitlesUsername"] as? String, osPass: s["openSubtitlesPassword"] as? String,
                                      subdl: s["subdlApiKey"] as? String, subsource: s["subsourceApiKey"] as? String)
    }

    // MARK: - Plumbing

    /// Runs `work` on another thread and waits at most `seconds`; nil on timeout. An overrun keeps
    /// running in Python (threads cannot be killed), as on Android.
    private static func bounded<T>(_ seconds: Double, _ work: @escaping () -> T?) -> T?? {
        let done = DispatchSemaphore(value: 0)
        let box = NSLock()
        var out: T??
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            box.lock(); out = .some(value); box.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        box.lock(); defer { box.unlock() }
        return out
    }

    private static func hashes(_ found: [A4kRouting.Torrent]) -> [String] { found.map { $0.hash.lowercased() } }

    private static func torrents(_ rows: Any?) -> [A4kRouting.Torrent] {
        (rows as? [[Any]] ?? []).compactMap { A4kRouting.Torrent(row: $0.map { "\($0)" }) }
    }

    /// `[done, providersDone, providersTotal]` with Python's bool as 0 or 1.
    private static func progress(_ raw: Any?) -> [Int]? {
        (raw as? [Any])?.map { ($0 as? NSNumber)?.intValue ?? 0 }
    }

    private static func parse(_ text: String?) -> [String: Any] {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
