import Foundation

// E4 (#469) owns this file with AudioSheet.swift: the quality sheet (YouTube options only,
// owner ruling D5). #466 moved the pre-#466 rows here unchanged.

extension PlayerControls {
    func qualitySheetContent() -> OSDSheetContent {
        guard let p = playback else { return OSDSheetContent(title: "Quality", rows: []) }
        let options = p.qualityOptions
        guard !options.isEmpty else {
            // HLS lane: AVPlayer's ABR picks renditions itself.
            return OSDSheetContent(title: "Quality", rows: [OSDItem(id: "auto", label: "Auto (adaptive)", selected: true, enabled: false, action: {})])
        }
        return OSDSheetContent(title: "Quality", rows: options.enumerated().map { idx, opt in
            let label = opt.label ?? opt.height.map { "\($0)p" } ?? "Option \(idx + 1)"
            return OSDItem(
                id: "q\(idx)",
                label: label,
                selected: opt.videoUrl != nil && opt.videoUrl == p.currentVideoUrl,
                action: { [weak self] in
                    p.selectQuality(opt)
                    self?.flash("Quality: \(label)")
                })
        })
    }

    /// Stub: the generic sheet keys apply.
    func qualitySheetHandleKey(_ key: OSDKey) -> Bool { false }
}
