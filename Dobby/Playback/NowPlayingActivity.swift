#if os(iOS)
import Foundation
import ActivityKit

/// Starts/updates/ends the Now Playing Live Activity.
///
/// Its real job is the CarPlay Dashboard: a Live Activity is the only card Dobby can
/// put on the car's home screen without an Apple CarPlay entitlement. Same view also
/// shows on the lock screen and in the Dynamic Island, so this is one push for three
/// surfaces.
///
/// iOS 26 is the floor — that is when `supplementalActivityFamilies` (the thing that
/// makes the dashboard render our view rather than a Dynamic Island crop) shipped.
@MainActor
final class NowPlayingActivity {
    static let shared = NowPlayingActivity()

    private var activity: Any?          // Activity<DobbyPlaybackAttributes>, type-erased for availability
    private var lastPush = Date.distantPast

    /// ActivityKit rate-limits updates; a per-frame progress callback would burn the
    /// budget in seconds. The widget runs its own timer, so a slow heartbeat is enough.
    private static let minPushInterval: TimeInterval = 15
    /// Lyrics are the exception: there is no widget-side primitive that can advance
    /// arbitrary text, so each line has to be pushed. These are local updates from a
    /// running app, not ActivityKit *push* notifications — the documented hourly
    /// budget is a push-only limit — but a floor still keeps a fast song from
    /// spamming the system.
    private static let minLyricPushInterval: TimeInterval = 1

    @discardableResult
    func start(title: String, subtitle: String, kind: String,
               elapsed: TimeInterval, duration: TimeInterval, isLive: Bool) -> Bool {
        guard #available(iOS 26.0, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        end()
        let state = Self.state(title: title, subtitle: subtitle,
                               elapsed: elapsed, duration: duration, isLive: isLive, isPlaying: true)
        do {
            activity = try Activity.request(
                attributes: DobbyPlaybackAttributes(kind: kind),
                content: .init(state: state, staleDate: nil)
            )
            lastPush = Date()
            return true
        } catch {
            NSLog("%@", "Dobby: Live Activity start failed: \(error.localizedDescription)")
            return false
        }
    }

    func update(title: String, subtitle: String,
                elapsed: TimeInterval, duration: TimeInterval, isLive: Bool,
                isPlaying: Bool, force: Bool = false) {
        guard #available(iOS 26.0, *), let activity = activity as? Activity<DobbyPlaybackAttributes> else { return }
        guard force || Date().timeIntervalSince(lastPush) >= Self.minPushInterval else { return }
        lastPush = Date()
        let state = Self.state(title: title, subtitle: subtitle,
                               elapsed: elapsed, duration: duration, isLive: isLive, isPlaying: isPlaying)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard #available(iOS 26.0, *), let activity = activity as? Activity<DobbyPlaybackAttributes> else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Spotify lyrics lane

    /// Starts (or restarts) the card in lyrics mode. `title`/`subtitle` carry the
    /// track, `line`/`nextLine` carry the words.
    @discardableResult
    func startLyrics(track: String, artist: String, duration: TimeInterval) -> Bool {
        guard #available(iOS 26.0, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        end()
        let state = Self.state(title: track, subtitle: artist,
                               elapsed: 0, duration: duration, isLive: false, isPlaying: true)
        do {
            activity = try Activity.request(
                attributes: DobbyPlaybackAttributes(kind: "lyrics"),
                content: .init(state: state, staleDate: nil)
            )
            lastPush = Date()
            return true
        } catch {
            NSLog("%@", "Dobby: lyrics Live Activity start failed: \(error.localizedDescription)")
            return false
        }
    }

    func updateLyrics(track: String, artist: String, line: String?, nextLine: String?,
                      elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard #available(iOS 26.0, *), let activity = activity as? Activity<DobbyPlaybackAttributes> else { return }
        guard Date().timeIntervalSince(lastPush) >= Self.minLyricPushInterval else { return }
        lastPush = Date()
        var state = Self.state(title: track, subtitle: artist,
                               elapsed: elapsed, duration: duration, isLive: false, isPlaying: isPlaying)
        state.line = line
        state.nextLine = nextLine
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    @available(iOS 26.0, *)
    private static func state(title: String, subtitle: String,
                              elapsed: TimeInterval, duration: TimeInterval,
                              isLive: Bool, isPlaying: Bool) -> DobbyPlaybackAttributes.ContentState {
        // Anchor the widget's timer to wall clock: "started" is now minus what has
        // already played, so the bar keeps advancing on its own between pushes.
        let now = Date()
        let total = max(duration, 0)
        return .init(
            title: title,
            subtitle: subtitle,
            isPlaying: isPlaying,
            startedAt: now.addingTimeInterval(-max(elapsed, 0)),
            endsAt: now.addingTimeInterval(max(total - elapsed, 0)),
            progress: total > 0 ? min(max(elapsed / total, 0), 1) : 0,
            isLive: isLive
        )
    }
}
#endif
