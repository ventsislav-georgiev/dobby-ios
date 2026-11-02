import SwiftUI
import KSPlayer

// E10 (#475) owns this file: the pause media-info cards (Android buildMediaInfoPanel
// :2047-2140), from the payload's title, subtitle, description and thumb (else poster). The
// content and visibility rules are pure, in PauseInfoModel.swift.

extension PlayerView {
    /// Always in the tree, just under the control bar layer. Shown only while paused with the
    /// bar up and no layer open (PauseInfoModel.shows). Never hit-tested: a click or tap lands
    /// on the picture below, which hides the bar and the cards with it (iOS: "tap anywhere
    /// dismisses the card"; Mac: click = OK = hide the bar).
    @ViewBuilder var pauseInfoCards: some View {
        if let req = playback.request {
            let model = PauseInfoModel(title: req.title, subtitle: req.subtitle,
                                       description: req.description, thumb: req.thumb, poster: req.poster)
            if model.hasText {
                let show = model.shows(paused: playback.player.state == .paused, barVisible: controls.visible,
                                       layerOpen: controls.anyLayerOpen, smartTube: req.playbackKind == "smarttube")
                // Kept in the tree while hidden (Android INVISIBLE, not GONE) so the still is
                // fetched once per title, not on every pause.
                VStack(spacing: 0) {
                    Spacer()
                    PauseInfoCardsRow(model: model, tint: controls.tint)
                        .padding(.horizontal, 22)   // the bar's own horizontal padding: same edges
                    // An invisible twin of the bar so the cards sit right on top of it whatever
                    // its height (E2 owns it, and portrait iOS wraps it to a tighter row). The
                    // bar's 14 pt top padding is Android's 14 dp gap.
                    if controls.visible { controlBar.hidden() }
                }
                .opacity(show ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(!show)
            }
        }
    }
}

/// The two pills: a poster card (still, title, meta line) and the plot card, as tall as each
/// other. Side by side when the width allows, else stacked (portrait iPhone).
struct PauseInfoCardsRow: View {
    let model: PauseInfoModel
    let tint: OsdTint
    @State private var still: Image?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                posterCard
                if model.plot != nil { plotCard.frame(minWidth: 220, idealWidth: 220, maxWidth: .infinity) }
            }
            .fixedSize(horizontal: false, vertical: true)   // both pills as tall as the taller one
            VStack(alignment: .leading, spacing: 12) {
                posterCard
                if model.plot != nil { plotCard }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: model.image) { await loadStill() }
    }

    /// No still and no title would be an empty square (Android applyMediaInfoContent).
    @ViewBuilder private var posterCard: some View {
        if model.title != nil || still != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let still {
                    still.resizable().aspectRatio(contentMode: .fit)   // FIT, never crop: some sources send a portrait poster
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(width: 228, height: 128)
                        .padding(.bottom, 12)
                }
                if let title = model.title {
                    Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .lineLimit(2).lineSpacing(2)
                }
                if let meta = model.meta {
                    Text(meta).font(.system(size: 12)).foregroundStyle(tint.accent(0xB3))
                        .lineLimit(1).padding(.top, 4)
                }
            }
            .frame(width: 228, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(14)
            .osdCard(fill: tint.panel, radius: 7, hairline: tint.accent(0x66))   // 14 raw px, 2 px stroke halved
        }
    }

    private var plotCard: some View {
        Text(model.plot ?? "")
            .font(.system(size: 14)).foregroundStyle(tint.text(0xE6))
            .lineSpacing(14 * 0.35).lineLimit(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .osdCard(fill: tint.panel, radius: 7, hairline: tint.accent(0x66))
    }

    /// URLSession straight to the CDN (PauseInfoModel unwrapped any Pi-less proxy URL). A failed
    /// fetch just leaves the card without its still, as on Android.
    private func loadStill() async {
        still = nil
        guard let url = model.image,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        #if os(macOS)
        if let img = NSImage(data: data) { still = Image(nsImage: img) }
        #else
        if let img = UIImage(data: data) { still = Image(uiImage: img) }
        #endif
    }
}
