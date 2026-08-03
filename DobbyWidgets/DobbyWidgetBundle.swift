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
                        if context.attributes.kind == "lyrics" {
                            LyricsBody(state: context.state, compact: true)
                        } else {
                            Text(context.state.title).font(.headline).lineLimit(1)
                            if !context.state.subtitle.isEmpty {
                                Text(context.state.subtitle).font(.caption)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            TimelineBar(state: context.state)
                        }
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
        switch kind {
        case "book": return "headphones"
        case "lyrics": return "music.note.list"
        default: return "play.rectangle.fill"
        }
    }
}

private struct LockScreenView: View {
    let state: DobbyPlaybackAttributes.ContentState
    let kind: String
    /// `.small` is what CarPlay and the Watch Smart Stack render. The dashboard
    /// card is a fraction of the lock screen's width, so the lyric gets all of it
    /// and the track name is dropped.
    @Environment(\.activityFamily) private var family

    var body: some View {
        if kind == "lyrics" {
            LyricsBody(state: state, compact: family == .small)
                .padding(family == .small ? 8 : 16)
        } else {
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
}

/// The words, and only the words. This is the entire point of the lane: at a
/// glance from the driver's seat, the current line has to win and everything
/// else has to get out of its way.
private struct LyricsBody: View {
    let state: DobbyPlaybackAttributes.ContentState
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            if !compact, !state.title.isEmpty {
                Text(state.subtitle.isEmpty ? state.title : "\(state.title) · \(state.subtitle)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(state.line?.isEmpty == false ? state.line! : "♪")
                .font(compact ? .headline : .title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let next = state.nextLine, !next.isEmpty {
                Text(next)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
