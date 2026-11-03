import Foundation

/// Persists offline downloads to Documents/Offline/<id>/ (visible in Finder on macOS
/// and the Files app on iOS via UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
/// Unlimited size — straight to disk, no Service-Worker cache quota.
///
/// Two URLSessions:
///  - `session` (.default): subtitle sidecars and a book's listing entry and cover (#210)
///    only — small, completion-handler based, which a background session does not allow.
///  - `bgSession` (.background): the media transfers, AUDIOBOOK chapters and VIDEO
///    files alike. iOS suspends the app (and with it any .default task) shortly after
///    it leaves the foreground, which killed video downloads with a timeout; a
///    background session hands the transfer to the system daemon, which needs no
///    Background App Refresh permission and survives suspension and relaunch.
///
/// Sync bridge getters (listNativeOffline/getNativeOffline) can't be served by a WKWebView
/// message handler (those are async), so the index is mirrored into a JS-side cache via
/// `pushIndex` and the getters read from there.
@MainActor
final class OfflineStore: NSObject, ObservableObject {
    /// Pushes the full index JSON into the web's `window.Dobby._offline` cache.
    var pushIndex: ((String) -> Void)?
    /// Reports a single download progress/status event to the web.
    var reportProgress: ((String) -> Void)?

    /// Set by the app delegate when iOS wakes us to finish background transfers.
    static var backgroundCompletion: (() -> Void)?
    static let bgSessionID = "com.solarflare.dobby.offline.bg"

    private var index: [String: Entry] = [:]
    private var tasks: [String: URLSessionTask] = [:]   // taskKey → task

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private let root: URL
    private let indexURL: URL

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Offline", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        super.init()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        loadIndex()
    }

    /// Create the background session and reclaim any tasks that survived a relaunch.
    /// Call once at app launch (before any download). Only ONE background session may
    /// exist per identifier, so this is the single point of construction.
    func activate() { _ = activeBgSession }

    private var boundBgSession: URLSession?
    private var activeBgSession: URLSession {
        if let s = boundBgSession { return s }
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.bgSessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        boundBgSession = s
        s.getAllTasks { tasks in
            let live = tasks.compactMap { t -> (String, URLSessionTask)? in
                guard let key = t.taskDescription else { return nil }
                return (key, t)
            }
            Task { @MainActor in
                for (key, t) in live { self.tasks[key] = t }
                self.failOrphanedDownloads(liveKeys: Set(live.map { $0.0 }))
            }
        }
        return s
    }

    // MARK: Bridge actions — VIDEO (single file)

    func startDownload(_ json: String) {
        guard let p = DownloadPayload.decode(json), !p.videoId.isEmpty else {
            NSLog("Dobby offline: bad download payload"); return
        }
        // #217, #508: URLSession is not WebKit, so PiRequestBlock never sees this. The page's
        // origin is the retired Pi's name, so only the Pi-origin parts are refused: a Pi video
        // URL refuses the whole download, a Pi subtitle row is skipped. Before the folder, the
        // index and any URLSession task.
        if ServerAddresses.isPiOrigin(p.url) { refuseVideoDownload(p.videoId); return }
        guard let dir = contained(p.videoId) else { NSLog("Dobby offline: bad download payload"); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var entry = index[p.videoId] ?? Entry(videoId: p.videoId, kind: "video", title: p.title ?? "", path: nil, subs: [], chapters: nil, bytes: 0, total: 0, status: "preparing")
        if let title = p.title, !title.isEmpty { entry.title = title }

        if let subs = p.subs {
            for s in subs {
                guard let urlStr = s.url, let url = URL(string: urlStr) else { continue }
                if ServerAddresses.isPiOrigin(urlStr) { NSLog("Dobby offline: Pi-origin subtitle skipped"); continue }
                let name = "sub-\(abs((s.lang ?? s.label ?? urlStr).hashValue)).\(subExt(s.mimeType, urlStr))"
                let dest = dir.appendingPathComponent(name)
                downloadSidecar(url, to: dest) { [weak self] ok in
                    guard ok else { return }
                    self?.appendSub(videoId: p.videoId, path: dest.path, lang: s.lang, label: s.label)
                }
            }
        }

        if p.subsOnly == true { index[p.videoId] = entry; saveIndex(p.videoId); return }

        guard let urlStr = p.url, let url = URL(string: urlStr) else {
            fail(p.videoId, "no url"); return
        }
        entry.status = "downloading"
        index[p.videoId] = entry
        saveIndex(p.videoId)
        emit(p.videoId, status: "downloading", bytes: 0, total: 0)

        let key = "video\t\(p.videoId)"
        let task = activeBgSession.downloadTask(with: url)
        task.taskDescription = key
        tasks[key] = task
        task.resume()
    }

    /// #217: an error event the page's handleDownloadProgress already renders (a toast and
    /// the button re-read). Reports only; the index and the video's folder stay as they were.
    private func refuseVideoDownload(_ videoId: String) {
        NSLog("Dobby offline: video download refused (Pi origin)")
        emit(videoId, status: "error", bytes: 0, total: 0, error: "This video was on the Dobby Pi, which is no longer used.")
    }

    // MARK: Bridge actions — BOOK (multi-chapter, background)

    /// #213, #508: every chapter came from the Pi, which is retired, so nothing starts and an
    /// existing entry is untouched. Audiobooks are hidden; how they come back is a later decision.
    /// The answer is an error event the page's handleNativeBookProgress already renders (a toast
    /// and the button re-read). #243 D1: the bookId is read loosely; a payload with no bookId
    /// string has nothing to address, so it is logged only.
    func startBookDownload(_ json: String) {
        NSLog("Dobby offline: book download refused (no Pi)")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let bookId = obj["bookId"] as? String, !bookId.isEmpty else { return }
        let d: [String: Any] = ["videoId": bookId, "kind": "book", "status": "error", "bytes": 0, "total": 0,
                                "error": "Books came from the Dobby Pi, which is no longer used."]
        if let js = try? jsonString(d) { reportProgress?(js) }
    }

    /// #502: cancelling a replacement download (a video whose entry already has its finished file,
    /// the only place `path` is set) stops the transfer and keeps that earlier copy: folder, entry,
    /// status complete. The transfer's partial lives in the session's temp file, not in the folder.
    func cancel(_ id: String) { remove(id, keepFinished: true) }

    func delete(_ id: String) { remove(id, keepFinished: false) }

    /// #243: the kind is read before the entry goes, so a failed save's error event still
    /// reaches the page's book handler. An id outside Offline (".", "..") is refused whole.
    private func remove(_ id: String, keepFinished: Bool) {
        guard let dir = contained(id) else { NSLog("Dobby offline: cancel refused, id outside Offline"); return }
        let kind = index[id]?.kind
        for (key, t) in tasks where key.hasSuffix("\t\(id)") || key.contains("\t\(id)\t") {
            t.cancel(); tasks[key] = nil
        }
        if keepFinished, var e = index[id], kind == "video", let path = e.path,
           FileManager.default.fileExists(atPath: anchored(path)) {
            e.status = "complete"
            index[id] = e
            saveIndex(id)
        } else {
            try? FileManager.default.removeItem(at: dir)
            index[id] = nil
            saveIndex(id, kind: kind)
        }
        emit(id, status: "cancelled", bytes: 0, total: 0)
    }

    /// Full index as a JSON string (array form for `listNativeOffline`).
    func indexJSON() -> String {
        let arr = index.values.map { $0.dict(anchor: anchored) }
        return (try? jsonString(arr)) ?? "[]"
    }

    /// Re-anchors a persisted absolute path onto the CURRENT container `root` —
    /// see `OfflinePathAnchor.swift` for why the stored path goes stale (#125).
    private func anchored(_ stored: String) -> String { anchorOfflinePath(stored, root: root) }

    // MARK: Bookkeeping helpers

    private func appendSub(videoId: String, path: String, lang: String?, label: String?) {
        guard var e = index[videoId] else { return }
        e.subs.append(SubEntry(path: path, lang: lang ?? "", label: label ?? ""))
        index[videoId] = e
        saveIndex(videoId)
    }

    private func markChapter(_ bookId: String, _ name: String, _ status: String) {
        guard var e = index[bookId], var chs = e.chapters else { return }
        if let i = chs.firstIndex(where: { $0.name == name }) {
            chs[i].status = status; e.chapters = chs
            if chs.allSatisfy({ $0.status == "complete" }) { e.status = "complete" }
            else if chs.contains(where: { $0.status == "error" }) && !chs.contains(where: { $0.status == "downloading" }) { e.status = "error" }
            index[bookId] = e
            saveIndex(bookId)
            emitBook(bookId)
        }
    }

    /// #243 D2: a transfer that completes after its download was cancelled was still moved into
    /// Offline/<id>, bytes nothing lists and nothing removes. With no entry left the whole folder
    /// goes, as cancel removes it; a book entry that no longer lists the file loses just that
    /// file. A file its entry owns (a video's entry, a listed chapter) is never touched.
    /// Ceiling: the subtitle and cover sidecars (kilobytes, on the default session) are not covered.
    /// If index.json no longer decodes, loadIndex starts empty, so a late transfer removes that
    /// book's whole folder: orphan cleanup of a folder nothing lists any more, not listed data lost.
    private func dropUnowned(_ id: String, _ name: String) {
        guard let dir = contained(id), let file = contained(id, name) else { return }
        guard let e = index[id] else { try? FileManager.default.removeItem(at: dir); return }
        if e.kind == "book", e.chapters?.contains(where: { $0.name == name }) != true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// #243: every id-built path under Offline that is created, removed or moved comes from here.
    /// Offline/<id>, or Offline/<id>/<name> when a name is given, only while it stays inside its
    /// parent after standardizing; nil for ".", "..", "../x" or "a/../..", which resolve to
    /// Offline itself or above it (a late transfer keyed "." removed Offline and index.json); a "."
    /// or ".." segment anywhere is refused, so no id can alias another id's folder.
    nonisolated private func contained(_ id: String, _ name: String? = nil) -> URL? {
        func under(_ base: URL, _ component: String) -> URL? {
            guard !component.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            let url = base.appendingPathComponent(component).standardizedFileURL
            return url.path.hasPrefix(base.standardizedFileURL.path + "/") ? url : nil
        }
        guard let dir = under(root, id) else { return nil }
        guard let name else { return dir }
        return under(dir, name)
    }

    /// Called once the background session has reported which tasks survived the
    /// relaunch. Anything the index still calls in-flight with no task behind it is
    /// dead — the app was killed before the transfer finished and iOS did not keep
    /// it — so it has to stop claiming to be downloading, or the UI waits forever.
    private func failOrphanedDownloads(liveKeys: Set<String>) {
        for (id, e) in index where e.status == "downloading" || e.status == "preparing" {
            if e.kind == "book" {
                guard let chs = e.chapters else { continue }
                let stillGoing = chs.contains { $0.status == "downloading" && liveKeys.contains("book\t\(id)\t\($0.name)") }
                if stillGoing { continue }
                for ch in chs where ch.status == "downloading" { markChapter(id, ch.name, "error") }
            } else if !liveKeys.contains("video\t\(id)") {
                fail(id, "interrupted")
            }
        }
    }

    private func fail(_ videoId: String, _ error: String) {
        if var e = index[videoId] { e.status = "error"; index[videoId] = e }
        saveIndex(videoId)
        emit(videoId, status: "error", bytes: 0, total: 0, error: error)
    }

    private func emit(_ id: String, status: String, bytes: Int64, total: Int64, error: String? = nil, kind: String? = nil) {
        var d: [String: Any] = ["videoId": id, "status": status, "bytes": bytes, "total": total]
        if let error { d["error"] = error }
        if let kind { d["kind"] = kind }
        if let js = try? jsonString(d) { reportProgress?(js) }
    }

    private func emitBook(_ bookId: String, bytes: Int64 = 0, total: Int64 = 0) {
        guard let e = index[bookId], let chs = e.chapters else { return }
        let done = chs.filter { $0.status == "complete" }.count
        var d: [String: Any] = [
            "videoId": bookId, "kind": "book", "status": e.status,
            "filesDone": done, "filesTotal": chs.count, "bytes": bytes, "total": total,
        ]
        if e.status == "complete" { d["bytes"] = total; d["total"] = total }
        if let js = try? jsonString(d) { reportProgress?(js) }
    }

    /// #483: an on-device row's sidecar URL on `dobby-api:` (the on-device lane) to the lane's cached
    /// file, set by WebContainer (OnDeviceLane.sidecarFile). A hook so this file still compiles alone in its check.
    static var laneSidecar: ((URL) -> URL?)?

    private func downloadSidecar(_ url: URL, to dest: URL, completion: @escaping (Bool) -> Void) {
        // #483: URLSession cannot fetch the custom scheme; the lane already holds the file, or nothing
        // can produce it from here (the row carries no download args), and the row is skipped.
        if url.scheme == AppConfig.apiScheme {
            try? FileManager.default.removeItem(at: dest)
            let ok = Self.laneSidecar?(url).map { (try? FileManager.default.copyItem(at: $0, to: dest)) != nil } ?? false
            if !ok { NSLog("Dobby offline: on-device subtitle not in the lane cache, skipped") }
            DispatchQueue.main.async { completion(ok) }
            return
        }
        let t = session.downloadTask(with: url) { tmp, _, _ in
            guard let tmp else { DispatchQueue.main.async { completion(false) }; return }
            try? FileManager.default.removeItem(at: dest)
            let ok = (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
            DispatchQueue.main.async { completion(ok) }
        }
        t.resume()
    }

    // MARK: Index persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let raw = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        // Everything now transfers on the background session, so a relaunch may find
        // its tasks still alive. Marking in-flight entries failed here would kill a
        // download that is still running — activeBgSession re-attaches the surviving
        // tasks and failOrphanedDownloads fails only what has none.
        index = raw
    }

    /// #243 D3: a failed write (a full disk after a big download) used to be silent: the session
    /// showed the change and the next launch lost it. `.atomic` keeps the previous index.json
    /// whole when the write fails, and the page gets an error event for `id`, the entry whose
    /// change triggered this save, after the index push so its handlers read the current cache.
    /// Ceiling: the in-memory index is not rolled back, so the page keeps showing the unsaved
    /// state until relaunch.
    /// `kind` is for a caller that already removed the entry (cancel); the default reads it.
    private func saveIndex(_ id: String, kind: String? = nil) {
        let saved = Result { try JSONEncoder().encode(index).write(to: indexURL, options: .atomic) }
        pushIndex?(indexJSON())
        if case .failure(let error) = saved {
            NSLog("Dobby offline: index.json write failed (%@)", error.localizedDescription)
            emit(id, status: "error", bytes: 0, total: 0, error: "The offline list could not be saved. Free some space and try again.", kind: kind ?? index[id]?.kind)
        }
    }

    private func subExt(_ mime: String?, _ url: String) -> String {
        let s = ((mime ?? "") + url).lowercased()
        if s.contains("vtt") { return "vtt" }
        if s.contains("ass") || s.contains("ssa") { return "ass" }
        return "srt"
    }

    private func jsonString(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - URLSessionDownloadDelegate

extension OfflineStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let parts = key.split(separator: "\t").map(String.init)
        Task { @MainActor in
            if parts.first == "book", parts.count >= 2 {
                self.emitBook(parts[1], bytes: totalBytesWritten, total: totalBytesExpectedToWrite)
            } else if parts.count >= 2 {
                self.emit(parts[1], status: "downloading", bytes: totalBytesWritten, total: totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        let parts = key.split(separator: "\t").map(String.init)
        let fm = FileManager.default
        let total = downloadTask.countOfBytesExpectedToReceive

        if parts.first == "book", parts.count >= 3 {
            let bookId = parts[1], fileName = parts[2]
            var moved = false
            if let dir = contained(bookId), let dest = contained(bookId, fileName) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                moved = (try? fm.moveItem(at: location, to: dest)) != nil
            }
            Task { @MainActor in
                self.tasks[key] = nil
                if moved { self.dropUnowned(bookId, fileName) }
                self.markChapter(bookId, fileName, moved ? "complete" : "error")
            }
            return
        }

        // Video single-file
        guard parts.count >= 2 else { return }
        let videoId = parts[1]
        let ext = (downloadTask.response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        var path: String?
        if let dir = contained(videoId), let dest = contained(videoId, ext.isEmpty ? "video.mp4" : "video.\(ext)") {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: location, to: dest)) != nil { path = dest.path }
        }
        Task { @MainActor [path] in
            self.finishVideo(videoId: videoId, key: key, path: path, total: total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription, let error else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        let parts = key.split(separator: "\t").map(String.init)
        Task { @MainActor in
            self.tasks[key] = nil
            if parts.first == "book", parts.count >= 3 { self.markChapter(parts[1], parts[2], "error") }
            else if parts.count >= 2 { self.fail(parts[1], error.localizedDescription) }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Self.backgroundCompletion?()
            Self.backgroundCompletion = nil
        }
    }

    private func finishVideo(videoId: String, key: String, path: String?, total: Int64) {
        tasks[key] = nil
        if let path { dropUnowned(videoId, (path as NSString).lastPathComponent) }
        guard let path, var e = index[videoId] else { fail(videoId, "move failed"); return }
        e.path = path
        e.status = "complete"
        e.total = total
        index[videoId] = e
        saveIndex(videoId)
        emit(videoId, status: "complete", bytes: total, total: total)
    }
}

// MARK: - Models

private struct Entry: Codable {
    let videoId: String
    var kind: String                 // "video" | "book"
    var title: String
    var path: String?                // video file path
    var subs: [SubEntry]
    var chapters: [ChapterFile]?     // book chapters
    var bytes: Int64
    var total: Int64
    var status: String
    /// #210, books only: GET /api/books/{id} as the Pi answered it (a JSON string this side
    /// never interprets beyond the cover fields) and the cover's file name in the book's
    /// folder. Optional, so an index written before #210 still decodes.
    var meta: String? = nil
    var cover: String? = nil

    /// JSON shape the web reads (`window.Dobby._offline` entries). `anchor` re-bases
    /// a stored absolute path onto the app's current container (#125: the container
    /// UUID in `path`/`uri` goes stale across every app update/reinstall).
    func dict(anchor: (String) -> String) -> [String: Any] {
        var d: [String: Any] = ["id": videoId, "videoId": videoId, "kind": kind, "title": title, "status": status]
        if let path { let p = anchor(path); d["path"] = p; d["uri"] = "file://" + p }
        d["subs"] = subs.map { s -> [String: Any] in
            let p = anchor(s.path)
            return ["path": p, "uri": "file://" + p, "lang": s.lang, "label": s.label]
        }
        if let meta { d["meta"] = meta }
        if let cover { d["cover"] = cover }
        if let chapters {
            d["complete"] = (status == "complete")
            d["chapters"] = chapters.map { ["name": $0.name, "status": $0.status] }
        }
        return d
    }
}

private struct SubEntry: Codable {
    let path: String
    let lang: String
    let label: String
}

private struct ChapterFile: Codable {
    let name: String
    var status: String
}

struct DownloadPayload: Decodable {
    let videoId: String
    let url: String?
    let title: String?
    let mimeType: String?
    let subsOnly: Bool?
    let subs: [SubtitleTrack]?

    static func decode(_ json: String) -> DownloadPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DownloadPayload.self, from: data)
    }
}

