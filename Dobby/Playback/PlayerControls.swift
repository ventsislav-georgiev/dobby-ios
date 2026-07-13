import SwiftUI
import KSPlayer
#if os(macOS)
import AppKit
#endif

/// Subtitle render style, mirrors the web app's default/large/contrast options.
enum SubtitleStyle: String, CaseIterable, Identifiable {
    case standard, large, contrast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Default"
        case .large: return "Large"
        case .contrast: return "High Contrast"
        }
    }
}

/// One row in an OSD side menu. `action` performs the selection.
struct OSDItem: Identifiable {
    let id: String
    let label: String
    let detail: String?
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    init(id: String, label: String, detail: String? = nil, selected: Bool, enabled: Bool = true, action: @escaping () -> Void) {
        self.id = id; self.label = label; self.detail = detail
        self.selected = selected; self.enabled = enabled; self.action = action
    }
}

/// OSD visibility + menu state + the bridge to KSPlayer for each control.
/// Lives for the duration of one player overlay (a @StateObject in PlayerView).
@MainActor
final class PlayerControls: ObservableObject {
    enum Menu: String, Identifiable, CaseIterable {
        case subtitles, audio, quality, speed, aspect
        var id: String { rawValue }
        var title: String {
            switch self {
            case .subtitles: return "Subtitles"
            case .audio: return "Audio"
            case .quality: return "Quality"
            case .speed: return "Speed"
            case .aspect: return "Aspect"
            }
        }
        var icon: String {
            switch self {
            case .subtitles: return "captions.bubble"
            case .audio: return "waveform"
            case .quality: return "slider.horizontal.3"
            case .speed: return "speedometer"
            case .aspect: return "aspectratio"
            }
        }
    }

    weak var playback: PlaybackCoordinator?

    @Published var visible = true
    @Published var menu: Menu?
    @Published var focusIndex = 0
    @Published var toast: String?
    @Published var subtitleStyle: SubtitleStyle = .standard {
        didSet { UserDefaults.standard.set(subtitleStyle.rawValue, forKey: Self.styleKey) }
    }

    // Loading / playback state surfaced for the spinner + auto-hide.
    @Published var buffering = false
    @Published var loaded = false
    @Published var showInfo = false

    // Aspect: Fit/Fill via KSPlayer gravity; Zoom/Stretch via a SwiftUI scaleEffect.
    @Published var isFill = false
    @Published var zoom: Double = 1.0
    @Published var stretch: Double = 1.0

    @Published var subtitleScale: Double = UserDefaults.standard.object(forKey: "dobby.subScale") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(subtitleScale, forKey: "dobby.subScale") }
    }
    @Published var subtitlePosition: Double = UserDefaults.standard.object(forKey: "dobby.subPos") as? Double ?? 40 {
        didSet { UserDefaults.standard.set(subtitlePosition, forKey: "dobby.subPos") }
    }
    @Published var subtitleDelay: Double = 0 {
        didSet { playback?.player.subtitleModel.subtitleDelay = subtitleDelay }
    }

    private static let styleKey = "dobby.subtitleStyle"
    private var hideTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    #if os(macOS)
    weak var window: NSWindow?
    var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }
    #endif

    init() {
        if let s = UserDefaults.standard.string(forKey: Self.styleKey),
           let v = SubtitleStyle(rawValue: s) { subtitleStyle = v }
    }

    #if os(macOS)
    func attachWindow(_ w: NSWindow) {
        window = w
        w.isRestorable = false   // don't let macOS restore a fullscreen Space on relaunch
        w.resizeIncrements = NSSize(width: 1, height: 1)   // drop KSPlayer's aspect lock so the window stays freely zoomable
        w.collectionBehavior.insert(.fullScreenPrimary)    // allow native fullscreen
    }
    #endif

    var isPlaying: Bool { playback?.player.playerLayer?.state.isPlaying ?? false }

    // MARK: Player state → spinner + auto-hide

    /// Driven from KSPlayer's onStateChanged. `.buffering`/`.preparing` mean loading
    /// (spinner); first `.readyToPlay`/`.bufferFinished` marks the new video loaded and
    /// applies the chosen aspect; any playing state (re)arms the idle auto-hide — the
    /// readyToPlay→bufferFinished gap is why the OSD used to get stuck visible.
    func syncState(_ s: KSPlayerState) {
        buffering = (s == .buffering || s == .preparing || s == .initialized)
        if s == .readyToPlay || s == .bufferFinished, !loaded { loaded = true; applyAspect() }
        if s.isPlaying { scheduleHide() }
    }

    // MARK: Visibility

    /// Reveal the OSD; auto-hide after idle only while playing (paused = sticky).
    func wake() {
        visible = true
        scheduleHide()
    }

    func scheduleHide() {
        hideTask?.cancel()
        guard menu == nil, !showInfo, isPlaying else { return }   // keep visible if a menu/info is open or paused
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.visible = false
        }
    }

    func forceShow() { hideTask?.cancel(); visible = true }

    /// Dismiss the OSD (and any open menu) immediately — first tap on the video.
    func hide() { hideTask?.cancel(); menu = nil; visible = false }

    // MARK: Toast (web showVideoOsd equivalent)

    func flash(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Transport

    func togglePlay() {
        playback?.togglePlayPause()
        forceShow()
        // After resuming, restart the idle hide.
        if isPlaying { scheduleHide() }
    }

    func seekBy(_ delta: TimeInterval) {
        guard let p = playback else { return }
        let cur = TimeInterval(p.player.timemodel.currentTime)
        let total = TimeInterval(p.player.timemodel.totalTime)
        let t = min(max(0, cur + delta), max(0, total))
        p.seek(to: t)
        flash(delta >= 0 ? "⏩ +\(Int(delta))s" : "⏪ \(Int(delta))s")
        wake()
    }

    func jump(fraction: Double) {
        guard let p = playback else { return }
        let total = TimeInterval(p.player.timemodel.totalTime)
        seekBy(total * fraction)
    }

    // MARK: Aspect / Info

    func applyAspect() { playback?.player.isScaleAspectFill = isFill }

    func setAspect(fill: Bool, zoom z: Double, stretch s: Double) {
        isFill = fill; zoom = z; stretch = s
        applyAspect()
        forceShow()
    }

    func toggleInfo() {
        showInfo.toggle()
        if showInfo { forceShow() } else { scheduleHide() }
    }

    // MARK: Menus

    func toggleMenu(_ m: Menu) {
        if menu == m { menu = nil } else { menu = m; focusIndex = selectedIndex(in: m) }
        forceShow()
    }

    func closeMenu() { menu = nil; scheduleHide() }

    /// Rows for the active menu, computed live from KSPlayer state.
    func items(for m: Menu) -> [OSDItem] {
        guard let p = playback else { return [] }
        switch m {
        case .subtitles:
            var rows: [OSDItem] = [OSDItem(
                id: "off",
                label: "Off",
                selected: p.player.subtitleModel.selectedSubtitleInfo == nil,
                action: { [weak self] in
                    p.player.subtitleModel.selectedSubtitleInfo = nil
                    self?.flash("Subtitles off")
                })]
            for info in p.player.subtitleModel.subtitleInfos {
                let sel = p.player.subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID
                // Sideloaded subs (URLSubtitleInfo) carry a source-prefixed label from
                // the web layer (Stremio -, Addic7ed -); mark in-container tracks so
                // the two are distinguishable in the list.
                let name = info is URLSubtitleInfo ? info.name : "Embedded - \(info.name)"
                rows.append(OSDItem(id: info.subtitleID, label: name, selected: sel, action: { [weak self] in
                    p.player.subtitleModel.selectedSubtitleInfo = info
                    self?.flash("Subtitles: \(name)")
                }))
            }
            // Style sub-section appended as toggle rows.
            for style in SubtitleStyle.allCases {
                rows.append(OSDItem(id: "style-\(style.rawValue)", label: "Style: \(style.label)",
                                    selected: subtitleStyle == style, action: { [weak self] in
                    self?.subtitleStyle = style
                    self?.flash("Subtitle style: \(style.label)")
                }))
            }
            // Size.
            for (label, scale) in [("Small", 0.75), ("Normal", 1.0), ("Large", 1.4), ("Huge", 1.8)] {
                rows.append(OSDItem(id: "size-\(scale)", label: "Size: \(label)",
                                    selected: abs(subtitleScale - scale) < 0.01, action: { [weak self] in
                    self?.subtitleScale = scale; self?.flash("Subtitle size: \(label)") }))
            }
            // Vertical position (extra points above the bottom).
            for (label, off) in [("Lower", 0.0), ("Default", 40.0), ("Higher", 120.0), ("Top", 280.0)] {
                rows.append(OSDItem(id: "pos-\(off)", label: "Position: \(label)",
                                    selected: abs(subtitlePosition - off) < 0.5, action: { [weak self] in
                    self?.subtitlePosition = off; self?.flash("Subtitle position: \(label)") }))
            }
            // Delay alignment.
            for d in [-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0] {
                let lbl = d == 0 ? "Delay: 0s" : String(format: "Delay: %+.1fs", d)
                rows.append(OSDItem(id: "delay-\(d)", label: lbl,
                                    selected: abs(subtitleDelay - d) < 0.01, action: { [weak self] in
                    self?.subtitleDelay = d; self?.flash(lbl) }))
            }
            return rows
        case .audio:
            let tracks = p.player.playerLayer?.player.tracks(mediaType: .audio) ?? []
            if tracks.isEmpty { return [OSDItem(id: "none", label: "No audio tracks", selected: false, enabled: false, action: {})] }
            return tracks.enumerated().map { idx, t in
                OSDItem(id: "a\(idx)", label: t.name, detail: t.languageCode, selected: t.isEnabled, action: { [weak self] in
                    p.player.playerLayer?.player.select(track: t)
                    self?.flash("Audio: \(t.name)")
                })
            }
        case .quality:
            let options = p.qualityOptions
            guard !options.isEmpty else {
                // HLS lane: AVPlayer's ABR picks renditions itself.
                return [OSDItem(id: "auto", label: "Auto (adaptive)", selected: true, enabled: false, action: {})]
            }
            return options.enumerated().map { idx, opt in
                let label = opt.label ?? opt.height.map { "\($0)p" } ?? "Option \(idx + 1)"
                return OSDItem(
                    id: "q\(idx)",
                    label: label,
                    selected: opt.videoUrl != nil && opt.videoUrl == p.currentVideoUrl,
                    action: { [weak self] in
                        p.selectQuality(opt)
                        self?.flash("Quality: \(label)")
                    })
            }
        case .speed:
            return speeds.map { s in
                OSDItem(id: "s\(s)", label: s == 1.0 ? "Normal" : "\(trimRate(s))×",
                        selected: abs(p.player.playbackRate - s) < 0.01, action: { [weak self] in
                    p.player.playbackRate = s
                    self?.flash("Speed: \(s == 1.0 ? "Normal" : "\(self?.trimRate(s) ?? "")×")")
                })
            }
        case .aspect:
            let plain = !isFill && zoom == 1 && stretch == 1
            var rows: [OSDItem] = [
                OSDItem(id: "fit", label: "Fit", selected: plain, action: { [weak self] in
                    self?.setAspect(fill: false, zoom: 1, stretch: 1); self?.flash("Aspect: Fit") }),
                OSDItem(id: "fill", label: "Fill (crop)", selected: isFill, action: { [weak self] in
                    self?.setAspect(fill: true, zoom: 1, stretch: 1); self?.flash("Aspect: Fill") }),
            ]
            for pct in [5, 10, 15, 20] {
                let z = 1 + Double(pct) / 100
                rows.append(OSDItem(id: "zoom\(pct)", label: "Zoom +\(pct)%",
                                    selected: !isFill && abs(zoom - z) < 0.001 && stretch == 1, action: { [weak self] in
                    self?.setAspect(fill: false, zoom: z, stretch: 1); self?.flash("Zoom +\(pct)%") }))
            }
            for pct in [5, 10, 15, 20] {
                let s = 1 + Double(pct) / 100
                rows.append(OSDItem(id: "stretch\(pct)", label: "Stretch +\(pct)%",
                                    selected: !isFill && abs(stretch - s) < 0.001 && zoom == 1, action: { [weak self] in
                    self?.setAspect(fill: false, zoom: 1, stretch: s); self?.flash("Stretch +\(pct)%") }))
            }
            return rows
        }
    }

    private func selectedIndex(in m: Menu) -> Int {
        items(for: m).firstIndex { $0.selected } ?? 0
    }

    private func trimRate(_ s: Float) -> String {
        let str = String(format: "%.2f", s)
        return str.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    // MARK: Keyboard nav within the active menu

    func navUp() { guard let m = menu else { return }; let n = items(for: m).count; focusIndex = (focusIndex - 1 + n) % max(1, n) }
    func navDown() { guard let m = menu else { return }; let n = items(for: m).count; focusIndex = (focusIndex + 1) % max(1, n) }
    func activateFocused() {
        guard let m = menu else { return }
        let rows = items(for: m)
        guard rows.indices.contains(focusIndex), rows[focusIndex].enabled else { return }
        rows[focusIndex].action()
    }

    // MARK: Fullscreen

    /// AppKit native fullscreen (own Space, hidden menu bar / Notification Center).
    /// The earlier native-fullscreen crash (empty-region BRK in
    /// `_adjustNeedsDisplayRegionForNewFrame`) was caused by the degenerate
    /// `aspectRatio = (0,0)` lock we used to "clear" KSPlayer's 16:9 — now cleared
    /// correctly via `resizeIncrements` at attach, so native is safe again.
    func toggleFullscreen() {
        #if os(macOS)
        let w = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let w else { return }
        w.resizeIncrements = NSSize(width: 1, height: 1)   // belt: never enter the transition with an aspect lock
        let entering = !w.styleMask.contains(.fullScreen)
        w.toggleFullScreen(nil)
        playback?.markSelftest("fullscreen now=\(entering)")
        #endif
    }

    /// Leave fullscreen when the overlay tears down while still in it (close button,
    /// playback end, app quit) — else the web window is left in its own FS Space.
    func exitFullscreenIfNeeded() {
        #if os(macOS)
        if isFullscreen { window?.toggleFullScreen(nil) }
        #endif
    }
}
