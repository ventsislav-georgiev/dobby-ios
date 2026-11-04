#if os(iOS)
import KSPlayer
import QuartzCore
import UIKit

/// #537 device-round render probe and experiment switches. SELFTEST ONLY: every entry point
/// returns at once unless DOBBY_SELFTEST_URL is set, so a normal launch starts no timer, reads no
/// display link and logs nothing. Once a second it hands one "tick" line to the coordinator's
/// mark(), which also appends it to the selftest log file.
/// Switches, one variable each, read only when the selftest is on:
///   DOBBY_EXP_PREFERREDFRAME=0  KSOptions.preferredFrame = false: KSPlayer leaves the display
///                               link at the system default rate instead of fps..2*fps
///   DOBBY_EXP_RANGE=min,max,pref override the link's preferredFrameRateRange after the first tick
///   DOBBY_EXP_HIDEWEB=1         hide the web view while the player is up
///   DOBBY_EXP_PING=0            no main-queue latency ping (proves the ping itself costs nothing)
final class RenderProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let enabled = env["DOBBY_SELFTEST_URL"] != nil
    private static var shared: RenderProbe?

    /// Before KSPlayer opens: the display link range is set on the first frame drawn.
    static func beforeOpen() {
        guard enabled else { return }
        if env["DOBBY_EXP_PREFERREDFRAME"] == "0" { KSOptions.preferredFrame = false }
    }

    static func start(player: @escaping () -> MediaPlayerProtocol?, web: UIView?, log: @escaping (String) -> Void) {
        guard enabled, shared == nil else { return }
        let probe = RenderProbe()
        shared = probe
        if env["DOBBY_EXP_HIDEWEB"] == "1" { web?.isHidden = true }
        log("probe preferredFrame=\(KSOptions.preferredFrame) range=\(env["DOBBY_EXP_RANGE"] ?? "-") hideWeb=\(env["DOBBY_EXP_HIDEWEB"] ?? "-") ping=\(env["DOBBY_EXP_PING"] ?? "-")")
        probe.run(player, log)
    }

    static func stop(web: UIView?) {
        guard enabled, let probe = shared else { return }
        probe.timer?.invalidate(); probe.ping?.cancel(); shared = nil
        if env["DOBBY_EXP_HIDEWEB"] == "1" { web?.isHidden = false }
    }

    private var timer: Timer?
    private var ping: DispatchSourceTimer?
    private var lagMax = 0.0      // main queue only
    private var lagOver = 0
    private var lastLinkTs = 0.0
    private var linkCalls = 0
    private var lastDropped: UInt32 = 0
    private var overridden = false
    private var n = 0

    private func run(_ player: @escaping () -> MediaPlayerProtocol?, _ log: @escaping (String) -> Void) {
        // 250 Hz main-queue ping: its latency is how long main was busy, and each run that sees a new
        // CADisplayLink.timestamp counts one display-link callback (the link fires at most 120 Hz).
        if Self.env["DOBBY_EXP_PING"] != "0" {
            let src = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "render-probe-ping", qos: .userInteractive))
            src.schedule(deadline: .now(), repeating: .milliseconds(4))
            src.setEventHandler { [weak self] in
                let sent = CACurrentMediaTime()
                DispatchQueue.main.async {
                    guard let self else { return }
                    let lag = CACurrentMediaTime() - sent
                    self.lagMax = max(self.lagMax, lag)
                    if lag > 0.042 { self.lagOver += 1 }
                    if let ts = Self.link(player())?.timestamp, ts != self.lastLinkTs { self.lastLinkTs = ts; self.linkCalls += 1 }
                }
            }
            src.resume()
            ping = src
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick(player(), log) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// KSPlayer keeps its display link private; Mirror reads the stored property, no fork needed.
    private static func link(_ p: MediaPlayerProtocol?) -> CADisplayLink? {
        guard let v = (p as? KSMEPlayer)?.videoOutput else { return nil }
        return Mirror(reflecting: v).children.first { $0.label == "displayLink" }?.value as? CADisplayLink
    }

    private func tick(_ p: MediaPlayerProtocol?, _ log: (String) -> Void) {
        n += 1
        let l = Self.link(p)
        if !overridden, let l, let r = Self.env["DOBBY_EXP_RANGE"] {
            let v = r.split(separator: ",").compactMap { Float($0) }
            if v.count == 3 {
                l.preferredFrameRateRange = CAFrameRateRange(minimum: v[0], maximum: v[1], __preferred: v[2])
                overridden = true
            }
        }
        let d = p?.dynamicInfo
        let dropped = d?.droppedVideoFrameCount ?? 0
        let r = l?.preferredFrameRateRange
        let period = l.map { ($0.targetTimestamp - $0.timestamp) * 1000 } ?? 0
        log(String(format: "tick n=%d pos=%.1f dfps=%.1f calls=%d drop=%d av=%.0f period=%.1f range=%.0f-%.0f/%.0f paused=%@ mainMax=%.0f over42=%d maxfps=%d lp=%@ th=%d",
                   n, p?.currentPlaybackTime ?? 0, d?.displayFPS ?? 0, linkCalls, Int(dropped) - Int(lastDropped),
                   (d?.audioVideoSyncDiff ?? 0) * 1000, period, r?.minimum ?? 0, r?.maximum ?? 0, r?.preferred ?? 0,
                   (l?.isPaused ?? true) ? "y" : "n", lagMax * 1000, lagOver, UIScreen.main.maximumFramesPerSecond,
                   ProcessInfo.processInfo.isLowPowerModeEnabled ? "y" : "n", ProcessInfo.processInfo.thermalState.rawValue))
        lastDropped = dropped; linkCalls = 0; lagMax = 0; lagOver = 0
    }
}
#endif
