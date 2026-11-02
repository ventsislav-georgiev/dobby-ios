import Foundation

// #474 E9: Pause on OK on fake defaults (never the app's own): the saved value is read, never
// written over; OK pauses only a started, playing video; the bare picture resumes once.
@main
enum MoreMenuModelCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    /// A fixed suite per use, emptied first, so reruns reuse one file each.
    static func fake(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "more-menu-check-\(name)")!
        d.removePersistentDomain(forName: "more-menu-check-\(name)")
        return d
    }

    static func main() {
        let empty = fake("empty")
        var m = MoreMenuState(defaults: empty)
        check(!m.pauseOnOk, "absent setting reads Off")
        check(empty.object(forKey: MoreMenuState.pauseOnOkKey) == nil, "reading writes no default")
        check(!m.okShouldPause(playing: true, started: true), "Off: OK never pauses")

        let saved = fake("saved")
        saved.set(true, forKey: MoreMenuState.pauseOnOkKey)
        m = MoreMenuState(defaults: saved)
        check(m.pauseOnOk, "saved On is read")
        check(saved.bool(forKey: MoreMenuState.pauseOnOkKey), "loading keeps the saved On")
        check(!m.okShouldPause(playing: true, started: false), "a video still preparing is not paused")
        check(!m.okShouldPause(playing: false, started: true), "an already paused video is not OK's pause")
        check(!m.bareShouldResume(paused: true), "a pause that was not OK's never resumes")
        check(m.okShouldPause(playing: true, started: true), "On: OK pauses a playing video")
        check(m.bareShouldResume(paused: true), "the bare picture resumes OK's pause")
        check(!m.bareShouldResume(paused: true), "and only once")
        _ = m.okShouldPause(playing: true, started: true)
        check(!m.bareShouldResume(paused: false), "a player the user resumed is left alone")
        _ = m.okShouldPause(playing: true, started: true)
        m.cancelPausedByOk()
        check(!m.bareShouldResume(paused: true), "a user play/pause cancels the resume")

        m.togglePauseOnOk()
        check(!m.pauseOnOk && saved.object(forKey: MoreMenuState.pauseOnOkKey) as? Bool == false,
              "the toggle saves Off")
        check(!MoreMenuState(defaults: saved).pauseOnOk, "a new player reads the toggled value")

        m.move(-1)
        check(m.focus == MoreMenuRow.allCases.count - 1, "up from the first row wraps to the last")
        m.move(1)
        check(m.focus == 0, "down from the last row wraps to the first")
        print("MoreMenuModelCheck: all checks passed")
    }
}
