import Foundation

// #466: the AspectModel.swift stub's check. E7 (#472) extends it with the transform math and
// the per-title memory eviction.
@main
enum AspectModelCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let a = AspectModel(isFill: false, zoom: 1.1, stretch: 1.2)
        check(a.scaleX == 1.1, "zoom scales the width")
        check(abs(a.scaleY - 1.32) < 1e-9, "stretch scales the height on top of zoom")
        print("AspectModelCheck: all checks passed")
    }
}
