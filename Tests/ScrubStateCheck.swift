import Foundation

// #115: the progress-bar scrub state, checked as a pure value type — no SwiftUI, no
// simulator. Same standalone-binary pattern as ServerAddressesCheck (see its header for
// why there is no XCTest target).
//
//   ./Tests/run-checks.sh

@main
enum ScrubStateCheck {
    static func main() {
        idle()
        knobStartsAtTheLivePosition()
        releaseReportsWhereTheDragEnded()
        rejectRestoresTheLivePosition()
        print("ScrubStateCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    /// Not scrubbing: the Slider shows the player, not a stale drag.
    static func idle() {
        var s = ScrubState()
        check(!s.isScrubbing, "a fresh state is not scrubbing")
        check(s.displayed(live: 42) == 42, "idle shows the live position")
        s.update(to: 300)
        _ = s.end()
        check(s.displayed(live: 42) == 42, "after a drag ends it shows the live position again")
    }

    /// The bug #115 reported: the knob binds to this value the instant the drag starts, so
    /// `begin` has to seed it with the live position. Before the fix the binding fell back
    /// to the previous drag's value — 0.0 on the first drag of a session — and the knob
    /// teleported to the start of the film under the user's finger.
    static func knobStartsAtTheLivePosition() {
        var s = ScrubState()
        s.begin(at: 1830)
        check(s.isScrubbing, "begin starts a scrub")
        check(s.displayed(live: 1831) == 1830,
              "the knob starts at the live position, not at 0 (#115: it jumped to the film's start)")

        // The regression that hid behind it: a SECOND drag must not start at the first
        // drag's destination either.
        s.update(to: 4200)
        check(s.end() == 4200, "release reports the dragged-to position")
        s.begin(at: 55)
        check(s.displayed(live: 56) == 55,
              "a later drag starts at the live position, not at the previous drag's value")
    }

    /// End of drag: the value handed to the player is where the finger let go, and the
    /// state goes back to following the player.
    static func releaseReportsWhereTheDragEnded() {
        var s = ScrubState()
        s.begin(at: 10)
        s.update(to: 120)
        s.update(to: 360)
        check(s.end() == 360, "release reports the last dragged value")
        check(!s.isScrubbing, "release stops scrubbing")
    }

    /// #117: PlaybackCoordinator reports a genuinely dropped seek (KSPlayerLayer
    /// player ready but not seekable, or the shouldSeekTo>0-never-replayed
    /// target-0 exception) — the failed target must not linger anywhere that
    /// could still surface it, so `reject` drops the display straight back to
    /// the live clock instead of the value the finger let go of.
    static func rejectRestoresTheLivePosition() {
        var s = ScrubState()
        s.begin(at: 10)
        s.update(to: 500)
        s.reject(to: 12)
        check(!s.isScrubbing, "a rejected seek stops scrubbing")
        check(s.value == 12, "a rejected seek clears the held value to the live position, not the dropped target (500)")
        check(s.displayed(live: 12) == 12,
              "a rejected seek shows the live position, not the dropped target")
    }
}
