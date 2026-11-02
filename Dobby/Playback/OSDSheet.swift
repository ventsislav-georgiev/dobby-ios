import SwiftUI

/// One row of an OSD sheet. `action` runs on Return / click. A row with `adjust` is an arrow
/// row, drawn "◀ label ▶": left/right (or a click on a chevron) call `adjust(-1)` / `adjust(+1)`.
/// Picking never closes the sheet by itself; a component that wants Android's close-on-pick
/// calls `controls.closeSheet()` inside its action.
struct OSDItem: Identifiable {
    let id: String
    let label: String
    let detail: String?
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    let adjust: ((Int) -> Void)?
    init(id: String, label: String, detail: String? = nil, selected: Bool, enabled: Bool = true,
         adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) {
        self.id = id; self.label = label; self.detail = detail
        self.selected = selected; self.enabled = enabled; self.adjust = adjust; self.action = action
    }
}

/// What a sheet component hands the generic sheet: a title, an optional tab strip and rows.
/// Built fresh on every render from live player state (a component's `<name>SheetContent()`).
struct OSDSheetContent {
    var title: String
    var rows: [OSDItem]
    /// Tab strip under the title; empty hides it.
    var tabs: [String] = []
    var activeTab = 0
    /// Called with the new tab index (left/right when the focused row is not an arrow row, or a click).
    var selectTab: ((Int) -> Void)?
}

/// The generic track sheet (Android buildTrackSheet :2471-2524): a centred 420 pt card, at most
/// 60 % of the player's height, sheet fill, 1 pt accent hairline at 0x4D, title in bold accent,
/// optional tab strip, rows filled `row`, the focused row filled `accent` with `onAccent` text.
/// Keyboard focus is `focusIndex` (owned by PlayerControls); hover moves the same index, a
/// click focuses and picks. macOS: a click outside the card calls `onDismiss`. iOS (#487): no
/// dismiss layer, so the control bar and the close X stay tappable under an open sheet (#466 QA
/// N1); a tap on the picture lands on ControlBar.swift's touchRegions, which closes the top
/// layer. Rows, tabs and chevrons are at least 44 pt on iOS (`touchMin`); macOS keeps its sizes.
struct OSDSheetView: View {
    let content: OSDSheetContent
    let tint: OsdTint
    let focusIndex: Int
    let onFocus: (Int) -> Void
    let onPick: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                #if os(macOS)
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onDismiss)
                #endif
                card
                    .frame(width: min(420, geo.size.width - 32))
                    .frame(maxHeight: geo.size.height * 0.6)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint.accent)
            if !content.tabs.isEmpty { tabStrip.padding(.top, 8) }
            // Hug the rows when they fit (Android wraps content), scroll only past 60 %.
            ViewThatFits(in: .vertical) {
                rowStack
                ScrollViewReader { proxy in
                    ScrollView { rowStack }
                        .onAppear { proxy.scrollTo(focusIndex, anchor: .center) }
                        .onChange(of: focusIndex) { i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .osdCard(fill: tint.sheet, radius: 9, hairline: tint.accent(0x4D))
    }

    private var rowStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(content.rows.enumerated()), id: \.element.id) { idx, row in
                rowView(row, idx: idx).id(idx)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(content.tabs.enumerated()), id: \.offset) { i, tab in
                let active = i == content.activeTab
                Text(tab)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(active ? tint.onAccent : tint.tabText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(minHeight: Self.touchMin)
                    .background(active ? tint.accent : tint.row)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { content.selectTab?(i) }
            }
        }
    }

    private func rowView(_ row: OSDItem, idx: Int) -> some View {
        let focused = idx == focusIndex
        let fg: Color = focused ? tint.onAccent : (row.enabled ? tint.text : tint.text(0x66))
        let label = (row.selected ? "✓ " : "") + row.label
        return HStack(spacing: 6) {
            if let adjust = row.adjust {
                chevron("◀") { onFocus(idx); adjust(-1) }
                Text(label)
                chevron("▶") { onFocus(idx); adjust(1) }
            } else {
                Text(label)
            }
            Spacer(minLength: 4)
            if let d = row.detail {
                Text(d).font(.system(size: 11)).foregroundStyle(focused ? tint.onAccent : tint.text(0x99))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(fg)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .frame(minHeight: Self.touchMin)
        .background(focused ? tint.accent : tint.row)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .onHover { if $0 { onFocus(idx) } }
        .onTapGesture { onFocus(idx); onPick(idx) }
    }

    private func chevron(_ glyph: String, _ tap: @escaping () -> Void) -> some View {
        Text(glyph)
            .frame(minWidth: Self.touchMin, minHeight: Self.touchMin)
            .contentShape(Rectangle()).onTapGesture(perform: tap)
    }

    /// The touch target floor (Apple HIG 44 pt) on iOS; nil leaves the macOS sizes untouched.
    private static var touchMin: CGFloat? {
        #if os(iOS)
        44
        #else
        nil
        #endif
    }
}
