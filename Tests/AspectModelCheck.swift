import Foundation

// #472: the aspect model's pure logic: the transform math, the knob steps, the auto stretch
// pick, the level reapply, the per-title memory (eviction, TTL, #180 removal) and its restore.
@main
enum AspectModelCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    static func main() {
        // Defaults: nothing applied, Auto stretch Off (#408).
        var a = AspectModel()
        check(a.autoLevel == 0 && AspectModel.level(stored: nil) == 0 && AspectModel.level(stored: 7) == 0,
              "auto stretch is Off by default and for an unknown stored level")
        var t = a.transform(width: 1600, height: 900)
        check(t.x == 1 && t.y == 1 && t.dy == 0, "default transform is the identity")

        // scaleX = stretchH x zoom, scaleY = stretchV x zoom, dy = offset x picture height.
        a.stretchH = 110; a.stretchV = 120; a.zoom = 105; a.offsetY = 10
        a.videoWidth = 2400; a.videoHeight = 1000          // 2.40 picture fitted in 16:9: 666.67 tall
        t = a.transform(width: 1600, height: 900)
        check(near(t.x, 1.155) && near(t.y, 1.26), "stretch and zoom compose on each axis")
        check(near(t.dy, 0.1 * 1600 / 2.4), "position Y moves by the picture height, not the window's")
        a = AspectModel(); a.videoWidth = 2400; a.videoHeight = 1000; a.mode = .stretch
        t = a.transform(width: 1600, height: 900)
        check(t.x == 1 && near(t.y, 2.4 / (16.0 / 9)), "Stretch to screen fills the height of a wide picture")
        check(a.modeHasNoEffect(viewAspect: 2.41) && !a.modeHasNoEffect(viewAspect: 16.0 / 9),
              "the Mode row is disabled only within 1 % of the view")

        // Steps: coarse snaps onto the 5 % grid, both directions wrap.
        check(AspectModel.step(128, 1, by: 5) == 130 && AspectModel.step(128, -1, by: 5) == 125,
              "coarse step snaps an off-grid percent")
        check(AspectModel.step(140, 1, by: 5) == 80 && AspectModel.step(80, -1, by: 1) == 140, "steps wrap")
        a = AspectModel(); a.adjust(.offsetY, -1)
        check(a.offsetY == -5, "position Y steps 5 %")
        a.offsetY = 20; a.adjust(.offsetY, 1)
        check(a.offsetY == -20, "position Y wraps")
        a = AspectModel(); a.stretchV = 120; a.offsetY = 5
        check(a.adjust(.mode, 1) == "stretchV" && a.mode == .stretch && a.stretchV == 100 && a.offsetY == 5,
              "a Mode pick resets the stretch knobs and keeps Position Y")

        // Auto stretch pick (Android pickStretchStepForAspect).
        let tv = 16.0 / 9
        check(AspectModel.pickStretch(videoAspect: 2.39, screenAspect: tv, level: 100) == 134,
              "Full floors the fill factor onto the 1 % grid")
        check(AspectModel.pickStretch(videoAspect: 2.39, screenAspect: tv, level: 10) == 110, "a level caps the fill")
        check(AspectModel.pickStretch(videoAspect: 2.76, screenAspect: tv, level: 100) == 140, "the grid caps the fill")
        check(AspectModel.pickStretch(videoAspect: 1.8, screenAspect: tv, level: 100) == 100, "16:9 sits in the dead-band")
        a = AspectModel(); a.autoLevel = 0
        check(a.autoStretch(videoAspect: 2.39, screenAspect: tv) == nil && a.stretchV == 100, "Off never stretches")
        a.autoLevel = 100; a.userAdjusted = true
        check(a.autoStretch(videoAspect: 2.39, screenAspect: tv) == nil, "a manual knob blocks the auto fill")
        a.userAdjusted = false
        check(a.autoStretch(videoAspect: 2.39, screenAspect: tv) == 134 && a.stretchFromAuto, "auto fill applies")
        check(a.autoStretch(videoAspect: 2.39, screenAspect: tv) == nil, "auto fill runs once per playback")
        a.autoLevel = 5
        check(a.reapplyLevel() == .remember && a.stretchV == 105, "a level change re-picks from the fill factor")
        a.autoLevel = 0
        check(a.reapplyLevel() == .none && a.stretchV == 100, "Off puts an auto stretch back to 100 %")

        // Per-title memory: 10 titles, oldest first out, 30 days, manual 100/100 removes the row.
        var m = StretchMemory()
        var s = AspectModel(); s.stretchV = 115
        for i in 0..<11 { m.remember(key: "k\(i)", aspect: s, knob: "stretchV", source: "manual", now: 1000 + Double(i)) }
        check(m.rows.count == 10 && m.rows["k0"] == nil && m.rows["k10"] != nil, "eviction drops the oldest row")
        m.prune(now: 1001.5 + StretchMemory.ttl)
        check(m.rows.count == 9 && m.rows["k1"] == nil, "rows past 30 days drop")
        s.stretchV = 100
        m.remember(key: "k5", aspect: s, knob: "stretchV", source: "manual", now: 1020)
        check(m.rows["k5"] == nil, "a manual choice back at 100 % removes the row (#180)")
        check(StretchMemory.key(videoId: nil, titleKey: nil, url: "https://x.test/a.mkv?tok=1#t") == "https://x.test/a.mkv",
              "the URL key drops the query and fragment")
        check(StretchMemory.titleKey(imdbId: "tt1", type: "series", season: "1", episode: "2") == "tt1_series_s1e2"
              && StretchMemory.titleKey(imdbId: "tt1", type: "series", season: nil, episode: "2") == nil,
              "the title key matches Android's")

        // Restore: manual zoom comes back on zoom; an auto row needs the same level stamp.
        var r = AspectModel(); r.autoLevel = 100
        let zoomRow = StretchMemory.Row(p: 112, k: "zoom", m: "manual", cap: 0, n: nil, t: 0)
        check(r.restore(zoomRow)! == ("zoom", 112) && r.zoom == 112 && r.userAdjusted, "manual zoom restores on zoom")
        r = AspectModel(); r.autoLevel = 10
        let autoRow = StretchMemory.Row(p: 134, k: "zoom", m: "auto", cap: StretchMemory.capStamp(100), n: 1.34, t: 0)
        check(r.restore(autoRow) == nil && r.stretchV == 100, "an auto row from another level drops")
        r.autoLevel = 100
        check(r.restore(autoRow)! == ("stretchV", 134) && r.autoApplied, "an auto row restores on stretch height")
        r = AspectModel()
        check(r.restore(autoRow) == nil, "Off ignores an auto row")

        print("AspectModelCheck: all checks passed")
    }
}
