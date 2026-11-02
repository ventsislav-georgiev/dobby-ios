import Foundation

// E5 (#470) owns this file with SubtitleOverlay.swift: the subtitle style sheet ("Aa") and the
// saved style. #466 moved the pre-#466 style / size / position rows here unchanged from the
// subtitles menu, and the three UserDefaults keys with them.

/// Subtitle render style, mirrors the web app's default/large/contrast options.
enum SubtitleStyle: String, CaseIterable, Identifiable {
    case standard, large, contrast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Default"
        case .large: return "Large"
        case .contrast: return "High Contrast"
        }
    }
}

/// The saved subtitle look. PlayerControls.subStyle saves it on every change.
struct SubtitleStyleSettings: Equatable {
    var style: SubtitleStyle = .standard
    var scale: Double = 1.0
    /// Extra points above the bottom.
    var position: Double = 40

    private static let styleKey = "dobby.subtitleStyle"
    private static let scaleKey = "dobby.subScale"
    private static let positionKey = "dobby.subPos"

    static func load() -> SubtitleStyleSettings {
        let d = UserDefaults.standard
        var s = SubtitleStyleSettings()
        if let raw = d.string(forKey: styleKey), let v = SubtitleStyle(rawValue: raw) { s.style = v }
        if let v = d.object(forKey: scaleKey) as? Double { s.scale = v }
        if let v = d.object(forKey: positionKey) as? Double { s.position = v }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(style.rawValue, forKey: Self.styleKey)
        d.set(scale, forKey: Self.scaleKey)
        d.set(position, forKey: Self.positionKey)
    }
}

extension PlayerControls {
    func styleSheetContent() -> OSDSheetContent {
        var rows: [OSDItem] = []
        for style in SubtitleStyle.allCases {
            rows.append(OSDItem(id: "style-\(style.rawValue)", label: "Style: \(style.label)",
                                selected: subStyle.style == style, action: { [weak self] in
                self?.subStyle.style = style
                self?.flash("Subtitle style: \(style.label)")
            }))
        }
        // Size.
        for (label, scale) in [("Small", 0.75), ("Normal", 1.0), ("Large", 1.4), ("Huge", 1.8)] {
            rows.append(OSDItem(id: "size-\(scale)", label: "Size: \(label)",
                                selected: abs(subStyle.scale - scale) < 0.01, action: { [weak self] in
                self?.subStyle.scale = scale; self?.flash("Subtitle size: \(label)") }))
        }
        // Vertical position (extra points above the bottom).
        for (label, off) in [("Lower", 0.0), ("Default", 40.0), ("Higher", 120.0), ("Top", 280.0)] {
            rows.append(OSDItem(id: "pos-\(off)", label: "Position: \(label)",
                                selected: abs(subStyle.position - off) < 0.5, action: { [weak self] in
                self?.subStyle.position = off; self?.flash("Subtitle position: \(label)") }))
        }
        return OSDSheetContent(title: "Subtitle style", rows: rows)
    }

    /// Stub: the generic sheet keys apply (left/right already drive arrow rows).
    func styleSheetHandleKey(_ key: OSDKey) -> Bool { false }
}
