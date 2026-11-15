import Foundation

// #613: the native player's lifecycle policy, BackgroundVideo.swift.
@main
enum BackgroundVideoCheck {
    final class Track {}

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let v = Track(), other = Track()

        // FFmpeg engine with a video track: park it, and on return hand back that same track once.
        var m = BackgroundVideo()
        check(m.enterBackground(ffmpegEngine: true, videoTrack: v), "FFmpeg engine with video parks")
        check(m.enterForeground(currentTracks: [other, v]) === v, "return hands back the parked track")
        check(m.parked == nil, "return clears the parked track")
        check(m.enterForeground(currentTracks: [v]) == nil, "a second foreground does nothing")

        // The AVPlayer engine detaches its own layer: no parking, no resync.
        m = BackgroundVideo()
        check(!m.enterBackground(ffmpegEngine: false, videoTrack: v), "AVPlayer engine does not park")
        check(m.enterForeground(currentTracks: [v]) == nil, "AVPlayer engine gets no resync")

        // Audio-only (no enabled video track): nothing to park.
        m = BackgroundVideo()
        check(!m.enterBackground(ffmpegEngine: true, videoTrack: nil), "audio-only does not park")
        check(m.enterForeground(currentTracks: []) == nil, "audio-only gets no resync")

        // A player reopened in the background has new track objects: leave it alone, still clear.
        m = BackgroundVideo()
        _ = m.enterBackground(ffmpegEngine: true, videoTrack: v)
        check(m.enterForeground(currentTracks: [other]) == nil, "a reopened player is not resynced")
        check(m.parked == nil, "parked track cleared even when not handed back")

        // A later background on the AVPlayer engine replaces an earlier parked track.
        m = BackgroundVideo()
        _ = m.enterBackground(ffmpegEngine: true, videoTrack: v)
        _ = m.enterBackground(ffmpegEngine: false, videoTrack: other)
        check(m.enterForeground(currentTracks: [v, other]) == nil, "latest background wins")

        print("BackgroundVideoCheck: all checks passed")
    }
}
