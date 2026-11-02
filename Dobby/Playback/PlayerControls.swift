import SwiftUI
import KSPlayer
#if os(macOS)
import AppKit
#endif

// The OSD contract (which file each entry owns, the key router, layers, toast, focus) is
// OSD-CONTRACT.md (repo root). This file is the state and the router; components live in
// their own files as `extension PlayerControls` / `extension PlayerView`.

/// A key as the OSD router sees it, decoupled from NSEvent. Letters and punctuation are the
/// US-layout key at that position (PlayerView maps key codes), so a Cyrillic layout still
/// reaches "s" for subtitles. Command/Control chords never arrive here.
enum OSDKey: Equatable {
    case left, right, up, down, ret, escape, space
    case char(Character)
}

/// OSD visibility, the layer stack, the key router and the state each component keeps.
/// Lives for the duration of one player overlay (a @StateObject in PlayerView).
@MainActor
final class PlayerControls: ObservableObject {
    /// The centred track sheets. Each case's rows and keys come from its component file
    /// (`sheetContent(_:)` / `sheetHandleKey(_:_:)` below dispatch to them).
    enum Sheet: String, Identifiable, CaseIterable {
        case subtitles, audio, quality, speed, aspect, style
        var id: String { rawValue }
    }

    weak var playback: PlaybackCoordinator?

    // MARK: Layers, in key priority (Android dispatchKey): delay pill > sheet > shortcuts > more > bar

    @Published var subsDelayOpen = false { didSet { layersChanged() } }
    @Published var sheet: Sheet? { didSet { layersChanged() } }
    @Published var shortcutsOpen = false { didSet { layersChanged() } }
    @Published var moreOpen = false { didSet { layersChanged() } }
    /// The control bar.
    @Published var visible = true { didSet { layersChanged() } }

    /// Keyboard focus in the open sheet; hover moves the same index (OSDSheetView.onFocus).
    @Published var focusIndex = 0
    @Published var toast: String?

    // Loading / playback state surfaced for the loaders and the auto-hide.
    @Published var buffering = false
    @Published var loaded = false
    @Published var showInfo = false

    // MARK: Component state, one struct per owning file (add fields there, not here)

    @Published var bar = ControlBarState()                   // ControlBar.swift (E2)
    @Published var transport = TransportState()              // PlayerControls+Transport.swift (E2)
    @Published var subtitleSheet = SubtitleSheetState()      // SubtitleSheet.swift (E3)
    @Published var subStyle = SubtitleStyleSettings.load() { // StyleSheet.swift (E5)
        didSet { subStyle.save() }
    }
    @Published var subsDelay = SubsDelayModel() {            // SubsDelayModel.swift (E6)
        didSet { applySubsDelay() }                          // SubsDelayPill.swift
    }
    @Published var aspect = AspectModel()                    // AspectModel.swift (E7)
    @Published var more = MoreMenuState()                    // MoreMenu.swift (E9)

    /// Every route the OSD reads its colours from: the payload's skin.
    var tint: OsdTint { .forSkin(playback?.request?.skin) }

    // #129: true while the Slider is tracking a drag; blocks auto-hide re-arm mid-scrub.
    var scrubbing = false
    private var hideTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var returnHoldTask: Task<Void, Never>?
    private var lastState: KSPlayerState?

    #if os(macOS)
    weak var window: NSWindow?
    #endif
    var isFullscreen: Bool {
        #if os(macOS)
        window?.styleMask.contains(.fullScreen) ?? false
        #else
        false
        #endif
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

    // MARK: Player state → loaders + auto-hide

    /// Driven from KSPlayer's onStateChanged. `.buffering`/`.preparing` mean loading;
    /// first `.readyToPlay`/`.bufferFinished` marks the new video loaded and applies the
    /// aspect. Android updatePlayPauseUi (:3529-3546): pausing never summons the bar but
    /// stops its auto-hide; resuming hides a bar that was up at once (the 5 s timeout is
    /// for bars summoned while playing). A rebuffer never moves `.paused` to playing, so
    /// only a real resume counts.
    func syncState(_ s: KSPlayerState) {
        buffering = (s == .buffering || s == .preparing || s == .initialized)
        if s == .readyToPlay || s == .bufferFinished, !loaded { loaded = true; applyAspect() }
        if s == .paused { hideTask?.cancel() }
        if s.isPlaying, lastState == .paused, visible, !anyLayerOpen, !scrubbing {
            hideTask?.cancel(); visible = false
        } else if s.isPlaying {
            scheduleHide()
        }
        lastState = s
    }

    /// Called from KSPlayer's onPlay (about 10 Hz) with the playback position.
    func playbackTick(current: TimeInterval) { subsDelayTick(current: current) }

    // MARK: Visibility

    var anyLayerOpen: Bool { subsDelayOpen || sheet != nil || shortcutsOpen || moreOpen }

    /// Reveal the bar; auto-hide after idle only while playing (paused = sticky).
    func wake() {
        visible = true
        scheduleHide()
    }

    func scheduleHide() {
        hideTask?.cancel()
        guard !anyLayerOpen, !showInfo, isPlaying, !scrubbing else { return }   // keep visible if a layer/info is open, paused, or scrubbing (#129)
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)   // Android CONTROL_BAR_AUTO_HIDE_MS
            guard !Task.isCancelled else { return }
            self?.visible = false
        }
    }

    func forceShow() { hideTask?.cancel(); visible = true }

    /// Dismiss the OSD and every open layer immediately — first tap on the video.
    /// A tap landing outside the control bar during a drag would otherwise tear the Slider
    /// out from under the finger, and because `scrubbing` is cleared only by the Slider's release branch,
    /// a hide mid-drag could also strand the flag set for the life of the view.
    func hide() { guard !scrubbing else { return }; hideTask?.cancel(); closeAllLayers(); visible = false }

    /// The bar and every layer closed: Android resumeIfPausedByOk's trigger (MoreMenu.swift).
    private func layersChanged() {
        if !visible, !anyLayerOpen { onBarePicture() }
    }

    // MARK: Toast (web showVideoOsd equivalent, Android showOsd)

    func flash(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)   // Android OSD_HIDE_MS
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Layers: open / close

    func openSheet(_ s: Sheet) {
        sheet = s
        focusIndex = sheetContent(s).rows.firstIndex { $0.selected } ?? 0
        forceShow()
    }

    func toggleSheet(_ s: Sheet) { if sheet == s { closeSheet() } else { openSheet(s) } }

    func closeSheet() { sheet = nil; scheduleHide() }

    /// Hold Return or "?": the bar this press opened goes down first (so a Pause-on-OK pause
    /// is undone, as on Android), then the card shows over the picture.
    func toggleShortcuts() {
        if shortcutsOpen { shortcutsOpen = false; scheduleHide(); return }
        hide()
        shortcutsOpen = true
    }

    /// Esc / the iOS edge swipe: close the topmost layer. False when none was open.
    @discardableResult
    func closeTopLayer() -> Bool {
        if subsDelayOpen { subsDelayOpen = false }
        else if sheet != nil { sheet = nil }
        else if shortcutsOpen { shortcutsOpen = false }
        else if moreOpen { moreOpen = false }
        else { return false }
        scheduleHide()
        return true
    }

    private func closeAllLayers() { subsDelayOpen = false; sheet = nil; shortcutsOpen = false; moreOpen = false }

    // MARK: Sheet dispatch (one case per component file)

    func sheetContent(_ s: Sheet) -> OSDSheetContent {
        switch s {
        case .subtitles: return subtitleSheetContent()   // SubtitleSheet.swift (E3)
        case .audio: return audioSheetContent()          // AudioSheet.swift (E4)
        case .quality: return qualitySheetContent()      // QualitySheet.swift (E4)
        case .speed: return speedSheetContent()          // MoreMenu.swift (E9)
        case .aspect: return aspectSheetContent()        // AspectSheet.swift (E7)
        case .style: return styleSheetContent()          // StyleSheet.swift (E5)
        }
    }

    private func sheetHandleKey(_ s: Sheet, _ key: OSDKey) -> Bool {
        switch s {
        case .subtitles: return subtitleSheetHandleKey(key)
        case .audio: return audioSheetHandleKey(key)
        case .quality: return qualitySheetHandleKey(key)
        case .speed: return speedSheetHandleKey(key)
        case .aspect: return aspectSheetHandleKey(key)
        case .style: return styleSheetHandleKey(key)
        }
    }

    /// Row `idx` of the open sheet picked (Return or a click). Disabled rows do nothing.
    func pickRow(_ idx: Int) {
        guard let s = sheet else { return }
        let rows = sheetContent(s).rows
        guard rows.indices.contains(idx), rows[idx].enabled else { return }
        focusIndex = idx
        rows[idx].action()
    }

    /// The generic sheet keys, after the component's own handler declined: up/down move the
    /// focus (wrapping), left/right adjust an arrow row or switch tabs, else left closes and
    /// right picks (the pre-#466 side menu's keys), Return picks.
    private func sheetNavigate(_ key: OSDKey) -> Bool {
        guard let s = sheet else { return false }
        let content = sheetContent(s)
        let n = max(1, content.rows.count)
        let focused = content.rows.indices.contains(focusIndex) ? content.rows[focusIndex] : nil
        switch key {
        case .up: focusIndex = (focusIndex - 1 + n) % n
        case .down: focusIndex = (focusIndex + 1) % n
        case .left, .right:
            let d = key == .left ? -1 : 1
            if let adjust = focused?.adjust, focused?.enabled == true { adjust(d) }
            else if !content.tabs.isEmpty, let select = content.selectTab {
                select((content.activeTab + d + content.tabs.count) % content.tabs.count)
            } else if d < 0 { closeSheet() }
            else { pickRow(focusIndex) }
        case .ret: pickRow(focusIndex)
        default: return false
        }
        return true
    }

    // MARK: Key router

    /// keyDown from PlayerView's NSEvent monitor. True = handled (the event is swallowed).
    /// Return repeats are swallowed: the press that is still down already acted (Android #452).
    func keyDown(_ key: OSDKey, isRepeat: Bool) -> Bool {
        if key == .ret, isRepeat { return true }
        return route(key)
    }

    /// keyUp: only Return matters, it ends a hold that has not fired yet.
    func keyUp(_ key: OSDKey) -> Bool {
        guard key == .ret else { return false }
        returnHoldTask?.cancel(); returnHoldTask = nil
        return true
    }

    /// Top layer first. Each open layer's handler sees the key before the ones below it; a key
    /// it returns false for falls through, ending at the bare picture (so Space, f and the
    /// sheet letters keep working with a layer open, as before #466). Esc closes the top
    /// layer when its handler did not take it.
    func route(_ key: OSDKey) -> Bool {
        if subsDelayOpen, subsDelayHandleKey(key) { return true }       // SubsDelayPill.swift (E6)
        if let s = sheet, sheetHandleKey(s, key) || sheetNavigate(key) { return true }
        if shortcutsOpen, shortcutsHandleKey(key) { return true }        // ShortcutsOverlay.swift (E9)
        if moreOpen, moreMenuHandleKey(key) { return true }              // MoreMenu.swift (E9)
        if key == .escape, closeTopLayer() { return true }
        if visible, controlBarHandleKey(key) { return true }             // ControlBar.swift (E2)
        return barePictureKey(key)
    }

    private func barePictureKey(_ key: OSDKey) -> Bool {
        switch key {
        case .space: togglePlay()                                        // Transport (E2)
        case .left: seekKey(-1)
        case .right: seekKey(1)
        case .up: jumpKey(1)
        case .down: jumpKey(-1)
        case .ret: okPress(); controlBarOpenedByKey(); armReturnHold()   // ControlBar.swift (E2)
        case .escape:
            if isFullscreen { toggleFullscreen() } else { playback?.stop() }
        case .char("?"): toggleShortcuts()
        case .char(","), .char("."), .char("/"): return subsDelayGlobalKey(key)   // SubsDelayPill.swift (E6)
        case .char("b"): bookmark()
        case .char("s"): toggleSheet(.subtitles)
        case .char("a"): toggleSheet(.audio)
        case .char("d"): toggleSheet(.speed)
        case .char("q"): if !(playback?.qualityOptions.isEmpty ?? true) { toggleSheet(.quality) }
        case .char("w"): toggleSheet(.aspect)
        case .char("f"): toggleFullscreen()
        case .char("i"): toggleInfo()
        default: return false
        }
        return true
    }

    /// OK on the picture (Return on the bare picture or bar, a click on the picture): show or
    /// hide the bar, Android handleSelectPress. Pause on OK (MoreMenu.swift) pauses first.
    func okPress() {
        if visible { hide() } else { pauseOnOkIfEnabled(); wake() }
    }

    /// Android SELECT_HOLD_MS: a Return held 550 ms opens the shortcuts card.
    private func armReturnHold() {
        returnHoldTask?.cancel()
        returnHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled, let self else { return }
            self.returnHoldTask = nil
            if !self.shortcutsOpen { self.toggleShortcuts() }
        }
    }

    // MARK: Info (Mac extra)

    func toggleInfo() {
        showInfo.toggle()
        if showInfo { forceShow() } else { scheduleHide() }
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
