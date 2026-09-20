#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity contract, shared by the app (which starts and updates it) and the
/// widget extension (which renders it).
///
/// The CarPlay angle: a Live Activity renders on the CarPlay Dashboard without any
/// CarPlay entitlement — the Developer Guide is explicit that "your app does not need
/// to be a CarPlay app to support Live Activities in CarPlay". Declaring the `.small`
/// supplemental activity family (see the widget) is what puts *this* view on the
/// dashboard instead of a cramped Dynamic Island fallback.
struct DobbyPlaybackAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String
        var isPlaying: Bool
        /// Absolute wall-clock window of the current item, so the widget can run a
        /// self-updating timer instead of us pushing an update every second (each
        /// push is rate-limited and costs budget).
        var startedAt: Date
        var endsAt: Date
        /// Elapsed fraction at the moment of the push — the paused view has no clock
        /// to run, so it draws this instead.
        var progress: Double

        var isLive: Bool
    }

    /// Set once when the activity starts; the item's own artwork is not carried here
    /// (ActivityKit payloads are size-capped — the widget draws a glyph instead).
    var kind: String     // "book" | "video"
}
#endif
