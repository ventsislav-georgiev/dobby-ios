import Foundation

// E3 (#468) owns this file: the pure ordering behind the subtitles sheet (Android
// orderedSubtitleEntries :7395-7436, tabs :4649-4702). No SwiftUI or KSPlayer import, so
// Tests/run-checks.sh compiles it standalone with Tests/SubtitleOrderingCheck.swift.

enum SubtitleOrdering {
    /// The payload's preferredSubtitleLang / preferredAudioLang comma list ("bg, en") as
    /// lowercased codes in order, blanks and repeats dropped.
    static func preferredLanguages(_ csv: String?) -> [String] {
        var out: [String] = []
        for part in (csv ?? "").split(separator: ",") {
            let code = part.trimmingCharacters(in: .whitespaces).lowercased()
            if !code.isEmpty, !out.contains(code) { out.append(code) }
        }
        return out
    }
}
