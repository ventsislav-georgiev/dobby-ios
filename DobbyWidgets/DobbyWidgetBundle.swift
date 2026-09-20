import WidgetKit
import SwiftUI
import ActivityKit

@main
struct DobbyWidgetBundle: WidgetBundle {
    var body: some Widget {
        DobbyNowPlayingActivity()
    }
}

/// Now Playing Live Activity — lock screen, Dynamic Island, and (the reason it
/// exists) the CarPlay Dashboard. `supplementalActivityFamilies([.small])` is what
/// makes CarPlay render the real view instead of falling back to the Dynamic Island
/// compact leading/trailing pair.
struct DobbyNowPlayingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DobbyPlaybackAttributes.self) { context in
            LockScreenView(state: context.state, kind: context.attributes.kind)
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: glyph(context.attributes.kind))
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        if !context.state.subtitle.isEmpty {
                            Text(context.state.subtitle).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        TimelineBar(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: glyph(context.attributes.kind))
            } compactTrailing: {
                if context.state.isLive {
                    Text("LIVE").font(.caption2)
                } else {
                    Text(timerInterval: context.state.startedAt...context.state.endsAt,
                         countsDown: true)
                        .font(.caption2)
                        .frame(maxWidth: 44)
                }
            } minimal: {
                Image(systemName: glyph(context.attributes.kind))
            }
        }
        .supplementalActivityFamilies([.small])
    }

    private func glyph(_ kind: String) -> String {
        kind == "book" ? "headphones" : "play.rectangle.fill"
    }
}

private struct LockScreenView: View {
    let state: DobbyPlaybackAttributes.ContentState
    let kind: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == "book" ? "headphones" : "play.rectangle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).font(.headline).lineLimit(1)
                if !state.subtitle.isEmpty {
                    Text(state.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                TimelineBar(state: state)
            }
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Self-updating progress. `ProgressView(timerInterval:)` advances on the widget's own
/// clock, so a paused-and-resumed item only needs one push, not one per second.
private struct TimelineBar: View {
    let state: DobbyPlaybackAttributes.ContentState

    var body: some View {
        if state.isLive || state.endsAt <= state.startedAt {
            Text(state.isLive ? "Live" : "").font(.caption2).foregroundStyle(.secondary)
        } else if state.isPlaying {
            ProgressView(timerInterval: state.startedAt...state.endsAt, countsDown: false)
                .tint(.white)
                .labelsHidden()
        } else {
            ProgressView(value: min(max(state.progress, 0), 1))
                .tint(.secondary)
                .labelsHidden()
        }
    }
}
