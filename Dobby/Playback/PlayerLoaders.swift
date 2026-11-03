import SwiftUI

// E11 (#476) owns this file: the preparing screen and the buffering loader (Android
// buildPreparingOverlay :1137-1212, the launch trace :1544-1555). The Mac keeps its instant close.

extension PlayerView {
    /// Always in the tree, above the subtitles; decides itself when to draw. Until the first
    /// ready state: the preparing screen. After it, a rebuffer runs the launch trace.
    var playerLoaders: some View {
        ZStack {
            if !controls.loaded {
                PreparingScreen(title: controls.playback?.request?.title ?? "",
                                accent: controls.tint.accent)
                    .transition(.opacity)
            } else if controls.buffering {
                TraceLoader(color: controls.tint.accent)
            }
        }
        .allowsHitTesting(false)
        // Android fades the preparing overlay out over 240 ms on the first frame.
        .animation(.easeOut(duration: 0.24), value: controls.loaded)
    }
}

/// Black screen, the launch trace centred (#525: something always moves), the title bottom-left
/// breathing 1 to 0.5 every 950 ms, the accent "STARTING NOW" kicker under it (Android px
/// halved: 900 px title width, 64 px margins).
private struct PreparingScreen: View {
    let title: String
    let accent: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            TraceLoader(color: accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .shadow(color: .black.opacity(0.8), radius: 6, y: 1)
                        // Reverse-repeating 1 -> 0.5 over 950 ms, eased like Android's default.
                        .opacity(0.75 + 0.25 * cos(.pi * t / 0.95))
                }
                Text("STARTING NOW")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(13 * 0.3)
                    .foregroundStyle(accent)
            }
            .frame(maxWidth: 450, alignment: .leading)
            .padding(32)
        }
    }
}

/// The launch trace (Android launch_trace.xml, #396/#445): 28 % of the D outline in the accent,
/// one lap per 1.6 s, no D mark under it, in the launch loader's 120 pt frame (#444).
private struct TraceLoader: View {
    let color: Color

    /// launch_trace pathData "M29,23H49A31,31 0 0 1 49,85H29Z" in its 108 viewport, traced twice
    /// so a window of 0.14 sliding over the first half wraps the corner without a second trim.
    private static let doubleD: Path = {
        var p = Path()
        for _ in 0..<2 {
            p.move(to: CGPoint(x: 29, y: 23))
            p.addLine(to: CGPoint(x: 49, y: 23))
            p.addRelativeArc(center: CGPoint(x: 49, y: 54), radius: 31,
                             startAngle: .degrees(-90), delta: .degrees(180))
            p.addLine(to: CGPoint(x: 29, y: 85))
            p.closeSubpath()
        }
        return p
    }()

    var body: some View {
        TimelineView(.animation) { tl in
            let phase = tl.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.6) / 1.6
            Self.doubleD
                .trimmedPath(from: phase / 2, to: phase / 2 + 0.14)
                .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                .frame(width: 108, height: 108)
                .scaleEffect(120.0 / 108.0)
        }
        .frame(width: 120, height: 120)
    }
}
