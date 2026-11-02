import Foundation

// #466: the SubsDelayModel.swift stub's check. E6 (#471) replaces it with the ±100 ms steps
// and the fps-corrected delay(t).
@main
enum SubsDelayModelCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        var m = SubsDelayModel()
        m.step(1)
        check(m.delay == 0.5, "right from 0 steps to the next preset")
        m.delay = 2; m.step(1)
        check(m.delay == 2, "the last preset clamps")
        m.delay = 0.3; m.step(-1)
        check(m.delay == 0, "a delay the page set between presets steps to the nearest preset that way")
        print("SubsDelayModelCheck: all checks passed")
    }
}
