import SwiftUI
import KSPlayer

// E7 (#472) owns this file with AspectModel.swift: the aspect sheet (Android addAspectRows),
// how the model reaches the picture, metadata auto stretch and per-title memory.

/// The box-local aspect settings (Android stretch_memory prefs): the Auto stretch level and the
/// per-title memory. Absent level = Off (#408).
enum AspectStore {
    static let levelKey = "dobby.autoStretchLevel"
    static let memoryKey = "dobby.stretchMemory"

    static var level: Int {
        get { AspectModel.level(stored: UserDefaults.standard.object(forKey: levelKey) as? Int) }
        set { UserDefaults.standard.set(newValue, forKey: levelKey) }
    }

    static func loadMemory() -> StretchMemory {
        var m = UserDefaults.standard.data(forKey: memoryKey)
            .flatMap { try? JSONDecoder().decode(StretchMemory.self, from: $0) } ?? StretchMemory()
        m.prune(now: Date().timeIntervalSince1970)
        return m
    }

    static func saveMemory(_ m: StretchMemory) {
        if let data = try? JSONEncoder().encode(m) { UserDefaults.standard.set(data, forKey: memoryKey) }
    }
}

extension PlayerControls {
    /// Called on first load (syncState) and after every change: starts the session once, then
    /// pushes the part KSPlayer owns (gravity: Crop is aspect fill). The transform is
    /// `aspectTransform`, which re-renders from `aspect` on its own.
    func applyAspect() {
        if !aspect.started { startAspectSession() }
        playback?.player.isScaleAspectFill = aspect.mode == .crop
    }

    /// The video view's aspect (window resizes and fullscreen change it); 0 when not laid out.
    var aspectViewAspect: Double {
        let s = playback?.player.playerLayer?.player.view?.bounds.size ?? .zero
        return s.width > 0 && s.height > 0 ? Double(s.width / s.height) : 0
    }

    /// First load: the level, the frame size and the title key, then the remembered row for this
    /// title, else the metadata auto stretch (Android startPlayback order).
    private func startAspectSession() {
        aspect.started = true
        aspect.autoLevel = AspectStore.level
        if let size = playback?.player.playerLayer?.player.naturalSize {
            aspect.videoWidth = Double(size.width); aspect.videoHeight = Double(size.height)
        }
        if let req = playback?.request {
            // A trailer (allowBookmarks false) carries its film's descriptor: keep it on the URL key.
            let title = req.allowBookmarks == true
                ? StretchMemory.titleKey(imdbId: req.video?.imdbId, type: req.video?.type,
                                         season: req.video?.season, episode: req.video?.episode)
                : nil
            aspect.titleKey = StretchMemory.key(videoId: req.videoId, titleKey: title, url: req.url ?? req.videoUrl)
        }
        if let row = AspectStore.loadMemory().rows[aspect.titleKey], let r = aspect.restore(row) {
            let what = r.knob == "zoom" ? "scale" : row.m == "manual" ? "stretch height" : "auto stretch"
            flash("Restored \(what): \(r.percent)%")
            return
        }
        autoStretchFromMetadata()
    }

    private func autoStretchFromMetadata() { autoStretch(videoAspect: aspect.videoAspect) }

    /// The auto-fill entry point. The metadata path passes the decoded frame's aspect; the #477
    /// letterbox sampler passes the bar-corrected picture aspect it measured. Portrait (an iPhone
    /// held upright) never stretches: its bars are the width fit, not a letterbox.
    func autoStretch(videoAspect: Double) {
        let screen = aspectViewAspect
        guard screen >= 1, let p = aspect.autoStretch(videoAspect: videoAspect, screenAspect: screen) else { return }
        rememberAspect(knob: "stretchV", source: "auto")
        applyAspect()
        flash("Auto stretch: \(p)% (fills \(String(format: "%.2f", videoAspect)):1)")
    }

    private func rememberAspect(knob: String, source: String) {
        var m = AspectStore.loadMemory()
        m.remember(key: aspect.titleKey, aspect: aspect, knob: knob, source: source,
                   now: Date().timeIntervalSince1970)
        AspectStore.saveMemory(m)
    }

    /// One arrow step or Reset (Android cycleAspectAdjust).
    func adjustAspect(_ knob: AspectModel.Knob, _ dir: Int) {
        if let memKnob = aspect.adjust(knob, dir) { rememberAspect(knob: memKnob, source: "manual") }
        applyAspect()
    }

    /// The Auto stretch row: Off, 5 %, 10 %, 15 %, 20 %, Full, wrapping; saved box-wide and
    /// applied to the video playing now (Android stepAutoStretchLevel + reapplyAutoStretchLevel).
    func stepAutoStretchLevel(_ dir: Int) {
        let levels = AspectModel.autoLevels, n = levels.count
        let i = levels.firstIndex(of: aspect.autoLevel) ?? 0
        aspect.autoLevel = levels[((i + dir) % n + n) % n]
        AspectStore.level = aspect.autoLevel
        flash("Auto stretch: \(AspectModel.levelLabel(aspect.autoLevel))")
        switch aspect.reapplyLevel() {
        case .remember: rememberAspect(knob: "stretchV", source: "auto")
        case .runStartPaths: autoStretchFromMetadata()      // #477: start the sampler here too
        case .none: break
        }
        applyAspect()
    }

    func aspectSheetContent() -> OSDSheetContent {
        let a = aspect
        let auto = a.stretchFromAuto ? " (auto)" : ""
        let y = a.offsetY > 0 ? "+\(a.offsetY)%" : "\(a.offsetY)%"
        func arrow(_ id: String, _ label: String, _ step: @escaping (Int) -> Void) -> OSDItem {
            // A click or tap on the row body steps forward (Android tablet: a tap steps); Return
            // closes the sheet keeping the value (aspectSheetHandleKey, Android okRunsRowAction).
            OSDItem(id: id, label: label, selected: false, adjust: step, action: { step(1) })
        }
        func knob(_ k: AspectModel.Knob) -> (Int) -> Void { { [weak self] d in self?.adjustAspect(k, d) } }
        var rows: [OSDItem] = []
        if a.modeHasNoEffect(viewAspect: aspectViewAspect) {
            rows.append(OSDItem(id: "mode", label: "Mode: not supported for this video", selected: false,
                                enabled: false, action: {}))
        } else {
            rows.append(arrow("mode", "Mode: \(a.mode.label)", knob(.mode)))
        }
        rows += [
            arrow("stretchV", "Stretch height: \(a.stretchV)%\(auto)", knob(.stretchV)),
            arrow("stretchVFine", "Stretch height fine: \(a.stretchV)%\(auto) (1%)", knob(.stretchVFine)),
            arrow("stretchH", "Stretch width: \(a.stretchH)%", knob(.stretchH)),
            arrow("zoom", "Scale: \(a.zoom)%", knob(.zoom)),
            arrow("zoomFine", "Scale fine: \(a.zoom)% (1%)", knob(.zoomFine)),
            arrow("offsetY", "Position Y: \(y)", knob(.offsetY)),
            arrow("autoLevel", "Auto stretch: \(AspectModel.levelLabel(a.autoLevel))",
                  { [weak self] d in self?.stepAutoStretchLevel(d) }),
            OSDItem(id: "reset", label: "Reset to default", selected: false,
                    action: { [weak self] in self?.adjustAspect(.reset, 1) }),
        ]
        return OSDSheetContent(title: "Aspect (◀/▶ to adjust)", rows: rows)
    }

    /// Return on an arrow row closes the sheet with the value shown (Android okRunsRowAction);
    /// everything else is the generic sheet keys.
    func aspectSheetHandleKey(_ key: OSDKey) -> Bool {
        guard key == .ret else { return false }
        let rows = aspectSheetContent().rows
        guard rows.indices.contains(focusIndex), rows[focusIndex].adjust != nil else { return false }
        closeSheet()
        return true
    }
}

extension View {
    /// The video-only transform PlayerView applies to the picture (never to subtitles or the
    /// OSD, #154): scale about the centre, then the Position Y offset.
    func aspectTransform(_ a: AspectModel) -> some View {
        GeometryReader { geo in
            let t = a.transform(width: Double(geo.size.width), height: Double(geo.size.height))
            self.scaleEffect(x: t.x, y: t.y).offset(y: t.dy)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
