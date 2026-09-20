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
