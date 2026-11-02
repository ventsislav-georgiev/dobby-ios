import SwiftUI
import KSPlayer

// E5 (#470) owns this file with StyleSheet.swift: the subtitle renderer (Android
// applySubtitleStyle). Draws in panel space, never under the aspect transform (#154).

extension PlayerView {
    /// Always in the tree (PlayerView places it above the picture, below the OSD).
    var subtitleOverlay: some View {
        SubtitleOverlayView(parts: subtitles.parts, style: controls.subStyle,
                            barVisible: controls.visible,
                            canvas: playback.player.playerLayer?.player.naturalSize ?? .zero)
            .animation(.easeInOut(duration: 0.18), value: controls.visible)
            .allowsHitTesting(false)
    }
}

/// Text cues: white bold with a black outline, size and lift as fractions of the player's height
/// (size: its shorter side), the chosen background behind them; embedded styles and fonts
/// ignored, <i>/<u> kept.
/// Image cues (PGS, VobSub): drawn where their canvas puts them on the fitted picture.
struct SubtitleOverlayView: View {
    let parts: [SubtitlePart]
    let style: SubtitleStyleSettings
    let barVisible: Bool
    /// The video's natural size, the image cues' canvas (.zero = unknown).
    let canvas: CGSize

    var body: some View {
        ZStack {
            // The picture ignores the safe area, so the image canvas has to as well.
            GeometryReader { geo in
                ForEach(parts) { part in
                    if let image = part.image {
                        let r = SubtitleStyleSettings.imageRect(origin: part.origin, imageSize: image.size,
                                                                canvas: canvas, view: geo.size)
                        Image(uiImage: image).resizable()
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                }
            }
            .ignoresSafeArea()

            GeometryReader { geo in
                let h = geo.size.height
                // Android sizes from the height of a landscape screen; a portrait phone's
                // equivalent is its width, or a 5 % cue would fill the screen.
                let size = min(h, geo.size.width) * style.sizeFraction
                // While the bar shows, never under it (the pre-#470 overlay's 120 pt lift).
                let lift = max(h * style.positionFraction, barVisible ? 120 : 0)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: size * 0.15) {
                        ForEach(parts) { part in
                            if part.image == nil, let text = part.text {
                                SubtitleLine(text: Self.render(text.string), size: size,
                                             background: style.backgroundOpacity)
                            }
                        }
                    }
                    .layoutPriority(2)
                    // Taller text than the space above the lift eats the lift, never the top edge
                    // (Android clamps a cue to the top the same way).
                    Spacer(minLength: 0).frame(maxHeight: lift).layoutPriority(1)
                }
                .padding(.horizontal, geo.size.width * 0.05)
                .frame(width: geo.size.width, height: h)
            }
        }
    }

    /// KSPlayer's SRT/VTT parser leaves HTML-style tags (<i>, <b>, <u>) in the cue text
    /// verbatim: apply those, strip any other <...> tag (e.g. <font ...>). Not a full HTML
    /// parser; subtitle cues only ever carry this handful of tags.
    static func render(_ s: String) -> AttributedString {
        var out = AttributedString()
        var italic = 0, underline = 0
        var buf = ""
        func flush() {
            guard !buf.isEmpty else { return }
            var run = AttributedString(buf)
            if italic > 0 { run.inlinePresentationIntent = .emphasized }
            if underline > 0 { run.underlineStyle = .single }
            out += run
            buf = ""
        }
        var idx = s.startIndex
        while idx < s.endIndex {
            if s[idx] == "<", let close = s[idx...].firstIndex(of: ">") {
                let tag = s[s.index(after: idx)..<close].lowercased()
                let closing = tag.hasPrefix("/")
                let name = (closing ? tag.dropFirst() : tag[...]).prefix { !$0.isWhitespace }
                flush()
                let delta = closing ? -1 : 1
                switch name {
                case "i", "em": italic = max(0, italic + delta)
                case "u": underline = max(0, underline + delta)
                default: break   // <b> too: the text is always bold
                }
                idx = s.index(after: close)
            } else {
                buf.append(s[idx])
                idx = s.index(after: idx)
            }
        }
        flush()
        return out
    }
}

/// One cue: Android CaptionStyleCompat(WHITE, background, transparent window, EDGE_TYPE_OUTLINE,
/// BLACK, DEFAULT_BOLD). The outline is eight black copies around the white text.
private struct SubtitleLine: View {
    let text: AttributedString
    let size: CGFloat
    let background: Double

    var body: some View {
        let o = max(1, size / 24)
        let offsets: [CGSize] = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
            .map { CGSize(width: Double($0.0) * o, height: Double($0.1) * o) }
        return line(.white)
            .background {
                ZStack { ForEach(offsets.indices, id: \.self) { line(.black).offset(offsets[$0]) } }
            }
            .padding(.horizontal, size * 0.25)
            .background(Color.black.opacity(background))
    }

    private func line(_ color: Color) -> some View {
        Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
