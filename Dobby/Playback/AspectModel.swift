import Foundation

// E7 (#472) owns this file with AspectSheet.swift: the pure aspect model, ported from Android
// PlaybackActivity (applyAspectAdjust, cycleAspectAdjust, pickStretchStepForAspect,
// autoStretchCeiling, the stretch memory and its restore decision). No SwiftUI or KSPlayer
// import, so Tests/run-checks.sh compiles it standalone with Tests/AspectModelCheck.swift.
// Every knob is a whole percent, as Android's 1 % grid.

struct AspectModel: Equatable {
    /// Android ASPECT_LABELS: FIT / FILL / ZOOM resize modes.
    enum Mode: Int, CaseIterable {
        case original, stretch, crop
        var label: String { ["Original", "Stretch to screen", "Crop to screen"][rawValue] }
    }

    /// The arrow rows and Reset, Android cycleAspectAdjust's `which`.
    enum Knob { case mode, stretchV, stretchVFine, stretchH, zoom, zoomFine, offsetY, reset }

    static let minPercent = 80, maxPercent = 140, coarse = 5
    static let offsetRange = -20...20                 // Position Y, 5 % steps, wraps
    /// Auto stretch levels: 0 = Off, 5...20 = at most that much, 100 = Full (Android AUTO_STRETCH_LEVELS).
    static let autoLevels = [0, 5, 10, 15, 20, 100]
    static let autoFull = 100

    var mode = Mode.original
    var stretchV = 100      // "Stretch height", scaleY
    var stretchH = 100      // "Stretch width", scaleX
    var zoom = 100          // "Scale", both axes
    var offsetY = 0         // percent of the picture height

    /// Box-wide, saved by AspectSheet.swift. #408: Off until the owner picks a level.
    var autoLevel = 0

    // Session flags (Android userAdjustedStretchV, stretchVFromAuto, autoStretchVApplied, autoStretchNeed).
    var started = false
    var userAdjusted = false
    var stretchFromAuto = false
    var autoApplied = false
    var autoNeed = 0.0
    /// Decoded frame size (0 until the first load) and the per-title memory key ("" = none).
    var videoWidth = 0.0, videoHeight = 0.0
    var titleKey = ""

    var videoAspect: Double { videoWidth > 0 && videoHeight > 0 ? videoWidth / videoHeight : 0 }

    // MARK: Transform (Android applyAspectAdjust: scaleX = stretchH x zoom, scaleY = stretchV x zoom)

    /// Scale about the centre and the vertical offset in points, for a video view of w x h.
    /// "Stretch to screen" adds the factor that makes the fitted picture fill the view; "Crop"
    /// is KSPlayer's aspect fill, so it needs nothing here.
    func transform(width w: Double, height h: Double) -> (x: Double, y: Double, dy: Double) {
        var x = Double(stretchH * zoom) / 10_000, y = Double(stretchV * zoom) / 10_000
        let va = videoAspect, viewAspect = h > 0 ? w / h : 0
        if mode == .stretch, va > 0, viewAspect > 0 {
            if va > viewAspect { y *= va / viewAspect } else { x *= viewAspect / va }
        }
        // Android translates by the content frame's height: the picture's, not the window's.
        let frameH = va > 0 ? (mode == .original ? min(h, w / va) : mode == .crop ? max(h, w / va) : h) : h
        return (x, y, Double(offsetY) / 100 * frameH)
    }

    /// Android aspectModeHasNoEffect: within 1 % of the view every Mode looks the same.
    func modeHasNoEffect(viewAspect: Double) -> Bool {
        let va = videoAspect
        guard va > 0, viewAspect > 0 else { return false }
        return abs(va / viewAspect - 1) <= 0.01
    }

    // MARK: Knobs

    /// Android stepAspectStretchIndex: one step, snapped onto the step's grid, wrapping at the ends.
    static func step(_ percent: Int, _ dir: Int, by step: Int) -> Int {
        let floorDiv = Int((Double(percent) / Double(step)).rounded(.down))
        let ceilDiv = Int((Double(percent) / Double(step)).rounded(.up))
        var next = dir > 0 ? (floorDiv + 1) * step : (ceilDiv - 1) * step
        if next > maxPercent { next = minPercent }
        if next < minPercent { next = maxPercent }
        return next
    }

    /// One arrow-row step or Reset. Returns the knob a manual memory row is written for
    /// ("stretchV" / "zoom"), nil when nothing is remembered (Android rememberAspectAdjust calls).
    @discardableResult
    mutating func adjust(_ knob: Knob, _ dir: Int) -> String? {
        let d = dir == 0 ? 1 : dir
        switch knob {
        case .mode:
            let n = Mode.allCases.count
            mode = Mode(rawValue: ((mode.rawValue + d) % n + n) % n)!
            return resetKnobs()                        // #273: a Mode pick starts over, Position Y kept
        case .stretchV, .stretchVFine:
            stretchV = Self.step(stretchV, d, by: knob == .stretchVFine ? 1 : Self.coarse)
            userAdjusted = true; stretchFromAuto = false
            return "stretchV"
        case .zoom, .zoomFine:
            zoom = Self.step(zoom, d, by: knob == .zoomFine ? 1 : Self.coarse)
            userAdjusted = true                        // a stacked auto stretch would pass the ceiling
            return "zoom"
        case .stretchH:
            stretchH = Self.step(stretchH, d, by: Self.coarse)
            return nil
        case .offsetY:
            var next = offsetY + 5 * d
            if next > Self.offsetRange.upperBound { next = Self.offsetRange.lowerBound }
            if next < Self.offsetRange.lowerBound { next = Self.offsetRange.upperBound }
            offsetY = next
            return nil
        case .reset:
            mode = .original; offsetY = 0
            return resetKnobs()
        }
    }

    /// Android resetStretchKnobsToDefault: the session stays at 100 % (the user asked for it).
    private mutating func resetKnobs() -> String {
        stretchH = 100; stretchV = 100; zoom = 100
        userAdjusted = true; stretchFromAuto = false
        return "stretchV"
    }

    static func levelLabel(_ level: Int) -> String {
        level == 0 ? "Off" : level == autoFull ? "Full" : "\(level)%"
    }

    /// A stored level, or Off when there is none or it is not a known level (#408).
    static func level(stored: Int?) -> Int {
        guard let stored, autoLevels.contains(stored) else { return 0 }
        return stored
    }

    // MARK: Auto stretch (metadata path; the #477 letterbox sampler feeds the same picker)

    /// Android autoStretchCeiling (#172, #275): never past the fill factor, the level or the grid.
    static func ceiling(needed: Double, level: Int) -> Double {
        min(needed, min(Double(100 + level) / 100, Double(maxPercent) / 100))
    }

    /// Android pickStretchStepForAspect: the largest 1 % stretch-height step at or below the ceiling,
    /// 100 inside the 2 % dead-band or below a 5 % fill.
    static func pickStretch(videoAspect: Double, screenAspect: Double, level: Int) -> Int {
        guard screenAspect > 0, videoAspect > screenAspect * 1.02 else { return 100 }
        let needed = videoAspect / screenAspect
        guard needed >= 1.05 else { return 100 }
        let allowed = ceiling(needed: needed, level: level)
        return (101...maxPercent).last { Double($0) / 100 <= allowed } ?? 100
    }

    /// Android maybeAutoStretchForAspect: once per playback, never over a manual knob or at Off.
    /// Returns the applied percent (the caller remembers an auto row and toasts), nil when nothing changed.
    mutating func autoStretch(videoAspect: Double, screenAspect: Double) -> Int? {
        guard !autoApplied, !userAdjusted, autoLevel != 0, screenAspect > 0 else { return nil }
        let p = Self.pickStretch(videoAspect: videoAspect, screenAspect: screenAspect, level: autoLevel)
        guard p != 100 else { return nil }
        stretchV = p; stretchFromAuto = true; autoApplied = true
        autoNeed = videoAspect / screenAspect
        return p
    }

    /// Android reapplyAutoStretchLevel after a level step. `.remember`: write an auto row;
    /// `.runStartPaths`: no fill measured yet, run the metadata pass (and the #477 sampler) now.
    enum LevelOutcome { case none, remember, runStartPaths }
    mutating func reapplyLevel() -> LevelOutcome {
        if userAdjusted { return .none }
        if autoLevel == 0 {
            if stretchFromAuto { stretchV = 100 }
            return .none
        }
        guard autoNeed > 0 else { return .runStartPaths }
        stretchV = Self.pickStretch(videoAspect: autoNeed, screenAspect: 1, level: autoLevel)
        stretchFromAuto = true; autoApplied = true
        return .remember
    }

    // MARK: Per-title memory restore

    /// Android restoreStretchMemoryIfNeeded + decideStretchMemoryRestoreIndex + restoreKnob.
    /// Returns the restored knob ("stretchV" / "zoom") and percent, nil when the row is ignored.
    mutating func restore(_ row: StretchMemory.Row) -> (knob: String, percent: Int)? {
        let p = row.p
        guard (Self.minPercent...Self.maxPercent).contains(p), row.m == "manual" || row.m == "auto" else { return nil }
        if row.m == "auto" && (autoLevel == 0 || row.cap != StretchMemory.capStamp(autoLevel)) { return nil }
        if row.m == "manual" && p == 100 { return nil }   // #180: no correction
        let knob = row.m == "manual" && row.k == "zoom" ? "zoom" : "stretchV"
        if knob == "zoom" { zoom = p } else { stretchV = p }
        if row.m == "manual" {
            userAdjusted = true
        } else {
            autoApplied = true; stretchFromAuto = true
            autoNeed = row.n ?? Double(p) / 100
        }
        return (knob, p)
    }
}

/// Per-title stretch memory (Android stretch_memory/map, #153/#179/#180): one row per title,
/// 10 titles, 30 days, oldest "t" evicted first.
struct StretchMemory: Codable, Equatable {
    struct Row: Codable, Equatable {
        var p: Int          // whole percent
        var k: String       // knob: "stretchV" or "zoom"
        var m: String       // "manual" or "auto"
        var cap: Int        // capStamp at save; an auto row restores only under the same one
        var n: Double?      // fill factor an auto row was picked from
        var t: Double       // saved at, seconds since 1970
    }

    static let maxEntries = 10
    static let ttl: Double = 30 * 24 * 60 * 60

    var rows: [String: Row] = [:]

    /// Android stretchMemoryCapStamp: Full keeps 10140, each capped level its own stamp.
    static func capStamp(_ level: Int) -> Int {
        level == AspectModel.autoFull ? 10_000 + AspectModel.maxPercent : 20_000 + level
    }

    /// Android stretchKeyFromVideo: YouTube videoId, else the title key, else the URL sans query/fragment.
    static func key(videoId: String?, titleKey: String?, url: String?) -> String {
        if let videoId, !videoId.isEmpty { return videoId }
        if let titleKey, !titleKey.isEmpty { return titleKey }
        guard let url else { return "" }
        return String(url.prefix { $0 != "?" && $0 != "#" })
    }

    /// Android stretchTitleKey: the PWA's resume key minus "bp_vpos_".
    static func titleKey(imdbId: String?, type: String?, season: String?, episode: String?) -> String? {
        guard let imdbId, !imdbId.isEmpty, let type, !type.isEmpty else { return nil }
        if type != "series" { return "\(imdbId)_\(type)" }
        guard let season, let episode else { return nil }
        return "\(imdbId)_\(type)_s\(season)e\(episode)"
    }

    /// Android loadStretchMemory: drop rows past the TTL.
    mutating func prune(now: Double) { rows = rows.filter { now - $0.value.t <= Self.ttl } }

    /// Android rememberAspectAdjust + saveStretchMemory. A manual choice leaving stretch height and
    /// scale both at 100 % removes the row (#180), so the auto fill runs again next time.
    mutating func remember(key: String, aspect a: AspectModel, knob: String, source: String, now: Double) {
        guard !key.isEmpty else { return }
        prune(now: now)
        if source == "manual" && a.stretchV == 100 && a.zoom == 100 {
            rows[key] = nil
        } else {
            rows[key] = Row(p: knob == "zoom" ? a.zoom : a.stretchV, k: knob, m: source,
                            cap: Self.capStamp(a.autoLevel),
                            n: source == "auto" && a.autoNeed > 0 ? a.autoNeed : nil, t: now)
        }
        while rows.count > Self.maxEntries, let oldest = rows.min(by: { $0.value.t < $1.value.t })?.key {
            rows[oldest] = nil
        }
    }
}
