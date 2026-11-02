import Foundation
import KSPlayer

// E2 (#467) owns this file with ControlBar.swift: play/pause, keyboard seek, bookmark.
// #466 moved these here unchanged; the stubs below keep the pre-#466 keys until E2 lands
// (left/right 10 s, up/down only wake the bar).

/// E2's transport state (seek burst window, escalation step, seek-pill timer, ...).
struct TransportState {}

extension PlayerControls {
    func togglePlay() {
        more.cancelPausedByOk()   // #474: the user chose the play state (Android togglePlay :7200)
        let pausing = isPlaying
        playback?.togglePlayPause()
        // Pausing shows the bar (pre-#466). A resume leaves it to syncState, which KSPlayer
        // calls synchronously from play(): it hides a bar that was up (Android
        // updatePlayPauseUi) or re-arms the 5 s hide; a forceShow here would undo that.
        if pausing { forceShow() }
    }

    func seekBy(_ delta: TimeInterval) {
        guard let p = playback else { return }
        let cur = TimeInterval(p.player.timemodel.currentTime)
        let total = TimeInterval(p.player.timemodel.totalTime)
        let t = min(max(0, cur + delta), max(0, total))
        p.seek(to: t)
        flash(delta >= 0 ? "⏩ +\(Int(delta))s" : "⏪ \(Int(delta))s")
        wake()
    }

    func jump(fraction: Double) {
        guard let p = playback else { return }
        let total = TimeInterval(p.player.timemodel.totalTime)
        seekBy(total * fraction)
    }

    /// Left (-1) / right (+1) on the bare picture. Stub: the pre-#466 fixed 10 s.
    /// E2: Android's 15 s burst escalating inside 900 ms, clamped to the end minus 200 ms.
    func seekKey(_ direction: Int) { seekBy(Double(direction) * 10) }

    /// Up (+1) / down (-1) on the bare picture. Stub: wakes the bar as before #466.
    /// E2: the 20 % jump, escalating (owner ruling D1).
    func jumpKey(_ direction: Int) { wake() }

    /// B key and the bar's Bookmark tile, only when the payload allows bookmarks.
    /// E8 implements PlaybackCoordinator.requestBookmark; E2 adds the "Bookmark @ m:ss" toast.
    func bookmark() {
        guard playback?.request?.allowBookmarks == true else { return }
        playback?.requestBookmark()
    }
}
