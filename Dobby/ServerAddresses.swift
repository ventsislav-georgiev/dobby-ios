import Foundation
import os

/// Multi-homed address book for the Dobby server.
///
/// The web app owns the canonical list (Settings → Dobby server addresses) and
/// pushes it down through the JS bridge on every load; we cache it so a cold
/// start can find the server on whichever network we woke up on — the LAN IP at
/// home, the Tailscale name everywhere else.
///
/// Probing is sequential in preference order, not a parallel race: the last
/// known-good address goes first, so the common case answers on the first probe
/// and only the launch right after a network change pays for a failed one.
///
/// #068: the probe's two budgets are split on purpose, mirroring Android's
/// `ServerAddresses` (dobby-android/.../ServerAddresses.java:28-44, its own #046).
/// Connecting and being answered fail for different reasons and deserve different
/// patience: nothing answers a Pi that is off inside `connectTimeout`, while a Pi
/// that is up but busy (a mid-deploy Swift rebuild, e.g.) can take seconds to
/// answer once TCP/TLS has already gone through — Android measured 2909 ms on a
/// real mid-deploy Pi, under a flat 1500 ms timeout that called it absent
/// (044-report.md:223). So: a short budget to find out if anybody is home, and
/// only once we know somebody is, a long budget to wait for them to speak. The
/// cheap wrong answer this avoids is declaring a slow Pi absent.
enum ServerAddresses {
    private static let listKey = "dobby.serverAddresses"
    private static let lastGoodKey = "dobby.serverAddresses.lastGood"
    private static let logger = Logger(subsystem: "eu.illegible.dobbyios", category: "ServerAddresses")

    /// Connect budget — Android's `CONNECT_TIMEOUT_MS`. A Pi that is off never answers,
    /// so this alone is what a Pi-off launch costs per candidate.
    private static let connectTimeout: TimeInterval = 1.5
    /// Read budget, spent only once the short probe proves somebody is there — Android's
    /// `READ_TIMEOUT_MS`. Sized for a busy Pi, not a dead one.
    private static let readTimeout: TimeInterval = 4.0
    /// The short probe's own budget — Android's `MIN_READ_TIMEOUT_MS`, which doubles as
    /// its `CONNECT_TIMEOUT_MS` here since URLSession has no separate connect timeout.
    private static let shortTimeout: TimeInterval = 1.5

    /// Probe order: last known-good, then the configured list, then the baked default.
    static func candidates() -> [URL] {
        var out: [URL] = []
        append(&out, UserDefaults.standard.string(forKey: lastGoodKey))
        for stored in stored() { append(&out, stored.absoluteString) }
        append(&out, AppConfig.serverURL.absoluteString)
        return out
    }

    /// The configured list alone, in the order the user set — what the editor shows.
    static func stored() -> [URL] {
        var out: [URL] = []
        for raw in UserDefaults.standard.stringArray(forKey: listKey) ?? [] { append(&out, raw) }
        return out
    }

    /// Accepts the JS bridge payload (a JSON string array). Ignores anything unusable.
    static func store(json: String) {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String] else { return }
        var parsed: [URL] = []
        for entry in raw { append(&parsed, entry) }
        guard !parsed.isEmpty else { return } // never let a bad push erase the way back in
        store(parsed)
    }

    static func store(_ addresses: [URL]) {
        UserDefaults.standard.set(addresses.map(\.absoluteString), forKey: listKey)
    }

    /// First candidate that answers `/api/health`, or nil when none do. Also the write
    /// side of `lastGoodKey`, which is what makes "Continue offline" (ContentView.swift)
    /// load the shell on the same origin the service worker's cache is keyed to.
    static func resolve() async -> URL? {
        for origin in candidates() {
            let (outcome, reason) = await probe(origin)
            // Same shape as Android's statusReason/failureReason: origin, verdict, elapsed
            // ms, and — on a miss — why, so a refusal reads differently from a timeout.
            // No secrets: `origin` is a server address, never a credential.
            logger.log("\(origin.absoluteString, privacy: .public): \(reason, privacy: .public)")
            guard outcome == .present else { continue }
            UserDefaults.standard.set(origin.absoluteString, forKey: lastGoodKey)
            return origin
        }
        return nil
    }

    /// What a probe attempt decides between.
    enum ProbeOutcome: Equatable {
        /// Answered inside the short budget — the common case.
        case present
        /// Connected inside the short budget but nothing answered yet: Android's
        /// "connect ok, read pending". Worth the long budget, not a verdict of absent.
        case presentSlow
        /// Never connected inside the short budget — nobody is listening, and Android's
        /// reasoning is that waiting longer would not change that.
        case absent
    }

    /// Pure decision function, exercised directly by `ServerAddressesCheck.swift`: no
    /// networking, just the same "which answer means what" call Android's `answered(int)`
    /// makes. `httpStatus` is nil when the short attempt got no response at all;
    /// `connected` is whether the TCP/TLS handshake completed regardless of that (from
    /// `URLSessionTaskMetrics.connectEndDate` — see `MetricsCollector`).
    static func classify(connected: Bool, httpStatus: Int?) -> ProbeOutcome {
        // A status line — any status line — means the read already finished: it settles
        // the verdict outright and a retry could not change it. Only the no-status case
        // (timed out before answering) is ambiguous enough to fork on `connected`.
        if let status = httpStatus { return (200..<400).contains(status) ? .present : .absent }
        return connected ? .presentSlow : .absent
    }

    /// Raw result of one HTTP attempt: connect + response, no verdict.
    private struct Attempt {
        let httpStatus: Int?
        let connected: Bool
        let elapsedMs: Int
    }

    /// Recovers "did the connect finish" from a request that may have timed out before
    /// answering. `URLSession` has no `HttpURLConnection`-style separate connect timeout,
    /// so this is how the same fact Android reads directly is recovered here: metrics are
    /// delivered whether the task succeeded, failed or timed out.
    private final class MetricsCollector: NSObject, URLSessionTaskDelegate {
        private(set) var connected = false
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            connected = metrics.transactionMetrics.contains { $0.connectEndDate != nil }
        }
    }

    private static func attempt(_ origin: URL, budget: TimeInterval) async -> Attempt {
        var request = URLRequest(url: origin.appendingPathComponent("api/health"))
        request.timeoutInterval = budget
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = budget
        config.waitsForConnectivity = false
        let collector = MetricsCollector()
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        // Per-attempt session with its own delegate: invalidate once the one task is
        // done, or it and the MetricsCollector it pins leak for the app's lifetime.
        // Safe after the awaited call below returns/throws — the metrics callback
        // fires before the task completes, and invalidate-after-finish is exactly
        // what finishTasksAndInvalidate is for.
        defer { session.finishTasksAndInvalidate() }
        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return Attempt(httpStatus: status, connected: true, elapsedMs: elapsedMs(since: started))
        } catch {
            return Attempt(httpStatus: nil, connected: collector.connected, elapsedMs: elapsedMs(since: started))
        }
    }

    private static func elapsedMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    /// Two-stage probe: stage one spends only `shortTimeout` finding out whether the Pi is
    /// there at all; a `presentSlow` verdict spends `readTimeout` finding out whether it is
    /// done thinking. Same information Android gets from one `HttpURLConnection` call with
    /// two timeout knobs — the extra HTTP attempt in the slow case is the price of
    /// `URLSession` not exposing that split natively.
    ///
    /// ponytail: no cross-candidate taper of the long budget (Android's
    /// `LONG_READ_WINDOW_MS` caps total `resolve()` time once several candidates each go
    /// slow) — add it if `resolve()` is ever seen running long with 3+ configured addresses.
    private static func probe(_ origin: URL) async -> (ProbeOutcome, reason: String) {
        let short = await attempt(origin, budget: shortTimeout)
        switch classify(connected: short.connected, httpStatus: short.httpStatus) {
        case .present:
            return (.present, "HTTP \(short.httpStatus!) after \(short.elapsedMs) ms")
        case .absent:
            let reason = short.httpStatus.map { "HTTP \($0) after \(short.elapsedMs) ms" }
                ?? "no connection after \(short.elapsedMs) ms"
            return (.absent, reason)
        case .presentSlow:
            let long = await attempt(origin, budget: readTimeout)
            let elapsed = short.elapsedMs + long.elapsedMs
            if classify(connected: true, httpStatus: long.httpStatus) == .present {
                return (.present, "HTTP \(long.httpStatus!) after \(elapsed) ms (connected at \(short.elapsedMs) ms, slow)")
            }
            let reason = long.httpStatus.map { "connected at \(short.elapsedMs) ms, then HTTP \($0) after \(elapsed) ms" }
                ?? "connected at \(short.elapsedMs) ms but no answer after \(elapsed) ms"
            return (.absent, reason)
        }
    }

    /// "192.0.2.31:8080" → "http://192.0.2.31:8080". Nil when unusable.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text } // bare host = a LAN box
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func append(_ out: inout [URL], _ raw: String?) {
        guard let raw, let url = normalize(raw), !out.contains(url) else { return }
        out.append(url)
    }
}
