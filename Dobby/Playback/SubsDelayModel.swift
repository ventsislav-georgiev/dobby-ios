import Foundation

// E6 (#471) owns this file with SubsDelayPill.swift: the pure subtitle delay model (Android
// adjust :8312-8336, fps correction :8287-8310). No SwiftUI or KSPlayer import, so
// Tests/run-checks.sh compiles it standalone with Tests/SubsDelayModelCheck.swift.

struct SubsDelayModel: Equatable {
    /// Seconds; positive shows subtitles later. Steps of 0.1 s (Android SUBS_DELAY_STEP_MS).
    var delay: Double = 0
    /// Row of `fpsChoices`; 0 = Off.
    var fpsIndex = 0
    /// The value last written to KSPlayer's subtitleDelay. A player value that differs was
    /// set by someone else (the page's setSubtitleOffsetMs, a new title's reset to 0) and is
    /// adopted as the delay before the next step, so a step never overwrites it (#466 N4).
    var applied: Double?
    /// The playback ref this state belongs to; a new ref starts from Off.
    var ref: String?
    /// The pill shows without owning the keys ("," "." "/" flash it for 2 s).
    var flashing = false
    var flashToken = 0

    static let step = 0.1
    static let fps23976 = 24000.0 / 1001.0
    /// Android SUB_FPS_CHOICES: (subtitle fps, video fps); row 0 is Off.
    static let fpsChoices: [(sub: Double, video: Double)] = [
        (1, 1), (25, fps23976), (fps23976, 25), (25, 24), (24, 25), (24, fps23976), (fps23976, 24),
    ]

    var ratio: Double { let c = Self.fpsChoices[fpsIndex]; return c.sub / c.video }

    /// The subtitle delay KSPlayer needs at video time `t`. KSPlayer shows the cue at
    /// subtitle time t - D; Android shows subtitle time (t - delay) / ratio (subTimeUsAt), so
    /// D(t) = t - (t - delay) / ratio. Off: D = delay.
    func offset(at t: Double) -> Double { fpsIndex == 0 ? delay : t - (t - delay) / ratio }

    mutating func step(_ direction: Int) {
        delay = ((delay + Double(direction) * Self.step) * 1000).rounded() / 1000
    }

    mutating func cycleFps(_ direction: Int) {
        let n = Self.fpsChoices.count
        fpsIndex = ((fpsIndex + direction) % n + n) % n
    }

    mutating func reset() { delay = 0; fpsIndex = 0 }

    /// Adopt a delay someone else wrote to the player (see `applied`). True when it did.
    mutating func adopt(playerDelay: Double) -> Bool {
        guard let applied, playerDelay != applied else { return false }
        delay = (playerDelay * 1000).rounded() / 1000
        self.applied = playerDelay
        return true
    }

    /// "+300 ms" / "−300 ms" (Android updateSubsDelayOsd).
    var label: String {
        let ms = Int((delay * 1000).rounded())
        return (ms >= 0 ? "+" : "−") + "\(abs(ms)) ms"
    }

    /// Android subsFpsLabel; `videoFps` 0 = unknown.
    func fpsLabel(videoFps: Double) -> String {
        let c = Self.fpsChoices[fpsIndex]
        var s = fpsIndex == 0 ? "Subtitle frame rate: Off"
            : "Subtitles made for \(Self.fpsText(c.sub)) fps, video \(Self.fpsText(c.video)) fps"
        if videoFps > 0 { s += "  (this video: \(Self.fpsText(videoFps)) fps)" }
        return s
    }

    static func fpsText(_ fps: Double) -> String {
        var s = String(format: "%.3f", fps)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
