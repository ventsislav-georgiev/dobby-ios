import Foundation

/// #613: what the native player does to its video when the app goes to the background and back.
/// Audio keeps playing in the background (KSOptions.canBackgroundPlay). The AVPlayer engine detaches
/// its own layer (KSAVPlayer.enterBackground). The FFmpeg engine needs this: iOS invalidates its
/// VideoToolbox session in the background, and KSPlayer rebuilds that session on the next packet,
/// which can only decode from a keyframe. So the video stream is discarded while in the background
/// (no packets pile up, no decode against a dead session). On return the caller re-enables it and
/// seeks to the current time, so the first packet the decoder sees is a keyframe. This is the same
/// recovery MEPlayerItem.select(track:) uses.
/// Tracks are compared by identity, so a player reopened while in the background is left alone.
struct BackgroundVideo {
    private(set) var parked: AnyObject?

    /// didEnterBackground. True: the caller discards `videoTrack` (only on the FFmpeg engine,
    /// and only when it has an enabled video track).
    mutating func enterBackground(ffmpegEngine: Bool, videoTrack: AnyObject?) -> Bool {
        parked = ffmpegEngine ? videoTrack : nil
        return parked != nil
    }

    /// willEnterForeground. Returns the parked track if the current player still owns it; the
    /// caller re-enables it and seeks to the current time. Always clears the parked track.
    mutating func enterForeground(currentTracks: [AnyObject]) -> AnyObject? {
        defer { parked = nil }
        guard let p = parked, currentTracks.contains(where: { $0 === p }) else { return nil }
        return p
    }
}
