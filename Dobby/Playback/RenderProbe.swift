#if os(iOS)
import AVFoundation
import KSPlayer
import QuartzCore
import UIKit

/// #537 device-round render probe and experiment switches. SELFTEST ONLY: every entry point
/// returns at once unless DOBBY_SELFTEST_URL or DOBBY_PROBE=1 is in the launch environment (a
/// devicectl launch of a dev build), so a normal launch starts no timer, reads no display link
/// and logs nothing. Once a second it hands one "tick" line to the coordinator's
/// mark(), which also appends it to the selftest log file.
/// Switches, one variable each, read only when the selftest is on:
///   DOBBY_EXP_PREFERREDFRAME=0|1 KSOptions.preferredFrame for this run: 1 restores KSPlayer's
///                               fps..2*fps display-link range that play() turns off (#537)
///   DOBBY_EXP_RANGE=min,max,pref override the link's preferredFrameRateRange after the first tick
///   DOBBY_EXP_HIDEWEB=1         hide the web view while the player is up
///   DOBBY_EXP_PING=0            no main-queue latency ping (proves the ping itself costs nothing)
///   DOBBY_EXP_SERVE=kbps,jitterMs,rttMs serve the app tmp dir over HTTP on loopback port 8537, paced to
///                               kbps, a stall of up to jitterMs once a second (then catch-up), rttMs
///                               before each response: FFmpeg's network read path without a network
///   DOBBY_EXP_PAUSE=at,dur      pause the player at tick at for dur seconds, then play (the owner pauses)
///   DOBBY_EXP_SEEK=at,delta     seek by delta seconds at tick at (the owner skips)
/// Tick fields beyond the first round: vpos (picture PTS) next to pos (audio clock), vq/aq the
/// decoded-frame queues, vp/ap the packet queues, stall (audio stalled, video is master), kbps read,
/// pi the present intervals of the second in ms:count (display-link timestamps of each new frame).
final class RenderProbe {
    private static let env = ProcessInfo.processInfo.environment
    // DOBBY_PROBE=1 (with DOBBY_SELFTEST_LOG for the file) runs the probe on an owner-started play, no autoplay.
    static let enabled = env["DOBBY_SELFTEST_URL"] != nil || env["DOBBY_PROBE"] == "1"
    private static var shared: RenderProbe?

    /// Before KSPlayer opens: the display link range is set on the first frame drawn.
    static func beforeOpen() {
        guard enabled else { return }
        if let v = env["DOBBY_EXP_PREFERREDFRAME"] { KSOptions.preferredFrame = v == "1" }
        if let s = env["DOBBY_EXP_SERVE"], !serving { serving = true; LoopServer.start(s) }
    }
    private static var serving = false

    static func start(player: @escaping () -> MediaPlayerProtocol?, owner: PlaybackCoordinator, web: UIView?, log: @escaping (String) -> Void) {
        guard enabled, shared == nil else { return }
        let probe = RenderProbe()
        shared = probe
        probe.owner = owner
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
    private weak var owner: PlaybackCoordinator?
    private var ping: DispatchSourceTimer?
    private var lagMax = 0.0      // main queue only
    private var lagOver = 0
    private var lastLinkTs = 0.0
    private var linkCalls = 0
    private var lastDropped: UInt32 = 0
    private var overridden = false
    private var n = 0
    private var lastShown = -1.0
    private var lastShownTs = 0.0
    private var pres: [Int: Int] = [:]   // present interval, in 120 Hz ticks -> count
    private var lastBytes: Int64 = 0

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
                    let p = player()
                    guard let l = Self.link(p) else { return }
                    if l.timestamp != self.lastLinkTs { self.lastLinkTs = l.timestamp; self.linkCalls += 1 }
                    if let v = (p as? KSMEPlayer)?.displayedVideoTime, v != self.lastShown {
                        if self.lastShownTs > 0 { self.pres[Int(((l.timestamp - self.lastShownTs) * 120).rounded()), default: 0] += 1 }
                        self.lastShown = v; self.lastShownTs = l.timestamp
                    }
                }
            }
            src.resume()
            ping = src
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick(player(), log) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func link(_ p: MediaPlayerProtocol?) -> CADisplayLink? { PlaybackCoordinator.playerDisplayLink(p) }

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
        let act = { (k: String) in Self.env[k].map { $0.split(separator: ",").compactMap { Double($0) } } ?? [] }
        // Through the coordinator, the owner's own pause and seek path (layer.seek with autoPlay).
        if let c = owner, case let a = act("DOBBY_EXP_PAUSE"), a.count == 2, n == Int(a[0]) || n == Int(a[0] + a[1]) {
            Task { @MainActor in c.togglePlayPause() }; log("exp toggle")
        }
        if let c = owner, let p, case let a = act("DOBBY_EXP_SEEK"), a.count == 2, n == Int(a[0]) {
            let to = p.currentPlaybackTime + a[1]
            log("exp seek \(a[1])"); Task { @MainActor in c.seek(to: to) }
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
        let me = p as? KSMEPlayer
        let item = me.flatMap { Mirror(reflecting: $0).children.first { $0.label == "playerItem" }?.value }
        let fields = item.map { Dictionary(Mirror(reflecting: $0).children.compactMap { c in c.label.map { ($0, c.value) } }) { a, _ in a } } ?? [:]
        let caps = fields["videoAudioTracks"] as? [CapacityProtocol] ?? []
        let q = { (t: AVMediaType) in caps.first { $0.mediaType == t }.map { "\($0.frameCount)/\($0.frameMaxCount) \($0.packetCount)" } ?? "-" }
        let bytes = d?.bytesRead ?? 0
        let pi = pres.sorted { $0.key < $1.key }.map { String(format: "%.0f:%d", Double($0.key) * 1000 / 120, $0.value) }.joined(separator: ",")
        log(String(format: "q n=%d vpos=%.2f pos=%.2f vq=%@ aq=%@ stall=%@ kbps=%lld pi=%@", n, me?.displayedVideoTime ?? 0,
                   p?.currentPlaybackTime ?? 0, q(.video), q(.audio), (fields["isAudioStalled"] as? Bool ?? false) ? "y" : "n",
                   (bytes - lastBytes) * 8 / 1000, pi))
        lastBytes = bytes; pres = [:]
    }
}
/// DOBBY_EXP_SERVE only (selftest): a loopback HTTP file server for the app tmp dir, one request per
/// connection, Range aware, paced. The phone has no LAN path to a Mac, and a remote host is the owner's
/// case: this puts FFmpeg's AVIO over HTTP under a remote host's rate, stalls and latency on the phone.
private enum LoopServer {
    static func start(_ spec: String) {
        let v = spec.split(separator: ",").compactMap { Double($0) }
        guard v.count == 3 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(8537).bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { NSLog("Dobby loopserver bind failed"); return }
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { continue }
                Thread.detachNewThread { handle(c, kbps: v[0], jitterMs: v[1], rttMs: v[2]) }
            }
        }
    }

    private static func handle(_ c: Int32, kbps: Double, jitterMs: Double, rttMs: Double) {
        defer { close(c) }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var req = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while req.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(c, &buf, buf.count, 0)
            guard n > 0 else { return }
            req.append(buf, count: n)
        }
        let head = String(decoding: req, as: UTF8.self)
        let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let file = NSTemporaryDirectory() + ((path.removingPercentEncoding ?? path) as NSString).lastPathComponent
        guard let fh = FileHandle(forReadingAtPath: file),
              let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value else {
            _ = sendAll(c, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
        }
        var a: Int64 = 0, b = size - 1, status = "200 OK"
        if let r = head.range(of: #"Range: bytes=(\d*)-(\d*)"#, options: [.regularExpression, .caseInsensitive]) {
            let nums = head[r].dropFirst("Range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if let x = Int64(nums[0]) { a = x; if nums.count > 1, let y = Int64(nums[1]) { b = min(y, size - 1) } }
            status = "206 Partial Content"
        }
        guard a <= b else { _ = sendAll(c, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return }
        usleep(useconds_t(rttMs * 1000))
        let hdr = "HTTP/1.1 \(status)\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\n"
            + (status.hasPrefix("206") ? "Content-Range: bytes \(a)-\(b)/\(size)\r\n" : "")
            + "Content-Length: \(b - a + 1)\r\nConnection: close\r\n\r\n"
        guard sendAll(c, Data(hdr.utf8)) else { return }
        try? fh.seek(toOffset: UInt64(a))
        let t0 = CACurrentMediaTime()
        var sent: Int64 = 0, nextStall = t0 + 1
        while a + sent <= b {
            let chunk = fh.readData(ofLength: Int(min(16384, b - a - sent + 1)))
            guard !chunk.isEmpty, sendAll(c, chunk) else { return }
            sent += Int64(chunk.count)
            let now = CACurrentMediaTime()
            // A stall, then the paced schedule catches up in a burst, as TCP from a far host does.
            if now >= nextStall { nextStall = now + 1; usleep(useconds_t(Double.random(in: 0...jitterMs) * 1000)) }
            let due = t0 + Double(sent) * 8 / (kbps * 1000)
            let wait = due - CACurrentMediaTime()
            if wait > 0 { usleep(useconds_t(wait * 1e6)) }
        }
    }

    private static func sendAll(_ c: Int32, _ d: Data) -> Bool {
        d.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = send(c, p.baseAddress! + off, p.count - off, 0)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}
#endif
