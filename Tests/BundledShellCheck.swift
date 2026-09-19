import Foundation

// #151. Two halves that must agree and are written in different places: the markup the
// bundled shell ships with (`BundledShell.rewritingSubresources`) and the address the
// handler answers (`OfflineSchemeHandler.fileURL` + `mime`). This runs them against the
// REAL shell `scripts/copy-app-shell.sh` just copied, not a fixture, so a new script tag
// in index.html or a renamed stylesheet is caught here rather than on the phone.
//
// `Tests/BundledShellWebViewCheck.swift` is the other end of this: it puts the same two
// halves behind a real WKWebView on a dead app-bound origin and measures that the
// rewritten script actually executes.
@main
enum BundledShellCheck {
    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok  " : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    /// Where run-checks.sh put the copy (argv[1]).
    private static var shellRoot: URL {
        URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Dobby/Shell")
    }

    static func main() {
        let root = shellRoot
        let indexPath = root.appendingPathComponent("index.html")
        guard let raw = try? String(contentsOf: indexPath, encoding: .utf8) else {
            print("FAIL no bundled shell at \(indexPath.path) — run scripts/copy-app-shell.sh first")
            exit(1)
        }

        // --- the rewrite, against the real markup -----------------------------------

        let rewritten = BundledShell.rewritingSubresources(raw)
        let base = "\(OfflineSchemeHandler.scheme)://\(BundledShell.host)"

        // Producer end: every boot sub-resource the shipped index.html asks for.
        let scriptsBefore = raw.components(separatedBy: "src=\"/js/").count - 1
        let stylesBefore = raw.components(separatedBy: "href=\"/styles.css\"").count - 1
        print("markup:       \(scriptsBefore) <script src=\"/js/…\">, \(stylesBefore) <link href=\"/styles.css\">")
        check(scriptsBefore >= 20, "the shipped index.html still loads its boot scripts as src=\"/js/…\" (\(scriptsBefore) found)")
        check(stylesBefore == 1, "the shipped index.html still loads exactly one href=\"/styles.css\"")

        // Consumer end: after the rewrite NOTHING boot-critical is left on the Pi origin,
        // and the count moved across rather than some tags being dropped.
        check(!rewritten.contains("src=\"/js/"),
              "no <script src=\"/js/…\"> survives the rewrite — one that did would hit the dead Pi")
        check(!rewritten.contains("href=\"/styles.css\""),
              "no <link href=\"/styles.css\"> survives the rewrite")
        check(rewritten.components(separatedBy: "src=\"\(base)/js/").count - 1 == scriptsBefore,
              "every one of the \(scriptsBefore) script tags moved onto \(base), none dropped")
        check(rewritten.contains("href=\"\(base)/styles.css\""), "the stylesheet moved onto \(base)")

        // `<base href>` was the lazier-looking option and is wrong: it would rebase the
        // page's own /api/… paths and make document.baseURI report the scheme instead of
        // the Pi origin, which is one of the three things #151's done condition checks.
        check(!rewritten.lowercased().contains("<base "),
              "the rewrite does not inject a <base> element (it would rebase /api/… and document.baseURI)")

        // The scheme+host in the markup are the SAME symbols the handler routes on, not a
        // second literal. Pin the literal too, so renaming either end is a deliberate act.
        check(base == "dobby-offline://shell", "sub-resources are addressed on dobby-offline://shell")

        // Everything else is left alone: a rewrite that touched /api/ would move the whole
        // API lane onto a scheme with no server behind it.
        check(rewritten.contains("\"/api/") == raw.contains("\"/api/"),
              "the rewrite leaves /api/ paths on the page's own origin")
        check(rewritten.count > raw.count, "the rewrite only ever lengthens (prefixes), never truncates")

        // --- the handler's second root ----------------------------------------------

        let handler = OfflineSchemeHandler(shellRoot: root)
        func resolved(_ raw: String) -> String? { handler.fileURL(for: URL(string: raw)!)?.path }

        // Depth one: /styles.css is at the shell root, while a downloaded file is always
        // <bookId>/<file> — the old >= 2 rule would have rejected the stylesheet.
        check(resolved("\(base)/styles.css") == root.appendingPathComponent("styles.css").path,
              "dobby-offline://shell/styles.css resolves into the shell root at depth one")
        check(resolved("\(base)/js/01-state-init.js") == root.appendingPathComponent("js/01-state-init.js").path,
              "dobby-offline://shell/js/01-state-init.js resolves into the shell root")
        check(FileManager.default.fileExists(atPath: resolved("\(base)/js/01-state-init.js") ?? ""),
              "…and that file is actually in the copy, so the handler would serve bytes")
        check(resolved("\(OfflineSchemeHandler.scheme)://\(BundledShell.host)/../secrets") == nil,
              "a .. escape out of the shell root is refused")

        // The pre-existing lane, unchanged: empty host still means Documents/Offline, and
        // still needs two segments. A mutant that routed everything at the shell breaks
        // every natively-downloaded book, and nothing else in the suite would notice.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Offline", isDirectory: true)
        check(resolved("\(OfflineSchemeHandler.scheme):///book-1/part.m4b")
                == docs.appendingPathComponent("book-1/part.m4b").path,
              "the host-less form still resolves into Documents/Offline, not the shell")
        check(resolved("\(OfflineSchemeHandler.scheme):///lonely.m4b") == nil,
              "the host-less form still refuses a single-segment path")
        check(OfflineSchemeHandler(shellRoot: nil).fileURL(for: URL(string: "\(base)/styles.css")!) == nil,
              "a build with no bundled shell serves nothing on dobby-offline://shell")

        // --- #156: the double-encoded separator --------------------------------------
        //
        // `url.path` has already decoded once, so a DOUBLE-encoded "/" survives
        // `split(separator: "/")` as ONE component and is only turned back into separators
        // by the `.map`, AFTER the `..` guard has looked at it. Measured on this machine
        // before the fix: the two single-encoded rows were refused and the two
        // double-encoded ones resolved to /secret — on BOTH roots, and with
        // `Access-Control-Allow-Origin: *` on the response, so the bytes were readable
        // cross-origin. The fix is containment on the RESOLVED path, because a string
        // check is exactly what the next decoding subtlety defeats.
        //
        // Each row pins three things, so no row can pass vacuously:
        //   1. the path Foundation hands the handler after its OWN single decode — a
        //      mutant that merely mistypes the URL literal changes this and fails here;
        //   2. that the HISTORICAL parse — the one this repo shipped before #156, with the
        //      second `removingPercentEncoding` still in the map — really does leave the
        //      root, so each row stays a documented traversal rather than "a string the
        //      handler happens to dislike". It is written out here rather than referenced
        //      because production no longer contains it;
        //   3. that `fileURL` NEVER HANDS BACK A PATH OUTSIDE ITS ROOT. Not "returns nil":
        //      the property is containment, and which guard achieves it is an
        //      implementation detail. Pinning nil would couple every row to one mechanism,
        //      and it did — removing the redundant second decode turns these inputs from
        //      traversals into harmless in-root names that no longer need refusing, and a
        //      nil assertion calls that a regression when it is the root-cause fix.
        func traversal(_ raw: String, decodesTo wantPath: String, under base: URL, _ label: String) {
            let u = URL(string: raw)!
            let historical = u.path.split(separator: "/")
                .map { String($0).removingPercentEncoding ?? String($0) }
                .reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL.path
            check(u.path == wantPath, "\(label): url.path is \(wantPath) after Foundation's own decode")
            check(!historical.hasPrefix(base.standardizedFileURL.path + "/"),
                  "\(label): the pre-#156 parse landed outside the root, at \(historical)")
            let got = resolved(raw)
            check(got == nil || got!.hasPrefix(base.standardizedFileURL.path + "/"),
                  "\(label): fileURL never lands outside the root")
        }
        traversal("\(base)/js/..%2f..%2fsecret", decodesTo: "/js/../../secret",
                  under: root, "shell root, single-encoded separator")
        traversal("\(base)/js/..%252f..%252fsecret", decodesTo: "/js/..%2f..%2fsecret",
                  under: root, "shell root, DOUBLE-encoded separator")
        traversal("\(base)/%2e%2e/secret", decodesTo: "/../secret",
                  under: root, "shell root, encoded dots")
        traversal("\(OfflineSchemeHandler.scheme):///b/..%252f..%252fsecret", decodesTo: "/b/..%2f..%2fsecret",
                  under: docs, "Documents root, DOUBLE-encoded separator")
        // The separator in the containment prefix is load-bearing, not decoration: drop it
        // and a SIBLING of the root passes, since ".../Offline-secrets" has ".../Offline"
        // as a plain string prefix. Nothing else in the suite would notice.
        traversal("\(OfflineSchemeHandler.scheme):///..%252fOffline-secrets/x", decodesTo: "/..%2fOffline-secrets/x",
                  under: docs, "Documents root, sibling-directory escape")

        // The half that breaks the shipping feature if the fix over-corrects. The web
        // percent-encodes every segment, so real book ids and filenames arrive encoded and
        // must still resolve, DECODED, to the file on disk. A fix that dropped
        // `removingPercentEncoding`, or that refused any path containing a '%', or that
        // compared the raw string against the root, fails right here — and on the phone
        // that is every downloaded book refusing to play.
        check(resolved("\(OfflineSchemeHandler.scheme):///The%20Hobbit%20%232/Ch%201%20%E2%80%93%20A%20Party.m4b")
                == docs.appendingPathComponent("The Hobbit #2")
                       .appendingPathComponent("Ch 1 – A Party.m4b").path,
              "a percent-encoded book id and filename still resolve, decoded, into Documents/Offline")
        check(resolved("\(base)/js/a%20b.js") == root.appendingPathComponent("js/a b.js").path,
              "a percent-encoded shell sub-resource still resolves, decoded, into the shell root")

        // Supervisor review fix. The map's `removingPercentEncoding` was a SECOND decode —
        // `url.path` had already done one — and the producer settles that nothing needed
        // it: BridgeInjection.swift:60 mints every one of these URLs as
        //   'dobby-offline:///' + encodeURIComponent(id) + '/' + encodeURIComponent(name)
        // which encodes exactly once. So it is removed, and this is the case that keeps it
        // removed: a name genuinely containing the literal text "%2F" goes on the wire as
        // "%252F", and one decode must give it back whole. The old double decode split it
        // into two components and served a different file.
        check(resolved("\(OfflineSchemeHandler.scheme):///book/a%252Fb.m4b")
                == docs.appendingPathComponent("book").appendingPathComponent("a%2Fb.m4b").path,
              "a filename literally containing %2F survives as one component — one decode, not two")

        // The separator in the containment prefix, pinned directly. Through fileURL it is
        // now unreachable — with one decode nothing can carry a "/" past the `..` guard —
        // so a mutant dropping it left the whole suite green until this case existed. It
        // is defence for the next caller, not for today's, and that is exactly the kind of
        // clause this ledger keeps finding unpinned.
        let sibling = docs.deletingLastPathComponent().appendingPathComponent("Offline-secrets")
        check(OfflineSchemeHandler.contained(sibling.appendingPathComponent("x"), in: docs) == nil,
              "a SIBLING of the root is not 'under' it, even though its path has the root's as a plain prefix")
        check(OfflineSchemeHandler.contained(docs.appendingPathComponent("book/part.m4b"), in: docs) != nil,
              "and a genuine child still passes, so the clause above is not refusing everything")

        // --- the OTHER half of "this build has no shell" -----------------------------
        //
        // Supervisor review fix. The check above pins that the HANDLER refuses; nothing
        // pinned that indexHTML() returns nil, and the two are not the same thing. The
        // `let html =` half of WebContainer's guard is what routes a shell-less build back
        // to the ordinary load — the behaviour "Continue offline" has always had, and the
        // right one on a box that has paired, because the service worker's cache is keyed
        // to that origin. run-checks.sh pins the guard's TEXT, which proves the code asks
        // for an optional; only this proves one can ever come back empty.
        //
        // Measured: changing `return nil` to `return ""` in indexHTML() left the whole
        // suite GREEN at 17 PASS / 43 ok / 0 FAIL, and with it every shell-less build
        // synthesizes a BLANK document instead of falling back. That is not hypothetical —
        // .github/workflows/testflight.yml checks out dobby-ios alone, so copy-app-shell.sh
        // warns and exits 0 there and EVERY TestFlight build is shell-less today. The
        // unpinned half was the shipping configuration.
        check(BundledShell.indexHTML(root: nil) == nil,
              "a build with no Shell folder returns no HTML, so WebContainer falls back to the ordinary load")

        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-shell-check-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        check(BundledShell.indexHTML(root: emptyDir) == nil,
              "a Shell folder with no index.html returns no HTML too — a half-finished copy must fall back, not blank the screen")
        try? FileManager.default.removeItem(at: emptyDir)

        // And the nil above is not vacuous: the real shell does produce HTML, already
        // rewritten, so the two cases are genuinely distinguishing absence from presence.
        let shipped = BundledShell.indexHTML(root: root)
        check(shipped != nil, "the real bundled shell does produce HTML")
        check(shipped?.contains("src=\"\(base)/js/") == true,
              "and that HTML is the rewritten form, not the raw markup")

        // --- the MIME table ----------------------------------------------------------
        //
        // Before #151 every one of these fell through to application/octet-stream.
        // Measured (BundledShellWebViewCheck, supervisor mutants 3/3b): text/css is
        // load-bearing — without it WebKit does not apply the stylesheet and the shell
        // boots unstyled — while the script type is NOT enforced for a custom scheme,
        // the script ran as octet-stream. So the js assertion below is held HERE and
        // nowhere else; deleting it would go unnoticed by the real WKWebView.
        check(OfflineSchemeHandler.mime(for: "js") == "text/javascript", "js is served as text/javascript")
        check(OfflineSchemeHandler.mime(for: "css") == "text/css", "css is served as text/css")
        check(OfflineSchemeHandler.mime(for: "html") == "text/html", "html is served as text/html")
        check(OfflineSchemeHandler.mime(for: "wasm") == "application/wasm", "wasm is served as application/wasm")
        check(OfflineSchemeHandler.mime(for: "JS") == "text/javascript", "the extension match stays case-insensitive")
        // The media types this handler was built for, still intact.
        check(OfflineSchemeHandler.mime(for: "m4b") == "audio/mp4", "m4b is still audio/mp4")
        check(OfflineSchemeHandler.mime(for: "mkv") == "video/x-matroska", "mkv is still video/x-matroska")
        check(OfflineSchemeHandler.mime(for: "xyz") == "application/octet-stream", "an unknown extension still falls through")

        print(failures == 0 ? "BundledShellCheck: all good" : "BundledShellCheck: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
