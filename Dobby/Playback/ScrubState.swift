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

    /// #117: a seek PlaybackCoordinator reports as genuinely dropped (never
    /// applied, never will be — see PlaybackCoordinator.seek(to:completion:))
    /// must not leave anything behind that could still show the failed
    /// target: drop back to the live clock explicitly rather than trust that
    /// `isScrubbing` already got there first.
    mutating func reject(to live: Double) {
        value = live
        isScrubbing = false
    }
}
