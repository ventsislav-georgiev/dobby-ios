import Foundation
import os

/// #483: the Pi's search and subtitle routes answered on the device, the Apple counterpart of
/// dobby-android's own on-device lanes. The page reaches them through `apiUrlFor`
/// (js/01-state-init.js, #484) as `dobby-api://streaming/fullsearch[/partial]` and
/// `dobby-api://subtitles/{search, fetch, file/<key>/<name>}` once `window.Dobby.onDeviceSearch`
/// is true, and reads the same bodies and status codes the Pi and Android give it. Decisions and
/// bodies are OnDeviceRouting (pure); the rows are shaped by the bundled Python entry; this file is
/// the I/O: the settings mirror, Python and the cache directories.
///
/// Threading: `answer` blocks (a full search waits up to a minute) and runs only on
/// ApiSchemeHandler's concurrent lane queue, never on main, so `PythonRuntime.shared` is never
/// first touched there; ApiSchemeHandler answers the WKURLSchemeTask on main (#169).
/// A `/partial` poll calls into Python while a search waits in it: the waiting call has the GIL
/// released (thread join), so the poll is served in milliseconds.
enum OnDeviceLane {
    typealias Answer = OnDeviceRouting.Answer

    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "lane")

    /// The settings document (the dobby-api://settings mirror). A seam so a proof can run the lane
    /// without the Keychain. Handed to Python whole: the entry picks the keys it needs.
    static var settings: () -> [String: Any] = {
        SettingsMirrorStore.load().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// One subtitle download at a time across every row (#105): the downloader shares one scratch
    /// directory and empties it at the start of every download.
    /// ponytail: one global lock, per-row needs a per-call scratch directory in Python first.
    private static let downloadLock = NSLock()
    private static let lockWait = 12.0
    private static let subsWait = 60.0

    /// Caches/<bundle id>/…: the Mac app is not sandboxed, so plain Caches is the user's shared one.
    /// The Python entry keeps its own working directory under `root` and names it itself.
    private static let root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dobby", isDirectory: true)
    static let searchCache = root.appendingPathComponent("search-cache", isDirectory: true)
    static let subtitleCache = root.appendingPathComponent("subtitles", isDirectory: true)

    /// The answer for one `dobby-api://streaming/…` or `dobby-api://subtitles/…` request.
    static func answer(_ url: URL, _ method: String, _ body: Data?) -> (status: Int, contentType: String, body: Data, cacheControl: String) {
        let path = url.path
        let query = OnDeviceRouting.query(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let started = Date()
        let a: Answer
        switch (url.host?.lowercased() ?? "", path) {
        case ("streaming", "/fullsearch"): a = fullSearch(query)
        case ("streaming", "/fullsearch/partial"): a = partial(query)
        case ("subtitles", "/search"): a = subSearch(query)
        case ("subtitles", "/fetch"): a = fetch(OnDeviceRouting.fetchFields(query: query, body: method == "POST" ? body : nil))
        case ("subtitles", _) where path.hasPrefix("/file/"): a = file(String(path.dropFirst("/file/".count)))
        default: a = .error(404, "Unknown dobby-api route")
        }
        if path != "/fullsearch/partial" {
            log.info("lane \(path, privacy: .public) \(a.status) \(Int(Date().timeIntervalSince(started) * 1000))ms bytes=\(a.body.count)")
        }
        // The file route is content-addressed (its name is a hash of the row id); the rest change per call.
        let cacheControl = path.hasPrefix("/file/") && a.status == 200 ? "public, max-age=31536000, immutable" : "no-store"
        return (a.status, a.contentType, a.body, cacheControl)
    }

    /// The lane's cached copy of an offline sidecar URL on the scheme (OfflineStore.laneSidecar), or nil.
    static func sidecarFile(_ url: URL) -> URL? {
        let query = OnDeviceRouting.query(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let named = OnDeviceRouting.sidecar(host: url.host, path: url.path, query: query)
        if let id = named.id { return cachedSubtitle(id) }
        guard let name = named.fileName else { return nil }
        let file = subtitleCache.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    // MARK: - Full search

    private static func fullSearch(_ query: [String: String]) -> Answer {
        guard let python = PythonRuntime.shared else { return .error(503, "Full search is not in this build") }
        let settings = settings()
        if let refused = split(python, settings, []).refused { return refused }
        let cacheKey: String, params: [String: String], refresh: Bool
        switch OnDeviceRouting.fullSearchPlan(query) {
        case .answer(let refused): return refused
        case let .search(k, p, r): (cacheKey, params, refresh) = (k, p, r)
        }
        // Only the slow search is cached; the split is recomputed on every answer.
        let cacheFile = searchCache.appendingPathComponent(OnDeviceRouting.cacheFileName(cacheKey))
        if !refresh, let text = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let hit = OnDeviceRouting.parseTsv(text)
            if !hit.isEmpty {
                // LRU by mtime: a hit is touched so the trim keeps it.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheFile.path)
                return .json(200, OnDeviceRouting.streamsJson(hit, split(python, settings, hit).flags, fromCache: true))
            }
        }
        var call: [String: Any] = params
        call["timeout"] = OnDeviceRouting.budgetSeconds
        call["wait"] = OnDeviceRouting.waitSeconds
        call["settings"] = settings
        call["cacheDir"] = root.path
        let result = parse(python.call("search", json(call)))
        let found = streams(result["streams"])
        log.info("lane fullsearch sources=\(progress(result["progress"])?.last ?? 0) results=\(found.count) timedOut=\(result["timedOut"] as? Bool ?? false)")
        guard !found.isEmpty else { return .json(200, "{\"streams\":[]}") }
        writeCache(cacheFile, found, limit: OnDeviceRouting.cacheLimit(result["cacheSize"]))
        return .json(200, OnDeviceRouting.streamsJson(found, split(python, settings, found).flags, fromCache: false))
    }

    /// Live progress of the running (or last) search; with `cache=1` its rows split as the search's are.
    private static func partial(_ query: [String: String]) -> Answer {
        guard let python = PythonRuntime.shared else { return .json(200, "{\"exists\":false}") }
        let snapshot = parse(python.call("search_partial", "{}"))
        guard snapshot["exists"] as? Bool == true else { return .json(200, "{\"exists\":false}") }
        let found = streams(snapshot["streams"])
        var cached: [Bool]?
        if query["cache"] == "1" {
            let answer = split(python, settings(), found)
            if let refused = answer.refused { return refused }
            cached = answer.flags
        }
        return .json(200, OnDeviceRouting.partialJson(found, progress: progress(snapshot["progress"]), cached: cached))
    }

    private static func writeCache(_ file: URL, _ found: [OnDeviceRouting.Found], limit: Int) {
        guard limit > 0 else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: searchCache, withIntermediateDirectories: true)
        guard (try? OnDeviceRouting.tsv(found).write(to: file, atomically: true, encoding: .utf8)) != nil else {
            log.error("lane cache write failed"); return
        }
        let files = (try? fm.contentsOfDirectory(at: searchCache, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "tsv" } ?? []
        guard files.count > limit else { return }
        func mtime(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for old in files.sorted(by: { mtime($0) > mtime($1) }).dropFirst(limit) { try? fm.removeItem(at: old) }
    }

    /// The cache split, from the Python entry: one flag per row, or the refusal it answers (401
    /// without the key it needs; the lane asks with no rows first). An unreadable answer is all
    /// uncached, so a row just lands on the uncached side.
    private static func split(_ python: PythonRuntime, _ settings: [String: Any],
                              _ found: [OnDeviceRouting.Found]) -> (flags: [Bool], refused: Answer?) {
        let result = parse(python.call("split", json(["settings": settings, "hashes": found.map(\.hash)])))
        if let status = result["status"] as? Int { return ([], .error(status, result["error"] as? String ?? "Refused")) }
        return ((result["cached"] as? [Any] ?? []).map { $0 as? Bool ?? false }, nil)
    }

    // MARK: - Subtitles

    private static func subSearch(_ query: [String: String]) -> Answer {
        let plan = OnDeviceRouting.subSearchPlan(query)
        if let refused = plan.answer { return refused }
        guard let python = PythonRuntime.shared else { return .error(503, "On-device subtitles are not in this build") }
        var params: [String: Any] = ["cacheDir": root.path, "settings": settings(), "type": plan.type,
                                     "imdb": query["imdbId"] ?? "", "title": query["title"] ?? "", "year": query["year"] ?? "",
                                     "filename": query["filename"] ?? "", "languages": plan.languages]
        if plan.type == "series" {
            params["season"] = query["season"] ?? ""
            params["episode"] = query["episode"] ?? ""
            params["tvshow"] = query["title"] ?? ""  // the Pi's --tvshow
        }
        // A search that overran answers an empty list, as the Pi does on a failed script: this leg
        // never holds the picker's gate.
        let result = parse(bounded(subsWait) { python.call("subs", json(params)) } ?? nil)
        let rows = result["subtitles"] as? [[String: Any]] ?? []
        return .json(200, OnDeviceRouting.subtitlesJson(rows) { cachedSubtitle($0) != nil })
    }

    /// The row's fields go to Python whole: it refuses a row it cannot download (404 or 400) and
    /// downloads the rest; this side keeps the cache, the lock and the answer.
    private static func fetch(_ fields: [String: String]) -> Answer {
        let id = fields["id"] ?? ""
        let lang = OnDeviceRouting.normalizeLanguage(fields["lang"] ?? "")
        let label = fields["label"]
        if let hit = cachedSubtitle(id) {
            return .json(200, OnDeviceRouting.cachedResponse(hit.lastPathComponent, lang: lang, label: label, fromCache: true))
        }
        // Refused rather than queued: the page retries a 503 on this endpoint and the retry finds
        // the holder's file in the cache above.
        guard downloadLock.lock(before: Date().addingTimeInterval(lockWait)) else {
            log.info("lane download busy, refused")
            return .error(503, "Subtitle download busy")
        }
        defer { downloadLock.unlock() }
        if let hit = cachedSubtitle(id) {
            return .json(200, OnDeviceRouting.cachedResponse(hit.lastPathComponent, lang: lang, label: label, fromCache: true))
        }
        guard let python = PythonRuntime.shared else { return .error(503, "On-device subtitles are not in this build") }
        let params: [String: Any] = ["cacheDir": root.path, "settings": settings(), "fields": fields]
        var file = "", reason = ""
        if let out = bounded(subsWait, { python.call("download", json(params)) }) {
            let result = parse(out)
            if let status = result["status"] as? Int {
                return .error(status, result["error"] as? String ?? "Subtitle refused")
            }
            file = result["file"] as? String ?? ""
            reason = result["error"] as? String ?? ""
        } else {
            reason = "timed out after \(Int(subsWait * 1000))ms"
        }
        let data = file.isEmpty ? nil : FileManager.default.contents(atPath: file)
        // An empty file is not a subtitle: cached, the /file route would serve it for a year (#105).
        guard let data, !data.isEmpty else {
            let why = !reason.isEmpty ? reason : (data == nil ? "no output" : "empty subtitle file")
            log.error("lane download failed reason=\(why, privacy: .public)")
            return .error(502, "Subtitle download failed: " + why)
        }
        let name = OnDeviceRouting.fnv1a(id) + "." + OnDeviceRouting.extensionOf(file)
        do {
            try FileManager.default.createDirectory(at: subtitleCache, withIntermediateDirectories: true)
            try data.write(to: subtitleCache.appendingPathComponent(name))
        } catch {
            return .error(500, "Subtitle cache failed: " + error.localizedDescription)
        }
        return .json(200, OnDeviceRouting.cachedResponse(name, lang: lang, label: label, fromCache: false))
    }

    private static func file(_ rest: String) -> Answer {
        guard let name = OnDeviceRouting.fileName(forFilePath: rest),
              let data = FileManager.default.contents(atPath: subtitleCache.appendingPathComponent(name).path) else {
            return .notFound
        }
        return Answer(status: 200, contentType: OnDeviceRouting.contentType(name), body: data)
    }

    /// The first cached file for a row id (SubtitleCache.firstCachedFile), or nil.
    private static func cachedSubtitle(_ id: String) -> URL? {
        let prefix = OnDeviceRouting.fnv1a(id) + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: subtitleCache.path)) ?? []
        return names.sorted().first { $0.hasPrefix(prefix) }.map { subtitleCache.appendingPathComponent($0) }
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

    private static func streams(_ rows: Any?) -> [OnDeviceRouting.Found] {
        (rows as? [[Any]] ?? []).compactMap { OnDeviceRouting.Found(row: $0) }
    }

    /// `[done, sourcesDone, sourcesTotal]` with Python's bool as 0 or 1.
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
