import AppKit
import Foundation
import WebKit

// #614: the launch cover (ContentView) lifts on ShellNavigation.onPainted, the Android TV launch hold
// (MainActivity.awaitPaint, #458): after the page finishes, `window.dobbyPainted` is polled and the cover
// holds only while it reads false, at most paintWait. Driven here in a real WKWebView on fixture shells:
// a page that turns true later, a page that never sets it, a page stuck on false.
//
// macOS only — `run-checks.sh` skips it elsewhere, same as the other WebView checks.
@main
enum LaunchHoldWebViewCheck {
    private static let origin = URL(string: "https://shell-origin.example")!
    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok  " : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    private static func pump(_ seconds: TimeInterval, _ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func shell(_ script: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dobby-launch-hold-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? "<!DOCTYPE html><html><head><script>\(script)</script></head><body>shell</body></html>"
            .write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return root
    }

    /// Seconds from the page's didFinish-ready state to onPainted, or nil when it never came within `limit`.
    private static func run(_ script: String, paintWait: TimeInterval, limit: TimeInterval) -> (finished: TimeInterval?, painted: TimeInterval?) {
        let root = shell(script)
        defer { try? FileManager.default.removeItem(at: root) }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let nav = ShellNavigation(shellRoot: root)
        nav.paintWait = paintWait
        let start = Date()
        var painted: TimeInterval?
        nav.onPainted = { painted = Date().timeIntervalSince(start) }
        webView.navigationDelegate = nav
        nav.load(origin, in: webView)
        pump(10) { !webView.isLoading }
        let finished = webView.isLoading ? nil : Date().timeIntervalSince(start)
        pump(limit) { painted != nil }
        return (finished, painted)
    }

    static func main() {
        _ = NSApplication.shared

        check(ShellNavigation.launchHolds(false, timedOut: false), "launchHolds: false with time left holds")
        check(!ShellNavigation.launchHolds(false, timedOut: true), "launchHolds: false past the wait releases")
        check(!ShellNavigation.launchHolds(true, timedOut: false), "launchHolds: true releases")
        check(!ShellNavigation.launchHolds(nil, timedOut: false), "launchHolds: an older page's undefined (nil) releases")
        check(!ShellNavigation.launchHolds("false", timedOut: false), "launchHolds: only a boolean false holds")

        let later = run("window.dobbyPainted = false; setTimeout(function () { window.dobbyPainted = true; }, 1200);",
                        paintWait: 6, limit: 8)
        print("turns true at 1.2 s: finished \(later.finished.map { String(format: "%.2f", $0) } ?? "nil") painted \(later.painted.map { String(format: "%.2f", $0) } ?? "nil")")
        check(later.finished != nil && (later.painted ?? 0) >= 1.2 && (later.painted ?? 99) < 2.5,
              "a page drawing for 1.2 s: the cover holds past didFinish and lifts once dobbyPainted is true")

        let none = run("window.other = 1;", paintWait: 6, limit: 3)
        print("never sets it: painted \(none.painted.map { String(format: "%.2f", $0) } ?? "nil")")
        check((none.painted ?? 99) < 1.0, "a page without dobbyPainted: the cover lifts on didFinish")

        let stuck = run("window.dobbyPainted = false;", paintWait: 1.5, limit: 5)
        print("stuck on false, wait 1.5 s: painted \(stuck.painted.map { String(format: "%.2f", $0) } ?? "nil")")
        check((stuck.painted ?? 0) >= 1.5 && (stuck.painted ?? 99) < 3, "a page stuck on false: the cover lifts at paintWait")

        if failures > 0 {
            print("FAIL: \(failures) launch hold check(s) (#614)")
            exit(1)
        }
        print("PASS: the launch cover holds until window.dobbyPainted, bounded, as on Android TV (#614)")
    }
}
