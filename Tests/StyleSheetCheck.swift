import Foundation

// #470: the subtitle style (Dobby/Playback/StyleSheet.swift): the steps, the wrap, the load
// that migrates the pre-#470 keys and never invents values, the sheet rows, and where an
// image (PGS) cue lands. The stand-ins below mirror the OSD types the sheet extension uses.
enum OSDKey { case left, right }
struct OSDItem {
    let id: String, label: String, selected: Bool
    let adjust: ((Int) -> Void)?, action: () -> Void
    init(id: String, label: String, detail: String? = nil, selected: Bool, enabled: Bool = true,
         adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) {
        self.id = id; self.label = label; self.selected = selected; self.adjust = adjust; self.action = action
    }
}
struct OSDSheetContent { var title: String; var rows: [OSDItem] }
final class PlayerControls {
    var subStyle = SubtitleStyleSettings()
    var closed = false
    func closeSheet() { closed = true }
}

@main
enum StyleSheetCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func load(_ d: [String: Any]) -> SubtitleStyleSettings { SubtitleStyleSettings.load { d[$0] } }

    static func main() {
        typealias S = SubtitleStyleSettings
        check(S.sizeFractions.count == 14 && S.sizeLabels.count == 14, "14 size steps (Android SUB_SIZE_FRACTIONS)")
        check(S.positionFractions.count == 20 && S.positionLabels.count == 20, "20 position steps")
        check(S.positionLabels[1] == "+5%" && S.positionLabels[18] == "+90%" && S.positionLabels[19] == "Top",
              "position labels Bottom, +5% ... +90%, Top")

        // Nothing saved: Android's defaults, 5 % / +5 % / Solid.
        let d = load([:])
        check(d == S() && d.sizeFraction == 0.05 && d.positionFraction == 0.05 && d.backgroundOpacity == 1,
              "fresh install reads the Android defaults")

        // Saved new keys win over the old ones and are clamped.
        let saved = load(["dobby.subtitleSizeIndex": 7, "dobby.subtitlePositionIndex": 99,
                          "dobby.subtitleBgIndex": 0, "dobby.subScale": 1.8, "dobby.subtitleStyle": "contrast"])
        check(saved.sizeIndex == 7 && saved.positionIndex == 19 && saved.backgroundIndex == 0,
              "saved indices win over the old keys and clamp into range")

        // Migration from the pre-#470 keys, per key.
        check(load(["dobby.subScale": 1.0]).sizeIndex == 2, "old Normal size migrates to 5 %")
        check(load(["dobby.subScale": 1.8]).sizeIndex == 10, "old Huge size migrates to 9 %")
        check(load(["dobby.subtitleStyle": "large"]).sizeIndex == 7, "old Large style migrates to 7.5 %")
        check(load(["dobby.subPos": 0.0]).positionIndex == 0, "old Lower position migrates to Bottom")
        check(load(["dobby.subPos": 120.0]).positionIndex == 3, "old Higher position migrates to +15 %")
        check(load(["dobby.subtitleStyle": "contrast"]).backgroundIndex == 1, "old High Contrast migrates to Translucent")
        check(load(["dobby.subtitleStyle": "standard"]).backgroundIndex == 0, "old Default style migrates to no background")
        check(load(["dobby.subPos": 120.0]).backgroundIndex == 2, "an old key never moves another dimension")

        // Save round trip.
        var written: [String: Any] = [:]
        saved.save { written[$1] = $0 }
        check(load(written) == saved, "save then load returns the same look")

        // Wrap both ways.
        var s = S()
        s.cycle(.size, -1); s.cycle(.size, -1); s.cycle(.size, -1)
        check(s.sizeIndex == 13, "size wraps from 4 % back to 12 %")
        s.cycle(.size, 1)
        check(s.sizeIndex == 0, "size wraps from 12 % to 4 %")
        s.cycle(.background, 1)
        check(s.backgroundIndex == 0, "background wraps from Solid to None")

        // The sheet: arrow rows step, Return closes keeping the value, Reset restores defaults.
        let c = PlayerControls()
        let rows = c.styleSheetContent().rows
        check(rows.map(\.id) == ["size", "position", "background", "reset"], "rows: size, position, background, reset")
        check(rows[0].label == "Font size: 5%" && rows[2].label == "Background: Solid", "rows show the current values")
        rows[1].adjust?(1)
        check(c.subStyle.positionIndex == 2 && !c.closed, "right on Position steps it and keeps the sheet open")
        rows[1].action()
        check(c.closed && c.subStyle.positionIndex == 2, "Return on an arrow row closes the sheet keeping the value")
        c.closed = false
        check(rows[3].adjust == nil, "Reset is a plain row")
        rows[3].action()
        check(c.subStyle == S() && !c.closed, "Reset restores the defaults and stays open")

        // Image cues: a 1080p PGS cue on a 2:1 window lands on the fitted 16:9 picture.
        let r = S.imageRect(origin: CGPoint(x: 480, y: 900), imageSize: CGSize(width: 960, height: 100),
                            canvas: CGSize(width: 1920, height: 1080), view: CGSize(width: 1080, height: 540))
        check(r == CGRect(x: 60 + 240, y: 450, width: 480, height: 50), "PGS cue maps through the fitted picture")
        let u = S.imageRect(origin: .zero, imageSize: CGSize(width: 2000, height: 100),
                            canvas: .zero, view: CGSize(width: 1000, height: 500))
        check(u == CGRect(x: 0, y: 450, width: 1000, height: 50), "unknown canvas: bottom-centred, shrunk to fit")
        print("StyleSheetCheck: all checks passed")
    }
}
