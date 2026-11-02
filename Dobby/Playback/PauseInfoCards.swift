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
        if let model = pauseInfoModel {
            let show = pauseCardsShown
            // Kept in the tree while hidden (Android INVISIBLE, not GONE) so the still is
            // fetched once per title, not on every pause.
            PauseInfoCardsLayer(model: model, tint: controls.tint, cover: $pauseCardsCover) {
                if controls.visible { controlBar }
            }
            .opacity(show ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(!show)
        }
    }

    private var pauseInfoModel: PauseInfoModel? {
        guard let req = playback.request else { return nil }
        let model = PauseInfoModel(title: req.title, subtitle: req.subtitle, description: req.description,
                                   thumb: req.thumb, poster: req.poster)
        return model.hasText ? model : nil
    }

    /// The cards are on screen; the subtitle overlay lifts a cue above them (#496).
    var pauseCardsShown: Bool {
        guard let model = pauseInfoModel, let req = playback.request else { return false }
        return model.shows(paused: playback.player.state == .paused, barVisible: controls.visible,
                           layerOpen: controls.anyLayerOpen, smartTube: req.playbackKind == "smarttube")
    }
}

/// The cards sized to the bar: an invisible twin of the bar (E2 owns it; its width follows the
/// tile row, capped and centred) is measured, and the cards take its card width and sit 14 pt
/// (Android's 14 dp) above it, whatever its height. `cover` reports how far up from the bottom
/// the cards reach, so a subtitle cue can sit above them instead of showing through (#496).
struct PauseInfoCardsLayer<Bar: View>: View {
    let model: PauseInfoModel
    let tint: OsdTint
    @Binding var cover: CGFloat
    @ViewBuilder let bar: Bar
    @State private var barWidth: CGFloat = 0

    /// ControlBarLook pads its card 44 pt off each side; the twin's measured width includes that.
    private static var barSideInset: CGFloat { 44 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                PauseInfoCardsRow(model: model, tint: tint)
                    .frame(width: max(0, barWidth - 2 * Self.barSideInset))
                    .padding(.bottom, 14)
                bar.hidden()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in if w > 0 { barWidth = w } }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in cover = h }
        }
    }
}

/// The two pills: a poster card (still, title, meta line) and the plot card, as tall as each
/// other. Side by side when the width allows, else stacked (portrait iPhone), where the poster
/// card turns compact (#496): a thumbnail at the leading edge, title and meta beside it, the
/// card as wide as the plot card and the bar.
struct PauseInfoCardsRow: View {
    let model: PauseInfoModel
    let tint: OsdTint
    @State private var still: Image?
    /// The still's width over its height, so the compact thumbnail has no empty margins.
    @State private var stillAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                posterCard
                if model.plot != nil { plotCard.frame(minWidth: 220, idealWidth: 220, maxWidth: .infinity) }
            }
            .fixedSize(horizontal: false, vertical: true)   // both pills as tall as the taller one
            VStack(alignment: .leading, spacing: 12) {
                compactPosterCard
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

    /// The stacked layout's poster card: Android has no phone layout, so this is ours.
    @ViewBuilder private var compactPosterCard: some View {
        if model.title != nil || still != nil {
            HStack(alignment: .center, spacing: 12) {
                if let still {
                    let h: CGFloat = 72
                    still.resizable().aspectRatio(contentMode: .fit)
                        .frame(width: min(128, h * stillAspect), height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let title = model.title {
                        Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(2).lineSpacing(2)
                    }
                    if let meta = model.meta {
                        Text(meta).font(.system(size: 12)).foregroundStyle(tint.accent(0xB3)).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .osdCard(fill: tint.panel, radius: 7, hairline: tint.accent(0x66))
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
        guard let img = NSImage(data: data) else { return }
        still = Image(nsImage: img)
        #else
        guard let img = UIImage(data: data) else { return }
        still = Image(uiImage: img)
        #endif
        if img.size.width > 0, img.size.height > 0 { stillAspect = img.size.width / img.size.height }
    }
}
