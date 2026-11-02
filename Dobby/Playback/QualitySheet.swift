import Foundation

// E4 (#469) owns this file with AudioSheet.swift: the quality sheet, Android populateTrackSheet
// "quality" + selectQualityOption. YouTube's payload options only (owner ruling: no per-format
// list); a pick switches the stream at the same position, toasts and closes the sheet.

extension PlayerControls {
    func qualitySheetContent() -> OSDSheetContent {
        let options = playback?.qualityOptions ?? []
        guard let p = playback, !options.isEmpty else {
            // Unreachable from the bar and q (both gated on options); Android's empty row.
            return OSDSheetContent(title: "Quality", rows: [OSDItem(id: "none", label: "No quality options available", selected: false, enabled: false, action: {})])
        }
        return OSDSheetContent(title: "Quality", rows: options.enumerated().map { idx, opt in
            let label = opt.label ?? "Quality \(idx + 1)"
            return OSDItem(
                id: "q\(idx)",
                label: label,
                selected: opt.videoUrl != nil && opt.videoUrl == p.currentVideoUrl,
                action: { [weak self] in
                    p.selectQuality(opt)
                    self?.flash("Quality: \(label)")
                    self?.closeSheet()
                })
        })
    }

    /// The generic sheet keys apply.
    func qualitySheetHandleKey(_ key: OSDKey) -> Bool { false }
}
