import SwiftUI
import KSPlayer

// E5 (#470) owns this file with StyleSheet.swift: the subtitle renderer. Draws in panel space,
// never under the aspect transform (#154). #466 moved the pre-#466 overlay here unchanged.

extension PlayerView {
    /// Always in the tree (PlayerView places it above the picture, below the OSD).
    var subtitleOverlay: some View {
        VStack {
            Spacer()
            ForEach(subtitles.parts) { part in
                if let text = part.text {
                    styledSubtitle(plainText(text))
                }
            }
        }
        .padding(.bottom, (controls.visible ? 120 : 56) + controls.subStyle.position)
        .animation(.easeInOut(duration: 0.18), value: controls.visible)
        .allowsHitTesting(false)
    }

    /// KSPlayer stamps `SubtitleModel.textFont` as a .font attribute over the whole
    /// string; an embedded attribute beats SwiftUI's .font() modifier, which made the
    /// style/size menu a no-op. Strip it so our styling applies.
    private func plainText(_ text: NSAttributedString) -> AttributedString {
        // KSPlayer's SRT/VTT parser leaves HTML-style tags (<i>, <b>, <u>) in the
        // cue text verbatim — render them instead of showing them.
        if text.string.contains("<") { return renderTags(text.string) }
        let m = NSMutableAttributedString(attributedString: text)
        m.removeAttribute(.font, range: NSRange(location: 0, length: m.length))
        return AttributedString(m)
    }

    /// Minimal subtitle tag renderer: applies <i>/<em>, <b>/<strong>, <u>;
    /// strips any other <...> tag (e.g. <font ...>). Not a full HTML parser —
    /// subtitle cues only ever carry this handful of tags.
    private func renderTags(_ s: String) -> AttributedString {
        var out = AttributedString()
        var italic = 0, bold = 0, underline = 0
        var buf = ""
        func flush() {
            guard !buf.isEmpty else { return }
            var run = AttributedString(buf)
            var intent: InlinePresentationIntent = []
            if italic > 0 { intent.insert(.emphasized) }
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
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
                case "b", "strong": bold = max(0, bold + delta)
                case "u": underline = max(0, underline + delta)
                default: break
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

    @ViewBuilder
    private func styledSubtitle(_ text: AttributedString) -> some View {
        let style = controls.subStyle.style
        let size = (style == .large ? 34.0 : 22.0) * controls.subStyle.scale
        switch style {
        case .standard:
            Text(text).font(.system(size: size)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 1, x: 1, y: 1)
                .multilineTextAlignment(.center)
        case .large:
            Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 1)
                .multilineTextAlignment(.center)
        case .contrast:
            Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
