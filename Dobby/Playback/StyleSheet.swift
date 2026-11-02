import Foundation
import CoreGraphics

// E5 (#470) owns this file with SubtitleOverlay.swift: the subtitle style sheet ("Aa") and the
// saved style, Android's addStyleRows / cycleSubtitleStyle / persist+loadSubtitleStyle. Imports
// Foundation and CoreGraphics only so Tests/StyleSheetCheck.swift can compile it on its own.

/// The saved subtitle look (Android SUB_SIZE_FRACTIONS / SUB_POSITION_FRACTIONS / SUB_BG_LABELS).
/// Device-wide, read when a player opens; PlayerControls.subStyle saves it on every change.
struct SubtitleStyleSettings: Equatable {
    /// Text height as a fraction of the player's height.
    static let sizeFractions = [0.040, 0.045, 0.050, 0.055, 0.060, 0.065, 0.070, 0.075,
                                0.080, 0.085, 0.090, 0.100, 0.110, 0.120]
    static let sizeLabels = ["4%", "4.5%", "5%", "5.5%", "6%", "6.5%", "7%", "7.5%",
                             "8%", "8.5%", "9%", "10%", "11%", "12%"]
    /// Bottom padding as a fraction of the player's height.
    static let positionFractions = (0..<20).map { Double($0) * 0.05 }
    static let positionLabels = ["Bottom"] + (1..<19).map { "+\($0 * 5)%" } + ["Top"]
    static let backgroundLabels = ["None", "Translucent", "Solid"]
    /// Black behind the text: Android 0x00 / 0x99 / 0xFF alpha.
    static let backgroundOpacities = [0.0, 0x99 / 255.0, 1.0]

    var sizeIndex = 2        // 5 %
    var positionIndex = 1    // +5 %
    var backgroundIndex = 2  // Solid

    var sizeFraction: Double { Self.sizeFractions[sizeIndex] }
    var positionFraction: Double { Self.positionFractions[positionIndex] }
    var backgroundOpacity: Double { Self.backgroundOpacities[backgroundIndex] }

    enum Knob { case size, position, background }

    /// One step left (-1) or right (+1), wrapping (Android cycleSubtitleStyle).
    mutating func cycle(_ knob: Knob, _ direction: Int) {
        func wrap(_ i: Int, _ n: Int) -> Int { ((i + direction) % n + n) % n }
        switch knob {
        case .size: sizeIndex = wrap(sizeIndex, Self.sizeFractions.count)
        case .position: positionIndex = wrap(positionIndex, Self.positionFractions.count)
        case .background: backgroundIndex = wrap(backgroundIndex, Self.backgroundLabels.count)
        }
    }

    private static let sizeKey = "dobby.subtitleSizeIndex"
    private static let positionKey = "dobby.subtitlePositionIndex"
    private static let backgroundKey = "dobby.subtitleBgIndex"
    // Pre-#470 keys (style / point-scale / points above the bottom), read only to migrate.
    private static let oldStyleKey = "dobby.subtitleStyle"
    private static let oldScaleKey = "dobby.subScale"
    private static let oldPositionKey = "dobby.subPos"

    /// Reads the saved look; writes nothing. A dimension never saved under the new keys is
    /// derived from the pre-#470 key when that exists, else Android's default. The first change
    /// in the sheet saves the new keys; the old ones are left as they are.
    static func load(_ read: (String) -> Any? = { UserDefaults.standard.object(forKey: $0) }) -> Self {
        var s = Self()
        let oldStyle = read(oldStyleKey) as? String
        func nearest(_ steps: [Double], _ v: Double) -> Int {
            steps.indices.min { abs(steps[$0] - v) < abs(steps[$1] - v) } ?? 0
        }
        func clamp(_ v: Int, _ n: Int) -> Int { min(max(v, 0), n - 1) }

        if let v = read(sizeKey) as? Int { s.sizeIndex = clamp(v, sizeFractions.count) }
        else if oldStyle != nil || read(oldScaleKey) != nil {
            // Old size = (Large ? 34 : 22) pt x scale; its 22 pt default maps to the 5 % default.
            let pts = (oldStyle == "large" ? 34.0 : 22.0) * ((read(oldScaleKey) as? Double) ?? 1)
            s.sizeIndex = nearest(sizeFractions, 0.05 * pts / 22)
        }
        if let v = read(positionKey) as? Int { s.positionIndex = clamp(v, positionFractions.count) }
        else if let pts = read(oldPositionKey) as? Double {
            // Points above the bottom on a typical 800 pt player: the old 40 pt default = +5 %.
            s.positionIndex = nearest(positionFractions, pts / 800)
        }
        if let v = read(backgroundKey) as? Int { s.backgroundIndex = clamp(v, backgroundLabels.count) }
        else if let oldStyle {
            // Old Default / Large drew a shadow only; High Contrast a 70 % black box.
            s.backgroundIndex = oldStyle == "contrast" ? 1 : 0
        }
        return s
    }

    func save(_ write: (Int, String) -> Void = { UserDefaults.standard.set($0, forKey: $1) }) {
        write(sizeIndex, Self.sizeKey)
        write(positionIndex, Self.positionKey)
        write(backgroundIndex, Self.backgroundKey)
    }

    /// Where an image (PGS / VobSub) subtitle lands in the player, in points. `origin` and
    /// `imageSize` are in the subtitle canvas' pixels (KSPlayer SubtitlePart.origin / image),
    /// `canvas` is the video's natural size: the canvas is fitted into `view` like the picture.
    /// Unknown canvas: bottom-centred, shrunk to fit and never enlarged (KSPlayer's own view).
    static func imageRect(origin: CGPoint, imageSize: CGSize, canvas: CGSize, view: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else {
            let k: CGFloat = min(1, view.width / imageSize.width, view.height / imageSize.height)
            let w: CGFloat = imageSize.width * k, h: CGFloat = imageSize.height * k
            return CGRect(x: (view.width - w) / 2, y: view.height - h, width: w, height: h)
        }
        let k: CGFloat = min(view.width / canvas.width, view.height / canvas.height)
        let x0: CGFloat = (view.width - canvas.width * k) / 2
        let y0: CGFloat = (view.height - canvas.height * k) / 2
        let x: CGFloat = x0 + origin.x * k, y: CGFloat = y0 + origin.y * k
        return CGRect(x: x, y: y, width: imageSize.width * k, height: imageSize.height * k)
    }
}

extension PlayerControls {
    /// Android addStyleRows: three arrow rows (left/right or a chevron steps them, Return or a
    /// click closes the sheet keeping the value, okRunsRowAction) and Reset, which stays open.
    func styleSheetContent() -> OSDSheetContent {
        let s = subStyle
        func row(_ id: String, _ label: String, _ knob: SubtitleStyleSettings.Knob) -> OSDItem {
            OSDItem(id: id, label: label, selected: false,
                    adjust: { [weak self] d in self?.subStyle.cycle(knob, d) },
                    action: { [weak self] in self?.closeSheet() })
        }
        return OSDSheetContent(title: "Subtitle style (◀/▶ to adjust)", rows: [
            row("size", "Font size: \(SubtitleStyleSettings.sizeLabels[s.sizeIndex])", .size),
            row("position", "Position: \(SubtitleStyleSettings.positionLabels[s.positionIndex])", .position),
            row("background", "Background: \(SubtitleStyleSettings.backgroundLabels[s.backgroundIndex])", .background),
            OSDItem(id: "reset", label: "Reset to default", selected: false,
                    action: { [weak self] in self?.subStyle = SubtitleStyleSettings() }),
        ])
    }

    /// The generic sheet keys do it all (left/right step the focused arrow row, Return picks).
    func styleSheetHandleKey(_ key: OSDKey) -> Bool { false }
}
