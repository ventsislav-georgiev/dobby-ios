import SwiftUI

/// The player OSD's colours, a port of the Android wrapper's OsdTint (#377/#395), chosen by
/// the play payload's `skin` (the page's currentSkinId()). Absent or unknown is Simple, the
/// Android default for the player; "appletv" is the Apple TV skin, the one the owner runs.
/// Colour only: sizes live in the views. ARGB literals are copied verbatim from OsdTint.java.
struct OsdTint: Equatable {
    /// Focus and selection fill; at lower alpha the hairlines and titles (`accent(_:)`).
    let accent: Color
    /// Glyph and text colour on `accent`.
    let onAccent: Color
    /// Progress bar played part; nil leaves the platform tint (Simple uses the theme's bar).
    let progress: Color?
    /// Toast and subtitle-delay pill fill.
    let osdFill: Color
    /// Control bar, seek pill and pause info cards.
    let panel: Color
    /// Track sheets and the shortcuts card.
    let sheet: Color
    /// An unfocused control tile, sheet row or tab.
    let row: Color
    /// Body text; `text(_:)` gives it at caption / plot / disabled alphas.
    let text: Color
    /// An inactive tab's text.
    let tabText: Color
    /// More menu card and its selected row.
    let menuCard: Color
    let menuSelected: Color

    private let accentRGB: UInt32
    private let textRGB: UInt32

    static let simple = OsdTint(accent: 0xFF5DADE2, onAccent: 0xFF000000, progress: nil,
                                osdFill: 0xCC101626, panel: 0xCC0A1024, sheet: 0xE6080C18, row: 0x33141E30,
                                text: 0xFFDFE7F2, tabText: 0xFF8FA3BF, menuCard: 0xDD1A1A2E, menuSelected: 0xFF3A3A5C)
    static let appleTV = OsdTint(accent: 0xFFF5F6FA, onAccent: 0xFF0C0D12, progress: 0xFFFFFFFF,
                                 osdFill: 0xCC1C1C1E, panel: 0xCC1C1C1E, sheet: 0xE62C2C2E, row: 0x333A3A3C,
                                 text: 0xFFFFFFFF, tabText: 0xB8FFFFFF, menuCard: 0xDD1C1C1E, menuSelected: 0xFF3A3A3C)

    /// OsdTint.forPayload: only an exact "appletv" switches skins.
    static func forSkin(_ skin: String?) -> OsdTint { skin == "appletv" ? .appleTV : .simple }

    /// The accent at an Android alpha byte (0x66 hairline, 0x4D sheet hairline, 0xB3 meta line).
    func accent(_ alpha: UInt8) -> Color { Color(argb: UInt32(alpha) << 24 | accentRGB) }
    func text(_ alpha: UInt8) -> Color { Color(argb: UInt32(alpha) << 24 | textRGB) }

    private init(accent: UInt32, onAccent: UInt32, progress: UInt32?, osdFill: UInt32, panel: UInt32,
                 sheet: UInt32, row: UInt32, text: UInt32, tabText: UInt32, menuCard: UInt32, menuSelected: UInt32) {
        self.accent = Color(argb: accent); self.onAccent = Color(argb: onAccent)
        self.progress = progress.map { Color(argb: $0) }
        self.osdFill = Color(argb: osdFill); self.panel = Color(argb: panel); self.sheet = Color(argb: sheet)
        self.row = Color(argb: row); self.text = Color(argb: text); self.tabText = Color(argb: tabText)
        self.menuCard = Color(argb: menuCard); self.menuSelected = Color(argb: menuSelected)
        self.accentRGB = accent & 0xFFFFFF; self.textRGB = text & 0xFFFFFF
    }
}

extension Color {
    /// Android-style 0xAARRGGBB.
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

extension View {
    /// The Android OSD card: a fill, a rounded rect and a 1 pt hairline (Android's 2 raw px on a
    /// density-2 Shield). Used by the toast, the sheets and any pill a component adds.
    func osdCard(fill: Color, radius: CGFloat, hairline: Color) -> some View {
        background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(hairline, lineWidth: 1))
    }
}

/// The OSD message (Android showOsd, PlaybackActivity onCreate :1595-1611): a top-centre pill,
/// 14 pt bold white on osdFill with the accent hairline at 0x66. Shown by `PlayerControls.flash`,
/// which owns the 1.4 s timer.
struct OSDToast: View {
    let message: String
    let tint: OsdTint

    var body: some View {
        VStack {
            Text(message)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .osdCard(fill: tint.osdFill, radius: 9, hairline: tint.accent(0x66))
                .padding(.top, 40)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
