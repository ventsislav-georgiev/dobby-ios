import Foundation
import JavaScriptCore

/// #243 D4: the offline index reaches the page only through the wrapper's _setOffline push after
/// ready, so a tab or Offline Books pass that ran before it kept the empty answer. The injected
/// literal is run in JavaScriptCore with a stub page: the push must call the PWA's
/// refreshOfflineBooksSection, and a page without one (an older PWA) must not throw.
@main
enum BridgeInjectionCheck {
    static func main() {
        let checks: [(String, () -> Void)] = [
            ("setOfflineRefreshesTheOfflineBooksSection", setOfflineRefreshesTheOfflineBooksSection),
            ("setOfflineSkipsAPageWithoutTheRefresh", setOfflineSkipsAPageWithoutTheRefresh),
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
        ctx.evaluateScript("window.Dobby._setOffline([{ videoId: 'fake-book-5', kind: 'book' }]);")
        check(thrown.all.isEmpty, "D4: _setOffline threw: \(thrown.all)")
        check(ctx.evaluateScript("refreshed")?.toInt32() == 1,
              "D4: _setOffline must call window.refreshOfflineBooksSection once per push")
        check(ctx.evaluateScript("seen")?.toString() == "[{\"videoId\":\"fake-book-5\",\"kind\":\"book\"}]",
              "D4: the refresh must run after the cache holds the pushed index")
        check(ctx.evaluateScript("window.Dobby.listNativeOffline()")?.toString() == "[{\"videoId\":\"fake-book-5\",\"kind\":\"book\"}]",
              "D4: _setOffline must still store the pushed index")
    }

    static func setOfflineSkipsAPageWithoutTheRefresh() {
        let (ctx, thrown) = page("")
        ctx.evaluateScript("window.Dobby._setOffline([{ videoId: 'fake-book-6' }]);")
        check(thrown.all.isEmpty, "D4: _setOffline must not throw on a page without refreshOfflineBooksSection: \(thrown.all)")
        check(ctx.evaluateScript("window.Dobby.getNativeOffline('fake-book-6')")?.toString() == "{\"videoId\":\"fake-book-6\"}",
              "D4: _setOffline must store the pushed index on an older page too")
    }
}
