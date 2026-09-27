import Foundation
import JavaScriptCore

/// #243 D4: the offline index reaches the page only through the wrapper's _setOffline push after
/// ready, so a tab or Offline Books pass that ran before it kept the empty answer. The injected
/// literal is run in JavaScriptCore with a stub page: the push must call the PWA's
/// refreshOfflineBooksSection when the finished set changes, and a page without one (an older
/// PWA) must not throw.
@main
enum BridgeInjectionCheck {
    static func main() {
        let checks: [(String, () -> Void)] = [
            ("setOfflineRefreshesTheOfflineBooksSection", setOfflineRefreshesTheOfflineBooksSection),
            ("setOfflineSkipsAPageWithoutTheRefresh", setOfflineSkipsAPageWithoutTheRefresh),
            ("setOfflineRefreshesOnlyWhenTheDoneSetChanges", setOfflineRefreshesOnlyWhenTheDoneSetChanges),
        ]
        let only = Set(CommandLine.arguments.dropFirst())
        for (name, run) in checks where only.isEmpty || only.contains(name) { run() }
        print("BridgeInjectionCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what) (#243)\n".utf8))
            exit(1)
        }
    }

    final class Thrown { var all: [String] = [] }

    /// A stub page (window is the global object, as in WebKit) with the injected literal run in it.
    static func page(_ pwa: String) -> (JSContext, Thrown) {
        let ctx = JSContext()!
        let thrown = Thrown()
        ctx.exceptionHandler = { _, e in thrown.all.append(e?.toString() ?? "?") }
        ctx.evaluateScript("var window = this; var navigator = { userAgent: 'check' };"
            + "var console = { log: function () {}, warn: function () {} };"
            + "window.webkit = { messageHandlers: { dobby: { postMessage: function () {} } } };" + pwa)
        ctx.evaluateScript(BridgeInjection.script(piEnabled: true))
        check(thrown.all.isEmpty && ctx.evaluateScript("typeof window.Dobby._setOffline")?.toString() == "function",
              "test setup: the injected literal did not run: \(thrown.all)")
        return (ctx, thrown)
    }

    static func setOfflineRefreshesTheOfflineBooksSection() {
        // The refresh records what the page's listNativeOffline() answers when it runs: it has to
        // be the pushed index, so the cache is assigned before the refresh, not after.
        let (ctx, thrown) = page("var refreshed = 0, seen = null;"
            + "function refreshOfflineBooksSection() { refreshed++; seen = window.Dobby.listNativeOffline(); }")
        ctx.evaluateScript("window.Dobby._setOffline([{ id: 'fake-book-5', videoId: 'fake-book-5', kind: 'book', status: 'complete' }]);")
        let pushed = "[{\"id\":\"fake-book-5\",\"videoId\":\"fake-book-5\",\"kind\":\"book\",\"status\":\"complete\"}]"
        check(thrown.all.isEmpty, "D4: _setOffline threw: \(thrown.all)")
        check(ctx.evaluateScript("refreshed")?.toInt32() == 1,
              "D4: _setOffline must call window.refreshOfflineBooksSection when a finished book arrives")
        check(ctx.evaluateScript("seen")?.toString() == pushed,
              "D4: the refresh must run after the cache holds the pushed index")
        check(ctx.evaluateScript("window.Dobby.listNativeOffline()")?.toString() == pushed,
              "D4: _setOffline must still store the pushed index")
    }

    /// #243 review: every saveIndex pushes (book start, extras, each chapter, video start and
    /// finish), and renderOfflineBooks rebuilds the section with its group closed, so the push
    /// re-renders only when the finished set changes: complete entries by id, cover and meta.
    /// The #210 backfill lands meta, then the cover, on a book that already finished.
    static func setOfflineRefreshesOnlyWhenTheDoneSetChanges() {
        let (ctx, thrown) = page("var refreshed = 0; function refreshOfflineBooksSection() { refreshed++; }")
        let a = "{ id: 'fake-book-7', videoId: 'fake-book-7', kind: 'book', status: 'complete', title: 'Fake Book' }"
        let bPart = "{ id: 'fake-book-8', videoId: 'fake-book-8', kind: 'book', status: 'downloading', chapters: [{ name: '01.mp3', status: 'complete' }, { name: '02.mp3', status: 'downloading' }] }"
        let b = "{ id: 'fake-book-8', videoId: 'fake-book-8', kind: 'book', status: 'complete', chapters: [{ name: '01.mp3', status: 'complete' }, { name: '02.mp3', status: 'complete' }] }"
        let c = "{ id: 'fake-book-9', videoId: 'fake-book-9', kind: 'book', status: 'complete', title: 'Fake Book' }"
        let cMeta = "{ id: 'fake-book-9', videoId: 'fake-book-9', kind: 'book', status: 'complete', title: 'Fake Book', meta: '{}' }"
        let cCover = "{ id: 'fake-book-9', videoId: 'fake-book-9', kind: 'book', status: 'complete', title: 'Fake Book', meta: '{}', cover: 'cover' }"
        let cRenamed = "{ id: 'fake-book-9', videoId: 'fake-book-9', kind: 'book', status: 'complete', title: 'Fake Book 2', meta: '{}', cover: 'cover' }"
        for (push, want, what) in [
            ("[\(a)]", 1, "the first finished book"),
            ("[\(a)]", 1, "the same set again"),
            ("[\(a), \(bPart)]", 1, "a chapter landing on an unfinished book"),
            ("[\(a), \(b)]", 2, "that book finishing"),
            ("[\(b), \(a)]", 2, "the same set reordered"),
            ("[\(b)]", 3, "one book removed"),
            ("[]", 4, "the last one removed"),
            ("[\(c)]", 5, "a new finished book"),
            ("[\(cMeta)]", 6, "the meta backfill on a finished book"),
            ("[\(cCover)]", 7, "the cover backfill on a finished book"),
            ("[\(cRenamed)]", 7, "an unrelated field changing"),
        ] {
            ctx.evaluateScript("window.Dobby._setOffline(\(push));")
            let got = ctx.evaluateScript("refreshed")?.toInt32() ?? -1
            check(thrown.all.isEmpty && got == want,
                  "D4: after \(what) the refresh count must be \(want), got \(got) \(thrown.all)")
        }
    }

    static func setOfflineSkipsAPageWithoutTheRefresh() {
        let (ctx, thrown) = page("")
        // A finished book, so the push reaches the guard.
        ctx.evaluateScript("window.Dobby._setOffline([{ id: 'fake-book-6', videoId: 'fake-book-6', status: 'complete' }]);")
        check(thrown.all.isEmpty, "D4: _setOffline must not throw on a page without refreshOfflineBooksSection: \(thrown.all)")
        check(ctx.evaluateScript("window.Dobby.getNativeOffline('fake-book-6')")?.toString()
                == "{\"id\":\"fake-book-6\",\"videoId\":\"fake-book-6\",\"status\":\"complete\"}",
              "D4: _setOffline must store the pushed index on an older page too")
    }
}
