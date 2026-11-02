import Foundation

// #469 E4: the audio row label matches Android describeAudioFormat.
@main
enum AudioTrackLabelCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let gb = "\u{1F1EC}\u{1F1E7}"
        check(AudioTrackLabel.label(name: "eng", language: "eng", codec: "eac3", codecName: "eac3", channels: 6, index: 0)
              == "\(gb) EN · DD+ 5.1", "an untitled track reads flag, uppercased 639-1 language, codec and layout")
        check(AudioTrackLabel.label(name: "\(gb) - Director commentary", language: "en", codec: "ac-3", codecName: nil, channels: 2, index: 1)
              == "\(gb) Director commentary · AC3 2.0", "a titled track keeps its title without a doubled flag")
        check(AudioTrackLabel.label(name: "truehd", language: nil, codec: "truehd", codecName: "truehd", channels: 8, index: 2)
              == "Track 3 · TrueHD 7.1", "no title and no language is Track N")
        check(AudioTrackLabel.label(name: "x", language: "und", codec: "pcm_s16le", codecName: "pcm_s16le", channels: 3, index: 0)
              == "x · PCM 3ch", "und is no language, pcm_* is PCM, odd counts read Nch")
        print("AudioTrackLabelCheck: all checks passed")
    }
}
