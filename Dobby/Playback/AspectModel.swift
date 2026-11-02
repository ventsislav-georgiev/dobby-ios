import Foundation

// E7 (#472) owns this file with AspectSheet.swift: the pure aspect model (Android
// applyAspectAdjust :2965-2999, cycleAspectAdjust :3067-3131, per-title memory :3859-3950).
// No SwiftUI or KSPlayer import, so Tests/run-checks.sh compiles it standalone with
// Tests/AspectModelCheck.swift. #466 stub: the pre-#466 Fit / Fill / Zoom / Stretch presets.

struct AspectModel: Equatable {
    /// Fill (crop) through KSPlayer's gravity; everything else is a transform on the video only.
    var isFill = false
    var zoom = 1.0
    /// Vertical stretch.
    var stretch = 1.0

    /// What PlayerView's video transform reads (AspectSheet.swift aspectTransform).
    var scaleX: Double { zoom }
    var scaleY: Double { zoom * stretch }
}
