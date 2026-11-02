import SwiftUI
import KSPlayer

// E7 (#472) owns this file with AspectModel.swift: the aspect sheet, how the model reaches the
// picture, auto stretch and per-title memory. #466 moved the pre-#466 rows here unchanged.

extension PlayerControls {
    /// Pushes the parts KSPlayer owns (gravity). Called on first load (syncState) and on a pick.
    /// E7: metadata auto stretch and the per-title restore hang off the first-load call.
    func applyAspect() { playback?.player.isScaleAspectFill = aspect.isFill }

    func setAspect(fill: Bool, zoom z: Double, stretch s: Double) {
        aspect = AspectModel(isFill: fill, zoom: z, stretch: s)
        applyAspect()
        forceShow()
    }

    func aspectSheetContent() -> OSDSheetContent {
        let a = aspect
        let plain = !a.isFill && a.zoom == 1 && a.stretch == 1
        var rows: [OSDItem] = [
            OSDItem(id: "fit", label: "Fit", selected: plain, action: { [weak self] in
                self?.setAspect(fill: false, zoom: 1, stretch: 1); self?.flash("Aspect: Fit") }),
            OSDItem(id: "fill", label: "Fill (crop)", selected: a.isFill, action: { [weak self] in
                self?.setAspect(fill: true, zoom: 1, stretch: 1); self?.flash("Aspect: Fill") }),
        ]
        for pct in [5, 10, 15, 20] {
            let z = 1 + Double(pct) / 100
            rows.append(OSDItem(id: "zoom\(pct)", label: "Zoom +\(pct)%",
                                selected: !a.isFill && abs(a.zoom - z) < 0.001 && a.stretch == 1, action: { [weak self] in
                self?.setAspect(fill: false, zoom: z, stretch: 1); self?.flash("Zoom +\(pct)%") }))
        }
        for pct in [5, 10, 15, 20] {
            let s = 1 + Double(pct) / 100
            rows.append(OSDItem(id: "stretch\(pct)", label: "Stretch +\(pct)%",
                                selected: !a.isFill && abs(a.stretch - s) < 0.001 && a.zoom == 1, action: { [weak self] in
                self?.setAspect(fill: false, zoom: 1, stretch: s); self?.flash("Stretch +\(pct)%") }))
        }
        return OSDSheetContent(title: "Aspect", rows: rows)
    }

    /// Stub: the generic sheet keys apply (left/right already drive arrow rows).
    func aspectSheetHandleKey(_ key: OSDKey) -> Bool { false }
}

extension View {
    /// The video-only transform PlayerView applies to the picture (never to subtitles or the
    /// OSD, #154). E7: stretch width, position Y (an offset needs the view height: read it
    /// with a GeometryReader or visualEffect inside this modifier).
    func aspectTransform(_ a: AspectModel) -> some View {
        scaleEffect(x: a.scaleX, y: a.scaleY)   // Zoom (uniform) + Stretch (vertical only)
    }
}
