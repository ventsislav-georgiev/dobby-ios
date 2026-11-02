import Foundation
import KSPlayer

// E2 (#467) owns this file with ControlBar.swift: play/pause, keyboard and double-tap seek, the
// 20 % jump, the seek pill's timer, bookmark. Android: togglePlay, triggerSeekBurst,
// triggerJumpBurst, showSeekProgress, requestBookmark (PlaybackActivity.java).

/// E2's transport state: the two bursts and whether the seek pill is up.
struct TransportState {
    var seekBurst = SeekBurst()
    var jumpBurst = SeekBurst()
    /// The seek pill (ControlBar.swift) is up; it only draws while the bar is hidden.
    var pillShown = false
    var pillTask: Task<Void, Never>?
}

extension PlayerControls {
    /// Space, the bar's play tile. Android togglePlay: "Playing" / "Paused".
    func togglePlay() {
        let pausing = isPlaying
        playback?.togglePlayPause()
        flash(pausing ? "Paused" : "Playing")
        // Pausing shows the bar (pre-#466). A resume leaves it to syncState, which KSPlayer
        // calls synchronously from play(): it hides a bar that was up (Android
        // updatePlayPauseUi) or re-arms the 5 s hide; a forceShow here would undo that.
        if pausing { forceShow() }
    }

    /// Live position and duration, sub-second (the time model only ticks whole seconds).
    private var position: (live: Double, duration: Double)? {
        guard let p = playback?.player.playerLayer?.player else { return nil }
        return (p.currentPlaybackTime, p.duration)
    }

    /// Left (-1) / right (+1) on the bare picture, a double-tap on either half (iOS). Android
    /// triggerSeekBurst: 15 s, escalating inside 900 ms, clamped to the end minus 200 ms.
    func seekKey(_ direction: Int) {
        guard let pos = position else { return }
        let r = transport.seekBurst.press(direction, unit: 15, now: ProcessInfo.processInfo.systemUptime,
                                          live: pos.live, duration: pos.duration)
        playback?.seek(to: r.target)
        flash("\(direction > 0 ? "+" : "-")\(15 * r.count)s")
        showSeekPill()
    }

    /// Up (+1) / down (-1) on the bare picture. Android triggerJumpBurst: 20 % of the
    /// duration, 40 % on the next press inside 900 ms (owner ruling D1).
    func jumpKey(_ direction: Int) {
        guard let pos = position else { return }
        guard pos.duration > 0 else { flash("Duration unknown"); return }
        let r = transport.jumpBurst.press(direction, unit: pos.duration * 0.2, now: ProcessInfo.processInfo.systemUptime,
                                          live: pos.live, duration: pos.duration)
        playback?.seek(to: r.target)
        flash("\(direction > 0 ? "+" : "-")\(20 * r.count)%")
        showSeekPill()
    }

    /// Android showSeekProgress: the pill shows for 2.2 s after a seek, only while the bar is
    /// hidden (the bar carries the same progress).
    private func showSeekPill() {
        transport.pillTask?.cancel()
        guard !visible else { transport.pillShown = false; return }
        transport.pillShown = true
        transport.pillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)   // Android SEEK_PROGRESS_AUTO_HIDE_MS
            guard !Task.isCancelled else { return }
            self?.transport.pillShown = false
        }
    }

    /// B key and the bar's Bookmark tile, only when the payload allows bookmarks.
    /// E8 implements PlaybackCoordinator.requestBookmark; the toast is Android's.
    func bookmark() {
        guard playback?.request?.allowBookmarks == true else { return }
        playback?.requestBookmark()
        flash("Bookmark @ \(Self.clock(position?.live ?? 0))")
    }

    /// Android formatPosition: m:ss, or h:mm:ss from an hour.
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? max(0, seconds) : 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
