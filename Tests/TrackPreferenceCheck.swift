import Foundation

// #473: the initial audio / subtitle language pick (Dobby/Playback/TrackPreference.swift).
@main
enum TrackPreferenceCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        check(TrackPreference.normalize("eng") == "en", "eng is en")
        check(TrackPreference.normalize("ger") == "de", "Matroska B code ger is de")
        check(TrackPreference.normalize("pt_BR") == "pt", "region dropped")
        check(TrackPreference.normalize("und") == nil && TrackPreference.normalize(nil) == nil, "und is no language")

        let p = TrackPreference.priority("bg, en", deviceLanguage: "de")
        check(p == ["bg", "en", "de"], "priority keeps order, adds the device language, en once")
        check(TrackPreference.priority(nil, deviceLanguage: nil) == ["en"], "no preference falls back to en")

        check(TrackPreference.pick(["eng", "bul"], priority: p) == 1, "earliest preferred language beats track order")
        check(TrackPreference.pick([nil, "fre", "ger"], priority: p) == 2, "device language after the preferred list")
        check(TrackPreference.pick(["jpn", nil], priority: p) == nil, "no match leaves the player's own pick")
        print("TrackPreferenceCheck: all checks passed")
    }
}
