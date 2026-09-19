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

        // --- the MIME table ----------------------------------------------------------
        //
        // WebKit refuses to execute a classic <script> whose Content-Type is not a
        // JavaScript MIME type, and refuses a stylesheet that is not text/css. Before
        // #151 every one of these fell through to application/octet-stream, which would
        // have served all 27 boot sub-resources into a blank page with nothing logged.
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
