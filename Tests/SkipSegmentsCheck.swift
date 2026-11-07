import Foundation

// #560: the intro / recap skip and the next-episode prompt (SkipSegments.swift), and the play
// payload's optional `skip` (PlayNativePayload.swift).
@main
enum SkipSegmentsCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    typealias Seg = SkipSegments.Segment

    static func segments(introMode: SkipSegments.Mode = .auto, recapMode: SkipSegments.Mode = .auto,
                         creditsMode: SkipSegments.Mode = .auto, confident: Bool = true,
                         length: Double? = nil, hasNext: Bool = true) -> SkipSegments {
        SkipSegments(intro: Seg(start: 83, end: 114, confident: confident),
                     recap: Seg(start: 0, end: 41.5, confident: confident),
                     credits: Seg(start: 1300, end: nil, confident: true), length: length,
                     introMode: introMode, recapMode: recapMode, creditsMode: creditsMode, hasNext: hasNext)
    }

    /// Ticks the positions in order on one state; returns the actions.
    static func run(_ s: inout SkipState, _ skip: SkipSegments?, _ positions: [Double],
                    duration: Double = 1430) -> [SkipState.Action?] {
        positions.map { s.tick(ref: "r1", position: $0, duration: duration, skip: skip) }
    }

    static func main() {
        // Mode auto, confident, length null: one seek to the end, the label for 3 s of playback.
        var s = SkipState()
        check(run(&s, segments(), [80]) == [nil], "before the intro nothing happens")
        check(s.button == nil && s.skipped == nil, "before the intro nothing shows")
        check(run(&s, segments(), [84]) == [.seek(114)], "auto + confident + length null seeks to the intro end")
        check(s.skipped == .intro && s.button == nil, "the auto-skip shows Skipped intro, no button")
        check(run(&s, segments(), [84.1]) == [nil], "a tick before the seek lands does not skip again")
        check(s.button == nil && s.skipped == .intro, "no Skip button flickers while the seek lands")
        _ = run(&s, segments(), [114, 116.9])
        check(s.skipped == .intro, "the label holds for 3 s after the skip")
        _ = run(&s, segments(), [117])
        check(s.skipped == nil, "the label goes after 3 s")

        // No re-skip after the user seeks back in: the button shows instead.
        check(run(&s, segments(), [90]) == [nil], "seeking back into a skipped intro does not skip again")
        check(s.button == .intro && s.buttonTarget(segments()) == 114, "it offers the Skip intro button instead")
        check(run(&s, segments(), [112.9]) == [nil] && s.button == .intro, "the button stays up to end - 1")
        _ = run(&s, segments(), [113])
        check(s.button == nil, "the button hides at end - 1")

        // A seek back into the segment drops a label still showing.
        s = SkipState()
        _ = run(&s, segments(), [85, 114, 115, 100])
        check(s.skipped == nil && s.button == .intro, "a seek back in drops the label and shows the button")

        // Recap: same rules, its own once-per-playback memory.
        s = SkipState()
        check(run(&s, segments(), [0.5]) == [.seek(41.5)] && s.skipped == .recap, "the recap auto-skips with Skipped recap")
        check(run(&s, segments(), [41.5, 84]) == [nil, .seek(114)], "the intro still auto-skips after the recap")

        // Mode button: never seeks, shows the button inside [start, end - 1).
        s = SkipState()
        check(run(&s, segments(introMode: .button), [84, 100]) == [nil, nil], "mode button never seeks")
        check(s.button == .intro && s.skipped == nil, "mode button shows Skip intro")
        s = SkipState()
        _ = run(&s, segments(recapMode: .button), [10])
        check(s.button == .recap, "mode button shows Skip recap")

        // Mode off: nothing at all.
        s = SkipState()
        check(run(&s, segments(introMode: .off, recapMode: .off), [10, 84, 100]) == [nil, nil, nil], "mode off never seeks")
        check(s.button == nil && s.skipped == nil, "mode off shows nothing")

        // Not confident: the button, never an auto-skip.
        s = SkipState()
        check(run(&s, segments(confident: false), [84]) == [nil] && s.button == .intro, "an unconfident intro gets the button")

        // The length tolerance: within 20 s of the duration auto-skips, beyond it the button.
        for (length, duration, auto) in [(1430.7, 1430.0, true), (1450.0, 1430.0, true), (1410.0, 1430.0, true),
                                         (1451.0, 1430.0, false), (1300.0, 1430.0, false), (1430.0, Double.nan, false)] {
            s = SkipState()
            let a = run(&s, segments(length: length), [84], duration: duration)
            check(a == (auto ? [.seek(114)] : [nil]), "length \(length) on duration \(duration) auto-skips: \(auto)")
            check(auto || s.button == .intro, "length \(length) on duration \(duration) falls back to the button")
        }
        check(segments().autoSkips(.intro, duration: .nan), "a null length auto-skips even before the duration is known")

        // Credits, hasNext false: nothing happens at the end.
        s = SkipState()
        check(run(&s, segments(hasNext: false), [1299, 1300, 1400]) == [nil, nil, nil], "hasNext false never fires next")
        check(!s.nextShown && s.countdown == nil, "hasNext false shows no Next episode button")
        s = SkipState()
        _ = run(&s, segments(creditsMode: .off), [1300, 1400])
        check(!s.nextShown, "credits mode off shows no Next episode button")
        var noCredits = segments(); noCredits.credits = nil
        s = SkipState()
        _ = run(&s, noCredits, [1300, 1420])
        check(!s.nextShown, "without credits data nothing happens at the end")

        // Credits, mode button: the button, no countdown.
        s = SkipState()
        check(run(&s, segments(creditsMode: .button), [1300, 1320]) == [nil, nil], "credits mode button never fires itself")
        check(s.nextShown && s.countdown == nil, "credits mode button shows Next episode without a countdown")

        // Credits, mode auto: a 10 s countdown that fires next.
        s = SkipState()
        check(run(&s, segments(), [1299.9]) == [nil] && !s.nextShown, "before credits.start no button")
        check(run(&s, segments(), [1300.2]) == [nil] && s.nextShown && s.countdown == 10, "credits.start shows Next episode, 10 s")
        check(run(&s, segments(), [1305.2]) == [nil] && s.countdown == 5, "the countdown follows the position")
        check(run(&s, segments(), [1310.2]) == [.next], "the countdown runs out and fires next")
        check(run(&s, segments(), [1310.3]) == [nil], "next fires once")

        // Cancel: the countdown stops, the button stays.
        s = SkipState()
        _ = run(&s, segments(), [1300, 1303])
        s.cancelCountdown()
        check(s.nextShown && s.countdown == nil, "a cancelled countdown leaves the button")
        check(run(&s, segments(), [1311, 1400]) == [nil, nil] && s.nextShown, "a cancelled countdown never fires")

        // The natural end inside a running countdown is next (credits within 10 s of the end).
        s = SkipState()
        _ = run(&s, segments(), [1300, 1304])
        check(s.nextOnNaturalEnd(ref: "r1", failed: false), "the end during the auto countdown carries next")
        check(!s.nextOnNaturalEnd(ref: "r1", failed: true), "a failed end during the countdown ends plainly")
        check(!s.nextOnNaturalEnd(ref: "r2", failed: false), "another playback's countdown never makes its end next")
        var cancelled = s; cancelled.cancelCountdown()
        check(!cancelled.nextOnNaturalEnd(ref: "r1", failed: false), "the end after a cancelled countdown ends plainly")
        var buttonMode = SkipState()
        _ = run(&buttonMode, segments(creditsMode: .button), [1300, 1304])
        check(!buttonMode.nextOnNaturalEnd(ref: "r1", failed: false), "credits mode button ends plainly")
        var offMode = SkipState()
        _ = run(&offMode, segments(creditsMode: .off), [1300, 1304])
        check(!offMode.nextOnNaturalEnd(ref: "r1", failed: false), "credits mode off ends plainly")
        var noNext = SkipState()
        _ = run(&noNext, segments(hasNext: false), [1300, 1304])
        check(!noNext.nextOnNaturalEnd(ref: "r1", failed: false), "hasNext false ends plainly")
        var before = SkipState()
        _ = run(&before, segments(), [1200])
        check(!before.nextOnNaturalEnd(ref: "r1", failed: false), "an end before credits.start ends plainly")
        check(!SkipState().nextOnNaturalEnd(ref: nil, failed: false), "an absent skip ends plainly")

        // Seeking back before the credits hides the button; reaching them again restarts it.
        _ = run(&s, segments(), [1200])
        check(!s.nextShown && s.countdown == nil, "seeking back before the credits hides Next episode")
        _ = run(&s, segments(), [1300])
        check(s.nextShown && s.countdown == 10, "reaching the credits again starts a fresh countdown")

        // A new playback starts over (a skipped intro skips again in the next episode).
        s = SkipState()
        _ = run(&s, segments(), [84])
        check(s.tick(ref: "r2", position: 84, duration: 1430, skip: segments()) == .seek(114), "a new ref forgets the skips")

        // Absent skip: nothing ever shows or fires.
        s = SkipState()
        check(run(&s, nil, [0, 10, 84, 1300, 1400]).allSatisfy { $0 == nil }, "an absent skip never acts")
        check(s == SkipState(ref: "r1"), "an absent skip leaves the state empty")

        // Parse: the contract's payload.
        let full = #"""
        {"ref":"a","skip":{
          "intro":{"start":83,"end":114.0,"confident":true},
          "recap":{"start":0.0,"end":41.5,"confident":false},
          "credits":{"start":2847.6,"confident":true},"length":1430.7,
          "mode":{"intro":"auto","recap":"button","credits":"off"},"hasNext":true}}
        """#
        let p = PlayNativePayload.decode(full)
        check(p?.skip == SkipSegments(intro: Seg(start: 83, end: 114, confident: true),
                                      recap: Seg(start: 0, end: 41.5, confident: false),
                                      credits: Seg(start: 2847.6, end: nil, confident: true), length: 1430.7,
                                      introMode: .auto, recapMode: .button, creditsMode: .off, hasNext: true),
              "the contract's skip object decodes field for field")

        let absent = PlayNativePayload.decode(#"{"ref":"a"}"#)
        check(absent != nil && absent?.skip == nil, "a payload without skip decodes with skip nil")
        check(PlayNativePayload.decode(#"{"ref":"a","skip":null}"#)?.skip == nil, "skip null reads as absent")

        let nulls = PlayNativePayload.decode(#"{"ref":"a","skip":{"intro":null,"recap":null,"credits":null,"length":null}}"#)
        check(nulls?.skip == SkipSegments(), "all-null segments, no mode: nothing, modes auto, hasNext false")

        // A malformed skip never costs the payload.
        for odd in [#""skip":"x""#, #""skip":[1,2]"#, #""skip":{"intro":{"start":"83","end":114},"mode":"auto","hasNext":"yes"}"#,
                    #""skip":{"intro":{"start":90,"end":80,"confident":true},"mode":{"intro":"sometimes"}}"#] {
            let q = PlayNativePayload.decode(#"{"ref":"a","#  + odd + "}")
            check(q?.ref == "a", "a malformed skip (\(odd)) still decodes the payload")
            check(q?.skip?.intro == nil && q?.skip?.hasNext != true, "a malformed skip (\(odd)) offers nothing")
            check(q?.skip.map { $0.introMode == .auto } ?? true, "an unknown mode (\(odd)) reads as auto")
        }

        print("PASS: SkipSegments auto/button/off per segment, confident, the 20 s length tolerance incl. null, "
              + "once-per-playback auto-skip with the button on seek-back, the 3 s label, credits with hasNext "
              + "false/off/button/auto, the 10 s countdown and its cancel, next on a natural end inside the countdown, an absent skip; PlayNativePayload "
              + "decodes skip, absent, null and malformed (#560)")
    }
}
