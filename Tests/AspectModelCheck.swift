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

        // #477 letterbox detector (Android LetterboxDetector): a 128 x 216 luma frame, bars dark.
        func frame(top: Int, bottom: Int, picture: UInt8 = 200, rows: [Int: UInt8] = [:]) -> [UInt8] {
            let w = Letterbox.sampleW, h = Letterbox.sampleH
            var f = [UInt8](repeating: 0, count: w * h)
            for y in top..<(h - bottom) { for x in 0..<w { f[y * w + x] = rows[y] ?? picture } }
            for (y, v) in rows where y < top || y >= h - bottom { for x in 0..<w { f[y * w + x] = v } }
            return f
        }
        func bars(_ f: [UInt8]) -> (top: Int, bottom: Int)? {
            Letterbox.detectBars(f, width: Letterbox.sampleW, height: Letterbox.sampleH)
        }
        check(bars(frame(top: 28, bottom: 28))! == (28, 28), "clean 2.39 bars in a 16:9 frame are found")
        check(bars(frame(top: 0, bottom: 0))! == (0, 0), "a full frame has no bars")
        check(bars(frame(top: 28, bottom: 28, rows: [28: 40]))! == (29, 28), "a dirty boundary row belongs to the bar")
        check(bars(frame(top: 28, bottom: 28, rows: [28: 40, 29: 40, 30: 40])) == nil,
              "a picture fading into the bar is unreliable")
        check(bars(frame(top: 28, bottom: 28, picture: 50)) == nil, "a dark scene is unreliable")
        check(bars(frame(top: 28, bottom: 10)) == nil, "lopsided bars are rejected")
        check(bars(frame(top: 60, bottom: 60)) == nil, "bars covering half the frame are rejected")

        // #477 sampler fold: apply on the first sample with bars, then only ever correct down.
        var l = AspectModel(); l.autoLevel = 100; l.videoWidth = 1920; l.videoHeight = 1080
        check(l.startLetterbox(token: 7) && !l.startLetterbox(token: 8), "the sampler starts once per playback")
        guard case .applied(135, let fills) = l.foldLetterbox((28, 28), screenAspect: tv), abs(fills - 2.4) < 1e-9
        else { check(false, "the first sample with bars applies the fill"); return }
        check(l.stretchV == 135 && l.stretchFromAuto && l.autoApplied, "the applied fill is an auto stretch")
        check(l.foldLetterbox((20, 20), screenAspect: tv) == .corrected(122) && l.stretchV == 122,
              "smaller bars correct the fill down")
        check(l.foldLetterbox((28, 28), screenAspect: 1.6) == .none && l.stretchV == 122,
              "the fill never grows back, not even for a narrower window")
        _ = l.foldLetterbox(nil, screenAspect: tv); _ = l.foldLetterbox((28, 28), screenAspect: tv)
        check(!l.lbDone, "an unreliable frame does not count as accepted")
        check(l.foldLetterbox((28, 28), screenAspect: tv) == .none && l.lbDone, "five accepted samples end the sampler")
        l = AspectModel(); l.autoLevel = 100; l.videoWidth = 1920; l.videoHeight = 1080
        for _ in 0..<4 { _ = l.foldLetterbox((0, 0), screenAspect: tv) }
        check(l.foldLetterbox((0, 0), screenAspect: tv) == .noFill && l.autoNeed == 1 && l.stretchV == 100,
              "no bars: the sampler remembers no stretch needed")
        l = AspectModel(); l.autoLevel = 100
        for _ in 0..<19 { _ = l.foldLetterbox(nil, screenAspect: tv) }
        check(l.foldLetterbox(nil, screenAspect: tv) == .none && l.lbDone, "twenty rounds without a frame give up silently")
        l = AspectModel(); l.autoLevel = 100; _ = l.autoStretch(videoAspect: 2.39, screenAspect: tv)
        check(!l.startLetterbox(token: 1), "the metadata fill keeps the sampler off")
        l = AspectModel(); l.autoLevel = 0
        check(!l.startLetterbox(token: 1), "Off does not start the sampler")
        l.lbToken = 1; l.videoWidth = 1920; l.videoHeight = 1080
        check(l.foldLetterbox((28, 28), screenAspect: tv) == .none && l.stretchV == 100 && abs(l.autoNeed - 1.35) < 1e-9,
              "at Off the sampler measures but applies nothing (#275)")
        l.autoLevel = 10
        check(l.reapplyLevel() == .remember && l.stretchV == 110 && l.lbApplied == 110,
              "a level step re-picks from the measured bars")
        l = AspectModel(); l.autoLevel = 0; l.videoWidth = 1920; l.videoHeight = 1080
        _ = l.foldLetterbox((0, 0), screenAspect: tv); l.autoLevel = 100
        check(l.reapplyLevel() == .none && !l.autoApplied, "measured without bars, a level step applies nothing")

        // #563: phone and pad follow the view's orientation until a pick; the Mac keeps Original.
        var o = AspectModel(); o.videoWidth = 2400; o.videoHeight = 1000
        check(o.effectiveMode(portrait: true) == .original && o.effectiveMode(portrait: false) == .original,
              "the Mac default stays Original")
        check(AspectModel.isPortrait(9.0 / 16) && !AspectModel.isPortrait(1) && !AspectModel.isPortrait(0),
              "portrait is a laid-out view aspect under 1")
        o.orientationDefault = true
        check(o.effectiveMode(portrait: true) == .crop && o.effectiveMode(portrait: false) == .stretch,
              "phone and pad: portrait crops, landscape stretches")
        t = o.transform(width: 1600, height: 900)
        check(t.x == 1 && near(t.y, 2.4 / tv), "landscape renders Stretch to screen")
        t = o.transform(width: 900, height: 1600)
        check(t.x == 1 && t.y == 1, "a rotation to portrait drops the stretch (Crop is the gravity)")
        check(o.modeHasNoEffect(viewAspect: 2.41), "a picture matching the view still disables the Mode row")
        o.adjust(.mode, 1, portrait: false)
        check(o.mode == .crop && o.effectiveMode(portrait: false) == .crop && o.effectiveMode(portrait: true) == .crop,
              "a pick steps from the mode on screen and survives a rotation")
        o.adjust(.mode, 1, portrait: true)
        check(o.effectiveMode(portrait: true) == .original && o.effectiveMode(portrait: false) == .original,
              "a pick of Original holds in both orientations")
        o.adjust(.reset, 1)
        check(o.followsOrientation && o.effectiveMode(portrait: true) == .crop && o.effectiveMode(portrait: false) == .stretch,
              "Reset returns phone and pad to the orientation default")
        var mac = AspectModel(); mac.adjust(.mode, 1); mac.adjust(.reset, 1)
        check(mac.effectiveMode(portrait: false) == .original, "Reset on the Mac is Original")
        // No auto stretch on top of an orientation-default Stretch or Crop.
        var f = AspectModel(); f.orientationDefault = true; f.autoLevel = 100; f.videoWidth = 1920; f.videoHeight = 1080
        check(f.autoStretch(videoAspect: 2.39, screenAspect: tv) == nil && f.stretchV == 100, "no metadata auto stretch")
        check(!f.startLetterbox(token: 1), "no letterbox sampler")
        check(f.reapplyLevel() == .none && f.stretchV == 100, "a level step applies nothing")
        check(f.restore(StretchMemory.Row(p: 134, k: "stretchV", m: "auto", cap: StretchMemory.capStamp(100), n: 1.34, t: 0)) == nil
              && f.stretchV == 100, "a remembered auto row is not restored")
        check(f.restore(StretchMemory.Row(p: 115, k: "stretchV", m: "manual", cap: 0, n: nil, t: 0))! == ("stretchV", 115),
              "a remembered manual row still restores")

        print("AspectModelCheck: all checks passed")
    }
}
