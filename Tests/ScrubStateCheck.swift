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
        releaseCommitsOnlyOnce()
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

    /// #131: a drag now has TWO possible release paths — the Slider's
    /// `onEditingChanged(false)`, and the gesture-state reset that recovers the one
    /// SwiftUI dropped on device. `isScrubbing` is the whole interlock: the first `end()`
    /// clears it, so the second path reads false and skips the seek. Both call sites are
    /// MainActor-isolated, so this is an atomic check-and-clear, not a race.
    static func releaseCommitsOnlyOnce() {
        var s = ScrubState()
        s.begin(at: 10)
        s.update(to: 900)
        check(s.isScrubbing, "a live drag reports isScrubbing, which is what both release paths gate on")
        check(s.end() == 900, "the first release path reports the dragged-to position")
        check(!s.isScrubbing,
              "the second release path must see isScrubbing false and not seek again (#131)")

        // And a touch that never became a drag must not resurrect the previous drag's
        // value: iOS's Slider ignores taps on the track, so no begin() ever runs. Fresh
        // object on purpose — re-asserting on `s` two lines after the check above passes
        // for free and says nothing about this case (#131 review).
        var t = ScrubState()
        check(!t.isScrubbing, "a touch with no begin() is not a live scrub")
        t.update(to: 42)
        check(!t.isScrubbing, "a value arriving without begin() still is not a live scrub")
    }
}
