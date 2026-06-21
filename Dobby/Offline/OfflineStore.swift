import Foundation

/// Persists offline downloads to Documents/Offline/<id>/ (visible in Finder on macOS
/// and the Files app on iOS via UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
/// Unlimited size — straight to disk, no Service-Worker cache quota.
///
/// Two URLSessions:
///  - `session` (.default): single-file VIDEO downloads + subtitle sidecars (unchanged).
///  - `bgSession` (.background): multi-file AUDIOBOOK chapter downloads — keeps running
///    when the app is backgrounded/suspended and is faster (parallel, no SW overhead).
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
            for t in tasks { Task { @MainActor in
                if let key = t.taskDescription { self.tasks[key] = t }
            } }
        }
        return s
    }

    // MARK: Bridge actions — VIDEO (single file)

    func startDownload(_ json: String) {
        guard let p = DownloadPayload.decode(json), !p.videoId.isEmpty else {
            NSLog("Dobby offline: bad download payload"); return
        }
        let dir = root.appendingPathComponent(p.videoId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var entry = index[p.videoId] ?? Entry(videoId: p.videoId, kind: "video", title: p.title ?? "", path: nil, subs: [], chapters: nil, bytes: 0, total: 0, status: "preparing")
        if let title = p.title, !title.isEmpty { entry.title = title }

        if let subs = p.subs {
            for s in subs {
                guard let urlStr = s.url, let url = URL(string: urlStr) else { continue }
                let name = "sub-\(abs((s.lang ?? s.label ?? urlStr).hashValue)).\(subExt(s.mimeType, urlStr))"
                let dest = dir.appendingPathComponent(name)
                downloadSidecar(url, to: dest) { [weak self] ok in
                    guard ok else { return }
                    self?.appendSub(videoId: p.videoId, path: dest.path, lang: s.lang, label: s.label)
                }
            }
        }

        if p.subsOnly == true { index[p.videoId] = entry; saveIndex(); return }

        guard let urlStr = p.url, let url = URL(string: urlStr) else {
            fail(p.videoId, "no url"); return
        }
        entry.status = "downloading"
        index[p.videoId] = entry
        saveIndex()
        emit(p.videoId, status: "downloading", bytes: 0, total: 0)

        let key = "video\t\(p.videoId)"
        let task = session.downloadTask(with: url)
        task.taskDescription = key
        tasks[key] = task
        task.resume()
    }

    // MARK: Bridge actions — BOOK (multi-chapter, background)

    func startBookDownload(_ json: String) {
        guard let p = BookDownloadPayload.decode(json), !p.bookId.isEmpty, !p.chapters.isEmpty else {
            NSLog("Dobby offline: bad book payload"); return
        }
        let dir = root.appendingPathComponent(p.bookId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Dedup chapter files (multiple chapters can share one file).
        var seen = Set<String>()
        let files = p.chapters.filter { seen.insert($0.fileName).inserted }

        index[p.bookId] = Entry(videoId: p.bookId, kind: "book", title: p.title ?? "", path: nil, subs: [],
                                chapters: files.map { ChapterFile(name: $0.fileName, status: "downloading") },
                                bytes: 0, total: 0, status: "downloading")
        saveIndex()
        emitBook(p.bookId)

        for ch in files {
            guard let url = URL(string: ch.url) else { markChapter(p.bookId, ch.fileName, "error"); continue }
            let key = "book\t\(p.bookId)\t\(ch.fileName)"
            let task = activeBgSession.downloadTask(with: url)
            task.taskDescription = key
            tasks[key] = task
            task.resume()
        }
    }

    func cancel(_ id: String) {
        for (key, t) in tasks where key.hasSuffix("\t\(id)") || key.contains("\t\(id)\t") {
            t.cancel(); tasks[key] = nil
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
        index[id] = nil
        saveIndex()
        emit(id, status: "cancelled", bytes: 0, total: 0)
    }

    func delete(_ id: String) { cancel(id) }

    /// Full index as a JSON string (array form for `listNativeOffline`).
    func indexJSON() -> String {
        let arr = index.values.map { $0.dict }
        return (try? jsonString(arr)) ?? "[]"
    }

    // MARK: Bookkeeping helpers

    private func appendSub(videoId: String, path: String, lang: String?, label: String?) {
        guard var e = index[videoId] else { return }
        e.subs.append(SubEntry(path: path, lang: lang ?? "", label: label ?? ""))
        index[videoId] = e
        saveIndex()
    }

    private func markChapter(_ bookId: String, _ name: String, _ status: String) {
        guard var e = index[bookId], var chs = e.chapters else { return }
        if let i = chs.firstIndex(where: { $0.name == name }) {
            chs[i].status = status; e.chapters = chs
            if chs.allSatisfy({ $0.status == "complete" }) { e.status = "complete" }
            else if chs.contains(where: { $0.status == "error" }) && !chs.contains(where: { $0.status == "downloading" }) { e.status = "error" }
            index[bookId] = e
            saveIndex()
            emitBook(bookId)
        }
    }

    private func fail(_ videoId: String, _ error: String) {
        if var e = index[videoId] { e.status = "error"; index[videoId] = e }
        saveIndex()
        emit(videoId, status: "error", bytes: 0, total: 0, error: error)
    }

    private func emit(_ id: String, status: String, bytes: Int64, total: Int64, error: String? = nil) {
        var d: [String: Any] = ["videoId": id, "status": status, "bytes": bytes, "total": total]
        if let error { d["error"] = error }
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

    private func downloadSidecar(_ url: URL, to dest: URL, completion: @escaping (Bool) -> Void) {
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
        index = raw
        for (k, var e) in index where e.status == "downloading" || e.status == "preparing" {
            // Books resume via the background session (re-attached in activate());
            // leave them "downloading". Stale single-file videos can't resume → error.
            if e.kind == "book" { continue }
            e.status = "error"; index[k] = e
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL) }
        pushIndex?(indexJSON())
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
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let total = downloadTask.countOfBytesExpectedToReceive

        if parts.first == "book", parts.count >= 3 {
            let bookId = parts[1], fileName = parts[2]
            let dir = docs.appendingPathComponent("Offline/\(bookId)", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(fileName)
            try? fm.removeItem(at: dest)
            let moved = (try? fm.moveItem(at: location, to: dest)) != nil
            Task { @MainActor in
                self.tasks[key] = nil
                self.markChapter(bookId, fileName, moved ? "complete" : "error")
            }
            return
        }

        // Video single-file
        guard parts.count >= 2 else { return }
        let videoId = parts[1]
        let dir = docs.appendingPathComponent("Offline/\(videoId)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = (downloadTask.response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        let dest = dir.appendingPathComponent(ext.isEmpty ? "video.mp4" : "video.\(ext)")
        try? fm.removeItem(at: dest)
        let moved = (try? fm.moveItem(at: location, to: dest)) != nil
        Task { @MainActor in
            self.finishVideo(videoId: videoId, key: key, path: moved ? dest.path : nil, total: total)
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
        guard let path, var e = index[videoId] else { fail(videoId, "move failed"); return }
        e.path = path
        e.status = "complete"
        e.total = total
        index[videoId] = e
        saveIndex()
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

    /// JSON shape the web reads (`window.Dobby._offline` entries).
    var dict: [String: Any] {
        var d: [String: Any] = ["id": videoId, "videoId": videoId, "kind": kind, "title": title, "status": status]
        if let path { d["path"] = path; d["uri"] = "file://" + path }
        d["subs"] = subs.map { s -> [String: Any] in
            ["path": s.path, "uri": "file://" + s.path, "lang": s.lang, "label": s.label]
        }
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

struct BookDownloadPayload: Decodable {
    let bookId: String
    let title: String?
    let chapters: [BookChapter]

    struct BookChapter: Decodable {
        let fileName: String
        let url: String
    }

    static func decode(_ json: String) -> BookDownloadPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BookDownloadPayload.self, from: data)
    }
}
