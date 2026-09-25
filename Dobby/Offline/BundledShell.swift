import Foundation
import os

/// The app shell that `scripts/copy-app-shell.sh` put in the bundle, prepared for
/// `WKWebView.loadSimulatedRequest` — the iOS analogue of Android's
/// `MainActivity.loadBundledShell()` (dobby-android/…/MainActivity.java:381-394).
///
/// Why a rewrite is needed here and not on Android. Android intercepts the Pi's own
/// `/js/…` URLs with `shouldInterceptRequest`, so its copy of `index.html` ships
/// untouched. `WKURLSchemeHandler` is refused for `https` — `WKWebView.handlesURLScheme("https")`
/// is `true` — and #150 measured that the navigation delegate is not a back door either:
/// across four phases it fired exactly one `decidePolicyFor` per phase, the main document,
/// and none for any sub-resource. So an iOS shell can only reach its own bytes by
/// addressing a scheme the app *does* handle, which means the markup has to say so.
///
/// `<base href>` is not the lazier spelling of this and was rejected: it would rebase
/// the page's `/api/…` paths onto the custom scheme too, and it would make
/// `document.baseURI` report the scheme rather than the Pi origin — one of the three
/// things the Pi-less cold start has to get right (#151 done condition).
///
/// Every `src="/…"` / `href="/…"` naming a file the shell actually ships is rewritten —
/// the boot scripts and stylesheet, and since #196 the images too. #151 rewrote only the
/// `/js/` and `/styles.css` prefixes and left `<img src="/icon-smarttube.png?v=3">` on the
/// Pi origin, where #181's `PiRequestBlock` refuses it: the SmartTube mode button drew an
/// empty box on every Pi-off launch. The rule is "the file is in the shell", not a prefix
/// list, so the next asset index.html names is covered without touching this file; a path
/// the shell does not ship (`/`, `/api/…`) stays on the page's own origin. The query
/// (`?v=3`) is kept on the rewritten URL and ignored by the handler, which reads `url.path`.
enum BundledShell {
    /// Host component of the sub-resource URLs, and the discriminator
    /// `OfflineSchemeHandler` routes on: `dobby-offline://shell/js/01-state-init.js`
    /// comes out of the bundle, `dobby-offline:///<bookId>/<file>` out of Documents.
    static let host = "shell"

    /// The folder reference `project.yml` copies into the app bundle, or nil in a build
    /// that has no shell — Android's `hasBundledShell()`, and the same consequence:
    /// the caller falls back to the behaviour it has always had.
    static var root: URL? { Bundle.main.url(forResource: "Shell", withExtension: nil) }

    /// The shell's `index.html`, sub-resources rewritten, ready to hand to
    /// `loadSimulatedRequest(_:responseHTML:)`. Nil when this build carries no shell.
    static func indexHTML(root: URL? = BundledShell.root) -> String? {
        guard let root,
              let html = try? String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
        else {
            // Android logs the same line for the same reason. A build made without the
            // sibling dobby checkout (today: every CI/TestFlight build — see
            // scripts/copy-app-shell.sh) has no shell, and the only difference the user
            // sees is a blank "Continue offline" on a never-paired box. Say so, or a
            // device round spends itself deciding whether the feature or the build is
            // what is missing.
            log.warning("No bundled app shell in this build")
            return nil
        }
        return rewritingSubresources(html, root: root)
    }

    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "BundledShell")

    /// Pure over `html` and the shell directory, and exercised directly by
    /// `Tests/BundledShellCheck.swift` against the real copy. The scheme comes from
    /// `OfflineSchemeHandler` rather than a second literal, so the address the markup asks
    /// for and the address the handler answers cannot drift apart.
    static func rewritingSubresources(_ html: String, root: URL,
                                      scheme: String = OfflineSchemeHandler.scheme) -> String {
        let base = "\(scheme)://\(host)"
        let out = NSMutableString(string: html)
        // Last match first, so each replacement leaves the earlier ranges valid.
        for match in attribute.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            let path = out.substring(with: match.range(at: 2)).removingPercentEncoding ?? ""   // the handler decodes once too
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path,
                                                 isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            out.insert(base, at: match.range(at: 2).location)
        }
        return out as String
    }

    /// `src="/path"` or `href="/path"`, path captured without its `?query` / `#fragment`.
    /// `//host/…` is protocol-relative, not a shell path, so the path may not start with `/`.
    private static let attribute = try! NSRegularExpression(
        pattern: #"\b(src|href)="(/[^/"?#][^"?#]*)[^"]*""#)
}
