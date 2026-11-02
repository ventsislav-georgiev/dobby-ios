import Foundation

// #471 (E6): the subtitle delay model. ±100 ms steps, the fps-corrected delay(t) against
// Android subTimeUsAt, and the page-set delay (setSubtitleOffsetMs) the next step builds on.
@main
enum SubsDelayModelCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    static func main() {
        var m = SubsDelayModel()
        m.step(1); m.step(1); m.step(1)
        check(m.delay == 0.3 && m.label == "+300 ms", "three right steps read +300 ms")
        m.step(-1); m.step(-1); m.step(-1); m.step(-1)
        check(m.delay == -0.1 && m.label == "−100 ms", "steps cross zero to −100 ms")
        check(m.offset(at: 5000) == -0.1, "fps Off: the delay is constant")

        // fps 25 -> 23.976: the cue the player shows at t is subtitle time (t - delay) / ratio
        // (Android subTimeUsAt); KSPlayer shows subtitle time t - D(t).
        m.fpsIndex = 1; m.delay = 0.5
        for t in [0.0, 600, 3600, 7000] {
            check(near(t - m.offset(at: t), (t - 0.5) / (25 / SubsDelayModel.fps23976)),
                  "delay(t) at \(t) s matches Android's subtitle time")
        }
        check(m.offset(at: 3600) > 100, "a PAL file on a 23.976 video drifts by minutes an hour in")
        m.cycleFps(-1); m.cycleFps(-1)
        check(m.fpsIndex == 6, "up from row 0 wraps to the last fps choice")
        m.reset()
        check(m.delay == 0 && m.fpsIndex == 0, "reset clears delay and fps")

        // #466 N4: the page set 1.25 s on the player; the next step builds on it.
        m.applied = 0
        check(!m.adopt(playerDelay: 0), "our own value is not adopted")
        check(m.adopt(playerDelay: 1.25), "a value someone else wrote is adopted")
        m.step(1)
        check(m.delay == 1.35, "stepping after setSubtitleOffsetMs keeps the page's delay")

        check(m.fpsLabel(videoFps: 0) == "Subtitle frame rate: Off", "Off label")
        m.fpsIndex = 1
        check(m.fpsLabel(videoFps: 23.976) == "Subtitles made for 25 fps, video 23.976 fps  (this video: 23.976 fps)",
              "fps label as on Android")
        print("SubsDelayModelCheck: all checks passed")
    }
}
