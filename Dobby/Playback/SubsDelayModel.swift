import Foundation

// E6 (#471) owns this file with SubsDelayPill.swift: the pure subtitle delay model (Android
// adjust :8312-8336, fps correction :8287-8310). No SwiftUI or KSPlayer import, so
// Tests/run-checks.sh compiles it standalone with Tests/SubsDelayModelCheck.swift.
// #466 stub: the pre-#466 delay presets, stepped by the pill's left/right.

struct SubsDelayModel: Equatable {
    /// Seconds; positive shows subtitles later. Applied to KSPlayer by PlayerControls.applySubsDelay.
    var delay: Double = 0

    static let presets: [Double] = [-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0]

    /// One preset left (-1) or right (+1), clamped at the ends. A delay between presets
    /// (set by the page) steps to the nearest preset in that direction.
    mutating func step(_ direction: Int) {
        let next = direction < 0
            ? Self.presets.last(where: { $0 < delay - 0.001 })
            : Self.presets.first(where: { $0 > delay + 0.001 })
        if let next { delay = next }
    }

    var label: String { delay == 0 ? "0s" : String(format: "%+.1fs", delay) }
}
