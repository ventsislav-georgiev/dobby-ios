import Foundation

/// Scrub state for the native player's progress Slider.
///
/// A Slider draws its knob at the bound value, so whatever the binding reports the moment
/// a drag starts is where the knob lands. #115: the binding fell back to the *previous*
/// drag's value (0.0 on the first drag of a session), so touching the bar teleported the
/// knob to the start of the film. macOS hides that — AppKit's slider tracks absolutely, so
/// the release value is still wherever the pointer is — but iOS tracks the knob relatively,
/// so every position after the jump is off by the distance the knob teleported and the
/// video "does not seek to that position".
///
/// Seeding from the live playback position on `begin(at:)` is the whole fix.
struct ScrubState {
    private(set) var isScrubbing = false
    private(set) var value = 0.0

    /// What the Slider should show: the in-flight scrub, else the live position.
    func displayed(live: Double) -> Double { isScrubbing ? value : live }

    /// `onEditingChanged(true)` — seed from the live position before the knob binds to it.
    mutating func begin(at live: Double) {
        value = live
        isScrubbing = true
    }

    /// The Slider's setter while a drag is in flight.
    mutating func update(to newValue: Double) { value = newValue }

    /// `onEditingChanged(false)` — hands back the position to seek to.
    mutating func end() -> Double {
        isScrubbing = false
        return value
    }
}

extension ScrubState {
    /// Every seek target the OSD makes lands here (Android): never before the start, and with a
    /// known duration never closer than 200 ms to the end, so a seek can not end the film.
    static func clamp(_ target: Double, duration: Double) -> Double {
        duration > 0 ? max(0, min(duration - 0.2, target)) : max(0, target)
    }

    /// Where a press or drag at `x` along a band `width` wide lands (Android touchSeekTargetMs).
    /// Nil while the width or the duration is unknown.
    static func target(x: Double, width: Double, duration: Double) -> Double? {
        guard width > 0, duration > 0 else { return nil }
        return clamp(x / width * duration, duration: duration)
    }
}

/// Android triggerSeekBurst / triggerJumpBurst: a press in the same direction inside 900 ms of the
/// last one steps further (15 s, 30 s, 45 s...; 20 %, 40 %...). Each press steps from the previous
/// press's target while the window is open, since the player may not report a seek it has not
/// finished yet.
struct SeekBurst {
    static let window = 0.9

    private var direction = 0
    private var count = 0
    private var expires = -Double.infinity
    private var lastTarget = 0.0

    /// One press at `now` (seconds, any monotonic clock): `unit` is the first step (15 s, or 20 %
    /// of the duration). Returns the clamped target and the step count (1, 2, 3...).
    mutating func press(_ dir: Int, unit: Double, now: Double, live: Double, duration: Double) -> (target: Double, count: Int) {
        let open = now <= expires
        count = open && dir == direction ? count + 1 : 1
        let from = open ? lastTarget : live
        direction = dir
        expires = now + Self.window
        lastTarget = ScrubState.clamp(from + unit * Double(count * dir), duration: duration)
        return (lastTarget, count)
    }
}
