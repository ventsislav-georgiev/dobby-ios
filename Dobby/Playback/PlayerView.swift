import SwiftUI
import KSPlayer
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Full-window native player with an Android-TV-style OSD. This file is the composition and
/// the input wiring only; the OSD contract (which file each part lives in, the key router, the
/// layers) is OSD-CONTRACT.md (repo root). macOS: keys go through PlayerControls' router,
/// a click on the picture shows or hides the bar, a double-click toggles fullscreen, mouse
/// movement reveals the bar. iOS: tap regions, the left-edge back swipe (Esc), tappable rows,
/// and a hardware keyboard (iPad) feeding the same router as the Mac keys (#487).
struct PlayerView: View {
    @EnvironmentObject var playback: PlaybackCoordinator
    @ObservedObject var time: ControllerTimeModel
    @ObservedObject var subtitles: SubtitleModel
    @StateObject var controls: PlayerControls
    let url: URL

    @State var scrub = ScrubState()
    @State var isPlaying = true
    /// #131: true from touch-down on the Slider until SwiftUI tears the gesture down.
    /// `@GestureState` is reset automatically when the gesture ends *or is cancelled* —
    /// that is the whole reason the wrapper exists over a plain `@State` set in
    /// `onChanged` and cleared in `onEnded`. Every terminal callback SwiftUI offers
    /// (`onEnded`, `Slider`'s `onEditingChanged(false)`) is only delivered when the
    /// gesture *completes*, so they all fail in the same direction; the reset does not.
    /// Declared here, on the root view, so it outlives the control bar (ControlBar.swift).
    @GestureState var sliderTouch = false
    /// #131 diagnostics only: did the Slider report `onEditingChanged(true)` for this
    /// touch? Separates "the release was delivered normally" from "the touch never became
    /// a drag" in the log, so those two never share one signature.
    @State var sliderDidBegin = false
    /// How far up from the bottom the bar, and the pause cards over it, reach (#496 cue lift).
    @State var barCover: CGFloat = 0
    @State var pauseCardsCover: CGFloat = 0

    static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "playback")
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    init(url: URL, time: ControllerTimeModel, subtitles: SubtitleModel, playback: PlaybackCoordinator) {
        self.url = url
        self.time = time
        self.subtitles = subtitles
        // #525: the controls hold the coordinator from the first body. Set in onAppear (after
        // it, and not published), the preparing screen kept an empty title and the default tint.
        _controls = StateObject(wrappedValue: PlayerControls(playback: playback))
    }

    var body: some View {
        // #538: the picture is the layout base and every OSD layer an overlay of it (the overlay
        // stacks them as a ZStack would), so no layer can size or move the picture. In one
        // ZStack every layer took part in sizing the root, and with the bar up the hidden pause
        // cards over the bar's twin pushed it: on a landscape iPhone the picture shrank and rode up.
        picture.overlay {
            #if os(iOS)
            touchRegions                                           // ControlBar.swift (E2)
            #else
            pictureClicks
            #endif

            subtitleOverlay                                        // SubtitleOverlay.swift (E5)
            playerLoaders                                          // PlayerLoaders.swift (E11)

            if controls.showInfo {
                infoOverlay.transition(.opacity)
            }

            pauseInfoCards                                         // PauseInfoCards.swift (E10)
            controlBarLayer                                        // ControlBar.swift (E2)

            // Close button as a top-level, topmost layer (not inside the bar): in iOS
            // portrait the bar's overlay was below the tap regions in hit-test order, so
            // the X wasn't tappable. A dedicated top layer always wins the touch.
            if controls.visible {
                // Root view ignores the safe area, so offset manually below the status
                // bar / Dynamic Island — touches there never reach the app (portrait
                // X-not-tappable bug).
                VStack { HStack { closeButton; Spacer() }; Spacer() }
                    .padding(.top, topSafeInset)
            }

            // Modal layers, bottom to top in the router's reverse priority.
            moreMenu                                               // MoreMenu.swift (E9)
            shortcutsOverlay                                       // ShortcutsOverlay.swift (E9)
            if let sheet = controls.sheet {
                OSDSheetView(content: controls.sheetContent(sheet), tint: controls.tint,
                             focusIndex: controls.focusIndex,
                             onFocus: { controls.focusIndex = $0 },
                             onPick: { controls.pickRow($0) },
                             onDismiss: { controls.closeSheet() })
                    .transition(.opacity)
            }
            subsDelayPill                                          // SubsDelayPill.swift (E6)

            if let toast = controls.toast {
                OSDToast(message: toast, tint: controls.tint)
                    .padding(.top, topSafeInset)
                    .transition(.opacity)
            }

            #if os(macOS)
            WindowAccessor { win in controls.attachWindow(win) }.allowsHitTesting(false)
            #else
            HardwareKeys { key, up in send(key, up: up) }.allowsHitTesting(false)
            #endif
        }
        .animation(.easeInOut(duration: 0.18), value: controls.visible)
        .animation(.easeInOut(duration: 0.12), value: controls.toast)
        .animation(.easeInOut(duration: 0.16), value: controls.sheet)
        .onAppear { installInput() }
        .onDisappear { removeInput(); controls.exitFullscreenIfNeeded() }
        // #131: deliberately on the root, not on the Slider. If the control bar is torn
        // out mid-drag the Slider's gesture dies with it, but `sliderTouch` lives on this
        // view, so the reset still reaches a handler that is still mounted.
        .onChange(of: sliderTouch) { down in if !down { sliderTouchEnded() } }
        #if os(iOS)
        // #197: the left-edge back swipe. The player covers the WebView, so its edge recognizer
        // never sees these touches; this is the macOS Esc / Android PlaybackActivity Back:
        // an open layer closes first, else the player closes. Simultaneous, so taps and the
        // Slider keep their own gestures; only a drag that starts at the edge counts. #487: it
        // is Esc through the router, so it does exactly what a hardware Esc does.
        .simultaneousGesture(DragGesture(minimumDistance: 30, coordinateSpace: .global).onEnded { v in
            guard v.startLocation.x < 24, v.translation.width > 50 else { return }
            _ = send(.escape, up: false)
        })
        #endif
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { controls.wake() }
        }
        #endif
    }

    /// The video, full window, under everything. Its size comes from the window alone (#538).
    private var picture: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            KSVideoPlayer(coordinator: playback.player, url: url, options: playback.options)
                .onStateChanged { _, state in
                    playback.onStateChanged(state)
                    isPlaying = state.isPlaying
                    controls.syncState(state)
                    if state == .readyToPlay { controls.wake() }
                }
                .onPlay { cur, total in
                    playback.onProgress(current: cur, total: total)
                    controls.playbackTick(current: cur)
                }
                .onFinish { _, err in playback.onFinish(error: err) }
                .aspectTransform(controls)                         // AspectSheet.swift (E7, #477 reset)
                .ignoresSafeArea()
                .clipped()
        }
    }

    // MARK: Picture clicks (macOS; iOS taps are ControlBar.swift's touchRegions)

    #if os(macOS)
    /// macOS: a click on the picture is Android's OK (show / hide the bar, owner ruling D2),
    /// a double-click toggles fullscreen. Below the OSD in the ZStack, so its controls win.
    private var pictureClicks: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { controls.toggleFullscreen() }
            .onTapGesture(count: 1) { controls.okPress() }
    }
    #endif

    private var closeButton: some View {
        Button { playback.stop() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 3)
                .padding(16)   // inside the label: whole padded area is tappable (≥44pt)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Top safe-area inset read off the key window — GeometryReader reports zero
    /// here because an ancestor already ignores the safe area.
    private var topSafeInset: CGFloat { Self.topSafeInset }

    /// Also the native remote player's (#541).
    static var topSafeInset: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
        #else
        0
        #endif
    }

    // MARK: Info OSD (stats for nerds) — live, refreshed each second

    private var infoOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 3) {
                ForEach(statLines, id: \.self) { Text($0) }
            }
            .font(.system(size: 11, weight: .medium).monospaced())
            .foregroundStyle(.white)
            .padding(12)
            .osdCard(fill: controls.tint.panel, radius: 10, hairline: .white.opacity(0.18))
            .padding(.top, 56)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .allowsHitTesting(false)
    }

    private var statLines: [String] {
        guard let p = playback.player.playerLayer?.player else { return ["no stream"] }
        var out: [String] = []
        let sz = p.naturalSize
        if sz.width > 0 { out.append("resolution  \(Int(sz.width))×\(Int(sz.height))") }
        let vtracks = p.tracks(mediaType: .video)
        if let v = vtracks.first(where: { $0.isEnabled }) ?? vtracks.first {
            out.append("video       \(fourCC(v.codecType))  \(v.bitRate / 1000) kbps")
            if v.nominalFrameRate > 0 { out.append(String(format: "track fps   %.3f", v.nominalFrameRate)) }
        }
        let atracks = p.tracks(mediaType: .audio)
        if let a = atracks.first(where: { $0.isEnabled }) ?? atracks.first {
            out.append("audio       \(fourCC(a.codecType))  \(a.bitRate / 1000) kbps")
        }
        if let d = p.dynamicInfo {
            out.append(String(format: "display fps %.1f", d.displayFPS))
            out.append("v-bitrate   \(d.videoBitrate / 1000) kbps")
            out.append("a-bitrate   \(d.audioBitrate / 1000) kbps")
            out.append("dropped     \(d.droppedVideoFrameCount) frames")
            out.append(String(format: "a/v sync    %+.0f ms", d.audioVideoSyncDiff * 1000))
            out.append(String(format: "read        %.1f MB", Double(d.bytesRead) / 1_048_576))
        }
        if p.fileSize > 0 { out.append(String(format: "size        %.1f MB", p.fileSize / 1_048_576)) }
        return out
    }

    /// FourCharCode (e.g. 'avc1', 'hvc1', 'mp4a') → trimmed ASCII string.
    private func fourCC(_ c: UInt32) -> String {
        let bytes = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
        let s = (String(bytes: bytes, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "—" : s
    }

    // MARK: Input wiring

    private func installInput() {
        #if os(macOS)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            handleKey(event) ? nil : event   // swallow handled keys
        }
        #endif
    }

    private func removeInput() {
        #if os(macOS)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        #endif
    }

    /// One key from any source (the Mac's NSEvent monitor, an iPad hardware keyboard, the iOS
    /// edge swipe) into the router. True = handled (the event is swallowed).
    private func send(_ key: OSDKey, up: Bool, isRepeat: Bool = false) -> Bool {
        if up { return controls.keyUp(key) }
        let handled = controls.keyDown(key, isRepeat: isRepeat)
        if key == .space { isPlaying = controls.isPlaying }
        return handled
    }

    #if os(macOS)
    /// Returns true if the key was handled (and should be swallowed). Command / Control chords
    /// pass through untouched so the menu bar's shortcuts (Cmd-Q, Cmd-W) still work.
    private func handleKey(_ e: NSEvent) -> Bool {
        if !e.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        guard let key = Self.osdKey(e) else { return false }
        return send(key, up: e.type == .keyUp, isRepeat: e.isARepeat)
    }

    /// Key codes are layout-independent; letters and punctuation map to the US key at that
    /// position. "?" is Shift-slash.
    private static func osdKey(_ e: NSEvent) -> OSDKey? {
        switch e.keyCode {
        case 49: return .space
        case 123: return .left
        case 124: return .right
        case 126: return .up
        case 125: return .down
        case 36, 76: return .ret
        case 53: return .escape
        case 44: return .char(e.modifierFlags.contains(.shift) ? "?" : "/")
        default:
            let letters: [UInt16: Character] = [0: "a", 1: "s", 2: "d", 3: "f", 11: "b", 12: "q", 13: "w",
                                                34: "i", 43: ",", 47: "."]
            return letters[e.keyCode].map(OSDKey.char)
        }
    }
    #endif
}

#if os(iOS)
/// #487: a hardware keyboard on iOS (iPad) into the same router as the Mac keys. A view with no
/// hit area that takes the first responder while the player is up and hands it back (the web
/// view) when the player closes. Key codes are layout-independent like the Mac's; Command /
/// Control chords and unmapped keys go up the responder chain untouched. UIKit delivers no
/// auto-repeat presses here, so a held key acts once.
private struct HardwareKeys: UIViewRepresentable {
    let onKey: (OSDKey, _ up: Bool) -> Bool

    func makeUIView(context: Context) -> KeyView { let v = KeyView(); v.onKey = onKey; return v }
    func updateUIView(_ v: KeyView, context: Context) { v.onKey = onKey }

    final class KeyView: UIView {
        var onKey: ((OSDKey, Bool) -> Bool)?
        private weak var previous: UIResponder?
        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            previous = UIResponder.dobbyCurrent
            becomeFirstResponder()
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil, isFirstResponder { resignFirstResponder(); previous?.becomeFirstResponder() }
            super.willMove(toWindow: newWindow)
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = presses.filter { !handle($0, up: false) }
            if !rest.isEmpty { super.pressesBegan(rest, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = presses.filter { !handle($0, up: true) }
            if !rest.isEmpty { super.pressesEnded(rest, with: event) }
        }

        /// A cancelled press ends like a release (Return's hold timer must not fire).
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = presses.filter { !handle($0, up: true) }
            if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
        }

        private func handle(_ press: UIPress, up: Bool) -> Bool {
            guard let k = press.key, k.modifierFlags.intersection([.command, .control]).isEmpty,
                  let key = Self.osdKey(k) else { return false }
            return onKey?(key, up) ?? false
        }

        /// Same keys as PlayerView.osdKey on the Mac: US-layout position, "?" is Shift-slash.
        private static func osdKey(_ k: UIKey) -> OSDKey? {
            switch k.keyCode {
            case .keyboardSpacebar: return .space
            case .keyboardLeftArrow: return .left
            case .keyboardRightArrow: return .right
            case .keyboardUpArrow: return .up
            case .keyboardDownArrow: return .down
            case .keyboardReturnOrEnter, .keypadEnter: return .ret
            case .keyboardEscape: return .escape
            case .keyboardSlash: return .char(k.modifierFlags.contains(.shift) ? "?" : "/")
            default:
                let letters: [UIKeyboardHIDUsage: Character] = [
                    .keyboardA: "a", .keyboardS: "s", .keyboardD: "d", .keyboardF: "f", .keyboardB: "b",
                    .keyboardQ: "q", .keyboardW: "w", .keyboardI: "i", .keyboardComma: ",", .keyboardPeriod: "."]
                return letters[k.keyCode].map(OSDKey.char)
            }
        }
    }
}

private extension UIResponder {
    private static weak var dobbyFound: UIResponder?
    /// The current first responder (nil-targeted action trick), so the key view can hand it back.
    static var dobbyCurrent: UIResponder? {
        dobbyFound = nil
        UIApplication.shared.sendAction(#selector(dobbyReportFirstResponder), to: nil, from: nil, for: nil)
        return dobbyFound
    }
    @objc private func dobbyReportFirstResponder() { UIResponder.dobbyFound = self }
}
#endif

#if os(macOS)
/// Resolves the hosting NSWindow (for fullscreen) and clears the 16:9 aspect-ratio
/// lock KSPlayer's dismantleNSView leaves on the window, which would otherwise
/// constrain the web-browsing window after the player closes.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onResolve(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        let win = nsView.window
        // Clear KSPlayer's 16:9 lock so the web-browsing window can be freely zoomed
        // again. resizeIncrements clears the aspect constraint (mutually exclusive);
        // aspectRatio = (0,0) is degenerate and crashes a later resize.
        DispatchQueue.main.async { win?.resizeIncrements = NSSize(width: 1, height: 1) }
    }
}
#endif
