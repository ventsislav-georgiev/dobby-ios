import Foundation

// #586: the play payload's subtitleMode and the subtitle auto-pick it gates
// (Dobby/Playback/TrackPreference.swift pickSubtitle, called from PlaybackCoordinator.applyPreferredTracks).
@main
enum SubtitleModeCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what) (#586)\n".utf8))
            exit(1)
        }
    }

    static func mode(_ json: String) -> SubtitleMode? {
        PlayNativePayload.decode(json).map { SubtitleMode($0.subtitleMode) }
    }

    static func main() {
        // Decode: missing or unknown reads on, and an unknown value never drops the payload.
        check(mode(#"{"ref":"r","preferredSubtitleLang":"bg"}"#) == .on, "decode: a payload without subtitleMode reads on")
        check(mode(#"{"ref":"r","subtitleMode":"sometimes"}"#) == .on, "decode: an unknown subtitleMode reads on")
        check(mode(#"{"ref":"r","subtitleMode":null}"#) == .on, "decode: a null subtitleMode reads on")
        check(mode(#"{"ref":"r","subtitleMode":"off"}"#) == .off, "decode: off reads off")
        check(mode(#"{"ref":"r","subtitleMode":"forced"}"#) == .forced, "decode: forced reads forced")
        check(mode(#"{"ref":"r","subtitleMode":"on"}"#) == .on, "decode: on reads on")
        check(SubtitleMode(nil) == .on, "decode: no value at all reads on")

        let p = TrackPreference.priority("bg,en", deviceLanguage: "de")
        let langs: [String?] = ["eng", "bul", "ger"]
        let noneForced = [false, false, false]

        // on: exactly pick(), whatever the forced marks say.
        for forced in [noneForced, [true, false, false], [false, false, true]] {
            check(TrackPreference.pickSubtitle(langs, forced: forced, priority: p, mode: .on)
                  == TrackPreference.pick(langs, priority: p), "on: the pick is unchanged")
        }
        check(TrackPreference.pickSubtitle(langs, forced: noneForced, priority: p, mode: .on) == 1, "on: earliest preferred language")
        check(TrackPreference.pickSubtitle(["jpn"], forced: [false], priority: p, mode: .on) == nil, "on: no match still picks nothing")

        // off: nothing, even with a forced track in the first preferred language.
        check(TrackPreference.pickSubtitle(langs, forced: noneForced, priority: p, mode: .off) == nil, "off: picks nothing")
        check(TrackPreference.pickSubtitle(langs, forced: [true, true, true], priority: p, mode: .off) == nil,
              "off: picks nothing even when every track is forced")

        // forced: only a forced track, in priority order; nothing when none is forced or none is preferred.
        check(TrackPreference.pickSubtitle(langs, forced: noneForced, priority: p, mode: .forced) == nil,
              "forced: nothing when no track is forced")
        check(TrackPreference.pickSubtitle(langs, forced: [true, false, false], priority: p, mode: .forced) == 0,
              "forced: the forced track beats an unforced earlier-priority one")
        check(TrackPreference.pickSubtitle(langs, forced: [true, true, false], priority: p, mode: .forced) == 1,
              "forced: earliest preferred language among the forced tracks")
        check(TrackPreference.pickSubtitle(["jpn", "eng"], forced: [true, false], priority: p, mode: .forced) == nil,
              "forced: a forced track outside the preferred languages is not picked")
        check(TrackPreference.pickSubtitle(langs, forced: [], priority: p, mode: .forced) == nil,
              "forced: a short forced list marks nothing")

        // The forced marking a title or label carries.
        for name in ["English (Forced)", "eng.forced.srt", "FORCED", "eng_forced", "Forced - Signs"] {
            check(TrackPreference.isForcedLabel(name), "label: \(name) is forced")
        }
        for name in ["English", "English SDH", "Unforced cut", "forcedly", nil] as [String?] {
            check(!TrackPreference.isForcedLabel(name), "label: \(name ?? "nil") is not forced")
        }
        print("SubtitleModeCheck: all checks passed")
    }
}
