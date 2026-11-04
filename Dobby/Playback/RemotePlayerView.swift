import SwiftUI

/// #541: the native remote player, the sender side of the remote control. This phone decodes nothing: it shows
/// the session the PWA pushes (RemotePlayerModel) over the poster, in the player's own OSD pieces (the bar's
/// card and tiles, the progress band, the track sheet), and every control goes back to the PWA, which sends
/// the hub command. Close leaves the session to the PWA's mini bar. ContentView places it over everything,
/// iOS only; it draws and takes touches only while the model has a view.
struct RemotePlayerView: View {
    @ObservedObject var model: RemotePlayerModel
    /// Seconds under the finger while the band is dragged.
    @State private var scrub: Double?
    /// The owner's skin (the one dark, white-glyph tint, closest to a music app's now playing). The sender has no
    /// play payload to read a skin from.
    private let tint = OsdTint.appleTV

    var body: some View {
        ZStack {
            if let v = model.view {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in player(v, now: ctx.date) }
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(model.view != nil)
        .animation(.easeInOut(duration: 0.2), value: model.view == nil)
        .animation(.easeInOut(duration: 0.16), value: model.sheet)
    }

    private func player(_ v: RemoteView, now: Date) -> some View {
        ZStack {
            backdrop(v)
            VStack(spacing: 14) {
                Spacer(minLength: PlayerView.topSafeInset + 56)
                artwork(v)
                VStack(spacing: 4) {
                    Text(v.title).font(.system(size: 20, weight: .bold)).foregroundStyle(tint.text)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Text(v.status).font(.system(size: 14)).foregroundStyle(tint.text(0xB3))
                }
                .padding(.horizontal, 24)
                Spacer(minLength: 0)
                ControlBarLook(tint: tint) { strip(v, now: now) } row: { tiles(v) }
            }
            VStack { HStack { closeButton; Spacer() }; Spacer() }.padding(.top, PlayerView.topSafeInset)
            if let kind = model.sheet {
                OSDSheetView(content: sheet(kind, v), tint: tint,
                             focusIndex: (kind == .audio ? v.audio : v.subtitle).firstIndex { $0.selected } ?? 0,
                             onFocus: { _ in }, onPick: { pick(kind, v, $0) }, onDismiss: { model.sheet = nil })
                    .background(Color.black.opacity(0.001).onTapGesture { model.sheet = nil })
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // The player's left-edge back swipe (#197): an open picker closes first, else the remote player.
        .simultaneousGesture(DragGesture(minimumDistance: 30, coordinateSpace: .global).onEnded { g in
            guard g.startLocation.x < 24, g.translation.width > 50 else { return }
            if model.sheet != nil { model.sheet = nil } else { model.press(.close) }
        })
    }

    // MARK: Poster

    /// The blurred poster fills the screen as an overlay of it, so a filled (wider) image never sizes the player.
    private func backdrop(_ v: RemoteView) -> some View {
        Color.black
            .overlay { poster(v).scaledToFill().blur(radius: 40).opacity(0.55) }
            .overlay { LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom) }
            .clipped()
            .ignoresSafeArea()
    }

    private func artwork(_ v: RemoteView) -> some View {
        poster(v).scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(radius: 12)
            .frame(maxWidth: 360, maxHeight: 360)
            .padding(.horizontal, 32)
    }

    private func poster(_ v: RemoteView) -> some View {
        AsyncImage(url: URL(string: v.poster)) { image in image.resizable() } placeholder: { Color.clear }
    }

    // MARK: Progress (ControlBar.swift's label and band)

    private func strip(_ v: RemoteView, now: Date) -> some View {
        let total = max(1, v.dur)
        let current = scrub ?? v.position(at: now)
        return GeometryReader { geo in
            VStack(spacing: 3) {
                HStack(spacing: 0) {
                    Text(PlayerControls.clock(current)); Text(" / "); Text(PlayerControls.clock(v.dur))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(tint.text)
                .frame(maxWidth: .infinity)
                ProgressBand(played: min(1, max(0, current / total)), buffered: 0, tint: tint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                scrub = ScrubState.target(x: d.location.x, width: geo.size.width, duration: v.dur)
            }.onEnded { _ in
                if let s = scrub { model.press(.seek(s)) }
                scrub = nil
            })
        }
    }

    // MARK: Tiles (ControlBar.swift's BarTileFace, one row where it fits, else two)

    private struct Tile: Hashable {
        let glyph: String
        let caption: String
        let button: RemoteButton?
        let sheet: RemoteTrackKind?
    }

    private func tileList(_ v: RemoteView) -> [Tile] {
        var t = [Tile(glyph: "\u{21BA}\u{FE0E}", caption: "-15 s", button: .back15, sheet: nil),
                 Tile(glyph: v.paused ? BarTile.play.glyph : BarTile.pauseGlyph, caption: v.paused ? "Play" : "Pause",
                      button: v.paused ? .play : .pause, sheet: nil),
                 Tile(glyph: "\u{21BB}\u{FE0E}", caption: "+15 s", button: .forward15, sheet: nil)]
        if !v.audio.isEmpty { t.append(Tile(glyph: BarTile.audio.glyph, caption: BarTile.audio.caption, button: nil, sheet: .audio)) }
        if !v.subtitle.isEmpty {
            t.append(Tile(glyph: BarTile.subtitles.glyph, caption: BarTile.subtitles.caption, button: nil, sheet: .subtitle))
        }
        if v.canNext { t.append(Tile(glyph: "\u{23ED}\u{FE0E}", caption: "Next", button: .next, sheet: nil)) }
        t.append(Tile(glyph: "\u{25A0}\u{FE0E}", caption: "Stop", button: .stop, sheet: nil))
        return t
    }

    private func tiles(_ v: RemoteView) -> some View {
        let all = tileList(v)
        let half = (all.count + 1) / 2
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ForEach(all, id: \.self) { tile($0) } }
            VStack(spacing: 4) {
                ForEach([Array(all[..<half]), Array(all[half...])], id: \.self) { line in
                    HStack(spacing: 4) {
                        ForEach(line, id: \.self) { tile($0, fill: true) }
                        ForEach(line.count..<half, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                    }
                }
            }
        }
    }

    private func tile(_ t: Tile, fill: Bool = false) -> some View {
        Button {
            if let b = t.button { model.press(b) } else { model.sheet = t.sheet }
        } label: {
            BarTileFace(glyph: t.glyph, caption: t.caption, lit: t.sheet != nil && model.sheet == t.sheet, tint: tint, fill: fill)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.caption)
    }

    // MARK: Track pickers (OSDSheet.swift)

    private func sheet(_ kind: RemoteTrackKind, _ v: RemoteView) -> OSDSheetContent {
        let rows = kind == .audio ? v.audio : v.subtitle
        return OSDSheetContent(title: kind == .audio ? "Audio" : "Subtitles",
                               rows: rows.map { r in OSDItem(id: r.id, label: r.label, selected: r.selected) {} })
    }

    private func pick(_ kind: RemoteTrackKind, _ v: RemoteView, _ i: Int) {
        let rows = kind == .audio ? v.audio : v.subtitle
        guard rows.indices.contains(i) else { return }
        model.press(kind == .audio ? .audio(rows[i].id) : .subtitle(rows[i].id))
    }

    private var closeButton: some View {
        Button { model.press(.close) } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 3)
                .padding(16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
