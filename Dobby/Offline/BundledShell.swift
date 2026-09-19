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
/// Only the boot set is rewritten: the 26 `<script src="/js/…">` tags and the one
/// `<link rel="stylesheet" href="/styles.css">`. Those are what a blank page hangs on.
/// ponytail: the icons and `/manifest.json` stay on the Pi origin and 404 against a dead
/// Pi — cosmetic, and they are in the bundle already if that ever matters enough to
/// widen the rule.
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
        return rewritingSubresources(html)
    }

    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "BundledShell")

    /// Pure, and exercised directly by `Tests/BundledShellCheck.swift`. The scheme comes
    /// from `OfflineSchemeHandler` rather than a second literal, so the address the markup
    /// asks for and the address the handler answers cannot drift apart.
    static func rewritingSubresources(_ html: String, scheme: String = OfflineSchemeHandler.scheme) -> String {
        let base = "\(scheme)://\(host)"
        return html
            .replacingOccurrences(of: "src=\"/js/", with: "src=\"\(base)/js/")
            .replacingOccurrences(of: "href=\"/styles.css\"", with: "href=\"\(base)/styles.css\"")
    }
}
