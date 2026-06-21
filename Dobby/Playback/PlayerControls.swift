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
        case subtitles, audio, speed, aspect
        var id: String { rawValue }
        var title: String {
            switch self {
            case .subtitles: return "Subtitles"
            case .audio: return "Audio"
            case .speed: return "Speed"
            case .aspect: return "Aspect"
            }
        }
        var icon: String {
            switch self {
            case .subtitles: return "captions.bubble"
            case .audio: return "waveform"
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

    private static let styleKey = "dobby.subtitleStyle"
    private var hideTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    #if os(macOS)
    weak var window: NSWindow?
    private var savedFrame: NSRect?
    private var savedLevel: NSWindow.Level = .normal
    var isFullscreen: Bool { savedFrame != nil }
    #endif

    init() {
        if let s = UserDefaults.standard.string(forKey: Self.styleKey),
           let v = SubtitleStyle(rawValue: s) { subtitleStyle = v }
    }

    #if os(macOS)
    func attachWindow(_ w: NSWindow) {
        window = w
        w.isRestorable = false   // don't let macOS restore a (legacy native) fullscreen Space
        w.resizeIncrements = NSSize(width: 1, height: 1)   // drop KSPlayer's aspect lock so the window stays freely zoomable
    }
    #endif

    var isPlaying: Bool { playback?.player.playerLayer?.state.isPlaying ?? true }

    // MARK: Visibility

    /// Reveal the OSD; auto-hide after idle only while playing (paused = sticky).
    func wake() {
        visible = true
        scheduleHide()
    }

    func scheduleHide() {
        hideTask?.cancel()
        guard menu == nil, isPlaying else { return }   // keep visible if a menu is open or paused
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
                rows.append(OSDItem(id: info.subtitleID, label: info.name, selected: sel, action: { [weak self] in
                    p.player.subtitleModel.selectedSubtitleInfo = info
                    self?.flash("Subtitles: \(info.name)")
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
        case .speed:
            return speeds.map { s in
                OSDItem(id: "s\(s)", label: s == 1.0 ? "Normal" : "\(trimRate(s))×",
                        selected: abs(p.player.playbackRate - s) < 0.01, action: { [weak self] in
                    p.player.playbackRate = s
                    self?.flash("Speed: \(s == 1.0 ? "Normal" : "\(self?.trimRate(s) ?? "")×")")
                })
            }
        case .aspect:
            return [
                OSDItem(id: "fit", label: "Fit", selected: !p.player.isScaleAspectFill, action: { [weak self] in
                    p.player.isScaleAspectFill = false; self?.flash("Aspect: Fit") }),
                OSDItem(id: "fill", label: "Fill", selected: p.player.isScaleAspectFill, action: { [weak self] in
                    p.player.isScaleAspectFill = true; self?.flash("Aspect: Fill") }),
            ]
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

    /// Manual frame-to-screen fullscreen — NOT AppKit's native `toggleFullScreen`.
    /// macOS 26 crashes the SwiftUI window hosting KSPlayer's Metal view + WKWebView
    /// with an empty-region BRK in `-[NSWindow _adjustNeedsDisplayRegionForNewFrame:]`
    /// on ANY resize of the *visible* window (native toggleFullScreen, animated
    /// setFrame, and plain deferred setFrame all crash the same way). AppKit only
    /// computes that display region for an on-screen window, so we order the window
    /// OUT, resize it while it has no display region to diff, then order it back IN.
    func toggleFullscreen() {
        #if os(macOS)
        let w = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let w, let screen = w.screen ?? NSScreen.main else { return }
        let entering = savedFrame == nil
        let target: NSRect
        if let frame = savedFrame {                       // exit
            w.level = savedLevel
            savedFrame = nil
            target = frame
        } else {                                          // enter
            savedFrame = w.frame
            savedLevel = w.level
            // Clear KSPlayer's 16:9 lock so the window can fill a non-16:9 screen.
            // Setting aspectRatio = (0,0) is degenerate (feeds an empty region into
            // `_adjustNeedsDisplayRegionForNewFrame` → BRK); resizeIncrements clears
            // the aspect constraint instead (the two are mutually exclusive).
            w.resizeIncrements = NSSize(width: 1, height: 1)
            w.level = .mainMenu + 1                        // cover menu bar by level, not presentationOptions
            target = screen.frame
        }
        // Defer the resize past the current event so it doesn't run reentrantly while
        // AppKit is still processing the click that triggered it.
        DispatchQueue.main.async { w.setFrame(target, display: false) }
        playback?.markSelftest("fullscreen now=\(entering)")
        #endif
    }

    /// Restore the window when the overlay tears down while fullscreen (close button,
    /// playback end, app quit) — else the web view is left screen-sized and elevated.
    func exitFullscreenIfNeeded() {
        #if os(macOS)
        if isFullscreen { toggleFullscreen() }
        #endif
    }
}
