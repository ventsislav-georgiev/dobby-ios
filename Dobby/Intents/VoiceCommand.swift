import Foundation

/// A Siri command waiting for the web app to be ready to run it.
///
/// App Intents run inside the app process, but Siri can fire one before (or while)
/// the WKWebView finishes loading. So intents park a command here and the bridge
/// drains it — on `ready` if the page is still loading, immediately otherwise.
@MainActor
final class VoiceCommandQueue {
    static let shared = VoiceCommandQueue()

    private var pending: [String: Any]?
    /// Set by WebBridge once the page has announced itself.
    var deliver: (([String: Any]) -> Void)?

    func send(_ command: [String: Any]) {
        if let deliver {
            deliver(command)
        } else {
            pending = command   // only the latest matters; a queue of stale plays helps nobody
        }
    }

    /// Called by the bridge when the web app reports `ready`.
    func flush() {
        guard let command = pending, let deliver else { return }
        pending = nil
        deliver(command)
    }
}
