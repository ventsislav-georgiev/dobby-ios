import Foundation

/// #243: the OfflineStore defects #242 found, run against the real class. It writes under
/// Documents/Offline, so run-checks.sh points CFFIXED_USER_HOME at a temporary home and this
/// refuses to start without one: a run must never touch the user's own Documents.
@main
enum OfflineStoreCheck {
    @MainActor static func main() {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty,
              docs.path.hasPrefix(URL(fileURLWithPath: home).standardizedFileURL.path) else {
            FileHandle.standardError.write(Data("FAIL: OfflineStoreCheck needs CFFIXED_USER_HOME set to a scratch home (#243)\n".utf8))
            exit(1)
        }
        // Registration domain only (in memory): the Pi setting on, so startBookDownload gets past
        // its #213 refusals to the payload decode. Nothing is persisted.
        UserDefaults.standard.register(defaults: ["dobby.piEnabled": true])
        let checks: [(String, @MainActor () -> Void)] = [
            ("badBookPayloadGetsAnErrorEvent", badBookPayloadGetsAnErrorEvent),
            ("lateChapterAfterCancelIsDropped", lateChapterAfterCancelIsDropped),
            ("ownedChapterIsKeptUnlistedOneDropped", ownedChapterIsKeptUnlistedOneDropped),
            ("lateVideoAfterCancelIsDroppedOwnedOneKept", lateVideoAfterCancelIsDroppedOwnedOneKept),
            ("failedIndexWriteGetsAnErrorEvent", failedIndexWriteGetsAnErrorEvent),
        ]
        // Names on the command line run just those (one process per check counts failures by name).
        let only = Set(CommandLine.arguments.dropFirst())
        for (name, run) in checks where only.isEmpty || only.contains(name) { run() }
        print("OfflineStoreCheck: all checks passed")
    }

    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let root = docs.appendingPathComponent("Offline", isDirectory: true)

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what) (#243)\n".utf8))
            exit(1)
        }
    }

    final class Events { var all: [[String: Any]] = [] }

    /// A store over an empty Offline root, or over `seed` (index.json as the app writes it).
    @MainActor static func store(seed: String? = nil) -> (OfflineStore, Events) {
        try? FileManager.default.removeItem(at: root)
        if let seed {
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try! Data(seed.utf8).write(to: root.appendingPathComponent("index.json"))
        }
        let s = OfflineStore()
        let ev = Events()
        s.reportProgress = { js in
            if let d = try? JSONSerialization.jsonObject(with: Data(js.utf8)) as? [String: Any] { ev.all.append(d) }
        }
        return (s, ev)
    }

    static func bookSeed(_ id: String, chapters: [String]) -> String {
        let chs = chapters.map { "{\"name\":\"\($0)\",\"status\":\"downloading\"}" }.joined(separator: ",")
        return "{\"\(id)\":{\"videoId\":\"\(id)\",\"kind\":\"book\",\"title\":\"Fake Book\",\"subs\":[],"
            + "\"chapters\":[\(chs)],\"bytes\":0,\"total\":0,\"status\":\"downloading\"}}"
    }

    static func videoSeed(_ id: String) -> String {
        "{\"\(id)\":{\"videoId\":\"\(id)\",\"kind\":\"video\",\"title\":\"Fake Video\",\"subs\":[],"
            + "\"bytes\":0,\"total\":0,\"status\":\"downloading\"}}"
    }

    /// The background session's completion, delivered by hand: a temp file standing in for the
    /// transfer and a never-resumed task carrying the key startBookDownload/startDownload set.
    @MainActor static func finish(_ s: OfflineStore, key: String) {
        let tmp = docs.deletingLastPathComponent().appendingPathComponent("transfer-\(UUID().uuidString)")
        try! Data("fake audio bytes".utf8).write(to: tmp)
        let task = URLSession(configuration: .ephemeral).downloadTask(with: URL(string: "http://127.0.0.1:9/fake")!)
        task.taskDescription = key
        s.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: tmp)
        check(!FileManager.default.fileExists(atPath: tmp.path), "test setup: the delegate did not move the transfer")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))   // the delegate hops to the main actor
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    @MainActor static func entry(_ s: OfflineStore, _ id: String) -> [String: Any]? {
        let arr = (try? JSONSerialization.jsonObject(with: Data(s.indexJSON().utf8))) as? [[String: Any]] ?? []
        return arr.first { $0["videoId"] as? String == id }
    }

    static func errors(_ ev: Events, _ id: String) -> [[String: Any]] {
        ev.all.filter { $0["videoId"] as? String == id && $0["status"] as? String == "error" }
    }

    /// D1: a book payload startBookDownload cannot use was dropped with an NSLog, so the page's
    /// Download button waited on an answer that never came. Both shapes get refuseBookDownload's
    /// book error event: a chapter row that fails the typed decode (bookId still readable) and
    /// an empty chapter list. Nothing is written for either.
    @MainActor static func badBookPayloadGetsAnErrorEvent() {
        let (s, ev) = store()
        s.startBookDownload("{\"bookId\":\"fake-book-1\",\"title\":\"Fake Book\",\"chapters\":[{\"fileName\":\"01.mp3\"}]}")
        s.startBookDownload("{\"bookId\":\"fake-book-1b\",\"chapters\":[]}")
        for id in ["fake-book-1", "fake-book-1b"] {
            let e = errors(ev, id)
            check(e.count == 1 && e[0]["kind"] as? String == "book" && e[0]["error"] as? String == "invalid book request",
                  "D1: a bad book payload for \(id) must get one book error event, got \(ev.all)")
            check(!exists(id), "D1: a bad book payload must not create the book's folder")
        }
        check(s.indexJSON() == "[]", "D1: a bad book payload must not write an index entry")
    }

    /// D2, orphan side: cancel removed the entry and the folder, then the chapter's transfer
    /// completed anyway and was moved into a fresh Offline/<bookId> nothing lists.
    @MainActor static func lateChapterAfterCancelIsDropped() {
        let (s, ev) = store(seed: bookSeed("fake-book-2", chapters: ["01.mp3"]))
        s.cancel("fake-book-2")
        finish(s, key: "book\tfake-book-2\t01.mp3")
        check(!exists("fake-book-2"), "D2: a chapter landing after its book was cancelled must not stay in Offline/fake-book-2")
        check(s.indexJSON() == "[]", "D2: a late chapter must not bring the cancelled entry back")
        check(errors(ev, "fake-book-2").isEmpty, "D2: a late chapter after cancel must not report an error: \(ev.all)")
    }

    /// D2, owned side: a chapter the entry lists keeps its file and completes; a file the entry
    /// does not list is dropped, and the owned one beside it survives that.
    @MainActor static func ownedChapterIsKeptUnlistedOneDropped() {
        let (s, ev) = store(seed: bookSeed("fake-book-3", chapters: ["01.mp3", "02.mp3"]))
        finish(s, key: "book\tfake-book-3\t01.mp3")
        check(exists("fake-book-3/01.mp3"), "D2: a chapter its entry lists must keep its file")
        let chs = entry(s, "fake-book-3")?["chapters"] as? [[String: Any]] ?? []
        check(chs.contains { $0["name"] as? String == "01.mp3" && $0["status"] as? String == "complete" },
              "D2: an owned chapter must still be marked complete: \(s.indexJSON())")
        finish(s, key: "book\tfake-book-3\t99.mp3")
        check(!exists("fake-book-3/99.mp3"), "D2: a file the book's entry does not list must be dropped")
        check(exists("fake-book-3/01.mp3"), "D2: dropping an unlisted file must keep the owned chapter beside it")
        check(errors(ev, "fake-book-3").isEmpty, "D2/D3: a successful save must not report an error: \(ev.all)")
    }

    /// D2's video sibling: the same late completion for a cancelled video, and a live one kept.
    @MainActor static func lateVideoAfterCancelIsDroppedOwnedOneKept() {
        let (s, _) = store(seed: videoSeed("fake-video-1"))
        s.cancel("fake-video-1")
        finish(s, key: "video\tfake-video-1")
        check(!exists("fake-video-1"), "D2: a video landing after it was cancelled must not stay in Offline/fake-video-1")

        let (s2, _) = store(seed: videoSeed("fake-video-2"))
        finish(s2, key: "video\tfake-video-2")
        check(exists("fake-video-2/video.mp4"), "D2: a video its entry owns must keep its file")
        check(entry(s2, "fake-video-2")?["status"] as? String == "complete", "D2: an owned video must still complete: \(s2.indexJSON())")
    }

    /// D3: index.json could not be written (a directory stands in the file's place, as a full
    /// disk refuses the write) and saveIndex swallowed it. The entry whose change triggered the
    /// save, the book whose last chapter just landed, gets a book error event.
    @MainActor static func failedIndexWriteGetsAnErrorEvent() {
        let (s, ev) = store(seed: bookSeed("fake-book-4", chapters: ["01.mp3"]))
        let indexURL = root.appendingPathComponent("index.json")
        try! FileManager.default.removeItem(at: indexURL)
        try! FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: indexURL.appendingPathComponent("blocker"))
        finish(s, key: "book\tfake-book-4\t01.mp3")
        let e = errors(ev, "fake-book-4")
        check(e.count == 1 && e[0]["kind"] as? String == "book",
              "D3: a failed index.json write must report one book error event for fake-book-4, got \(ev.all)")
        try? FileManager.default.removeItem(at: root)
    }
}
