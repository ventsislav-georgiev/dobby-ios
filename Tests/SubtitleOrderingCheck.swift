import Foundation

// #466: the SubtitleOrdering.swift stub's check. E3 (#468) extends it with the Android order.
@main
enum SubtitleOrderingCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        check(SubtitleOrdering.preferredLanguages("bg, EN,,bg") == ["bg", "en"],
              "the payload's comma list becomes lowercased codes in order, blanks and repeats dropped")
        check(SubtitleOrdering.preferredLanguages(nil).isEmpty, "no list is no preferred language")
        print("SubtitleOrderingCheck: all checks passed")
    }
}
