import SwiftUI
import KSPlayer
#if os(macOS)
import AppKit
#endif

/// Full-window native player with an Android-TV-style OSD: bottom transport bar,
/// right-side selection menus (subtitles / audio / speed / aspect), toast feedback.
/// macOS: space=play/pause, ←/→ seek, ↑/↓ menu nav, f=fullscreen, esc=back/close,
/// mouse move reveals the OSD (auto-hides while playing). iOS: tap toggles pause +
/// reveals the OSD; menu rows are tappable.
struct PlayerView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @ObservedObject private var time: ControllerTimeModel
    @ObservedObject private var subtitles: SubtitleModel
    @StateObject private var controls = PlayerControls()
    let url: URL

    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var isPlaying = true
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    // Android OSD palette.
    private let panelBG = Color(red: 8/255, green: 12/255, blue: 24/255).opacity(0.82)
    private let accent = Color(red: 0x5d/255, green: 0xad/255, blue: 0xe2/255)
    private let selectedBG = Color(red: 0x0f/255, green: 0x34/255, blue: 0x60/255)

    init(url: URL, time: ControllerTimeModel, subtitles: SubtitleModel) {
        self.url = url
        self.time = time
        self.subtitles = subtitles
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            KSVideoPlayer(coordinator: playback.player, url: url, options: playback.options)
                .onStateChanged { _, state in
                    playback.onStateChanged(state)
                    isPlaying = state.isPlaying
                    controls.syncState(state)
                    if state == .readyToPlay { controls.wake() }
                }
                .onPlay { cur, total in playback.onProgress(current: cur, total: total) }
                .onFinish { _, err in playback.onFinish(error: err) }
                .scaleEffect(x: controls.zoom * controls.stretch, y: controls.zoom)   // Zoom/Stretch aspect modes
                .ignoresSafeArea()
                .clipped()

            #if os(iOS)
            tapRegions
            #endif

            subtitleOverlay

            if controls.buffering || !controls.loaded {
                loadingSpinner.transition(.opacity)
            }

            if controls.showInfo {
                infoOverlay.transition(.opacity)
            }

            if controls.visible {
                osd.transition(.opacity)
            }

            // Close button as a top-level, topmost layer (not inside `osd`): in iOS
            // portrait the osd's overlay was below the tap regions in hit-test order, so
            // the X wasn't tappable. A dedicated top layer always wins the touch.
            if controls.visible {
                VStack { HStack { closeButton; Spacer() }; Spacer() }
            }

            if let toast = controls.toast {
                toastView(toast).transition(.opacity)
            }

            #if os(macOS)
            WindowAccessor { win in controls.attachWindow(win) }.allowsHitTesting(false)
            #endif
        }
        .animation(.easeInOut(duration: 0.18), value: controls.visible)
        .animation(.easeInOut(duration: 0.12), value: controls.toast)
        .onAppear { controls.playback = playback; installInput() }
        .onDisappear { removeInput(); controls.exitFullscreenIfNeeded() }
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { controls.wake() }
        }
        #endif
    }

    // MARK: Tap regions (iOS)

    /// Three full-height zones under the OSD. While the OSD is showing, any tap just
    /// dismisses it (first tap = hide). With the OSD hidden: left = −10s, center =
    /// play/pause, right = +10s. Sits below the OSD in the ZStack, so OSD buttons win.
    #if os(iOS)
    private var tapRegions: some View {
        HStack(spacing: 0) {
            tapZone { controls.seekBy(-10) }
            tapZone { controls.togglePlay(); isPlaying = controls.isPlaying }
            tapZone { controls.seekBy(10) }
        }
        .ignoresSafeArea()
    }

    private func tapZone(_ action: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { if controls.visible { controls.hide() } else { action() } }
    }
    #endif

    // MARK: OSD

    private var osd: some View {
        ZStack {
            // Dim only while paused, like a modal pause screen.
            if !isPlaying { Color.black.opacity(0.25).ignoresSafeArea() }

            VStack { Spacer(); controlBar }

            if let menu = controls.menu {
                HStack { Spacer(); menuPanel(menu) }
                    .padding(.trailing, 24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: controls.menu)
    }

    private var closeButton: some View {
        Button { playback.stop() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 3)
        }
        .buttonStyle(.plain)
        .padding(16)
    }

    private var controlBar: some View {
        let total = max(1, Double(time.totalTime))
        let current = scrubbing ? scrubValue : Double(time.currentTime)
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(timeLabel(current)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { current }, set: { scrubValue = $0 }), in: 0...total) { editing in
                    scrubbing = editing
                    if !editing { playback.seek(to: scrubValue) }
                    controls.forceShow()
                }
                .tint(accent)
                Text(timeLabel(total)).font(.caption.monospacedDigit())
            }

            HStack(spacing: 18) {
                iconButton(isPlaying ? "pause.fill" : "play.fill", size: 22) { controls.togglePlay(); isPlaying = controls.isPlaying }
                iconButton("gobackward.10", size: 19) { controls.seekBy(-10) }
                iconButton("goforward.10", size: 19) { controls.seekBy(10) }
                Spacer()
                ForEach(PlayerControls.Menu.allCases) { m in
                    iconButton(m.icon, size: 18, active: controls.menu == m) { controls.toggleMenu(m) }
                }
                iconButton("info.circle", size: 18, active: controls.showInfo) { controls.toggleInfo() }
                #if os(macOS)
                iconButton("arrow.up.left.and.arrow.down.right", size: 18) { controls.toggleFullscreen() }
                #endif
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }

    private func iconButton(_ name: String, size: CGFloat, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? accent : .white)
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
    }

    // MARK: Side menu panel (Android subtitle-osd look)

    private func menuPanel(_ menu: PlayerControls.Menu) -> some View {
        let rows = controls.items(for: menu)
        return VStack(alignment: .leading, spacing: 2) {
            Text(menu.title)
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(accent)
                .padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            menuRow(row, focused: controls.focusIndex == idx)
                                .id(idx)
                                .onTapGesture { selectRow(row) }
                        }
                    }
                }
                .onChange(of: controls.focusIndex) { i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
            }
        }
        .padding(12)
        .frame(width: 320)
        .frame(maxHeight: 460)
        .background(panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 17, y: 12)
    }

    private func selectRow(_ row: OSDItem) {
        guard row.enabled else { return }
        row.action()
        controls.forceShow()
    }

    private func menuRow(_ row: OSDItem, focused: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(row.selected ? accent : .white.opacity(0.35))
            Text(row.label)
                .font(.system(size: 14))
                .foregroundStyle(row.enabled ? .white : .white.opacity(0.4))
            Spacer(minLength: 4)
            if let d = row.detail {
                Text(d).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(focused ? selectedBG : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }

    // MARK: Subtitles (styled)

    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            ForEach(subtitles.parts) { part in
                if let text = part.text {
                    styledSubtitle(AttributedString(text))
                }
            }
        }
        .padding(.bottom, (controls.visible ? 120 : 56) + controls.subtitlePosition)
        .animation(.easeInOut(duration: 0.18), value: controls.visible)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func styledSubtitle(_ text: AttributedString) -> some View {
        let size = (controls.subtitleStyle == .large ? 34.0 : 22.0) * controls.subtitleScale
        switch controls.subtitleStyle {
        case .standard:
            Text(text).font(.system(size: size)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 1, x: 1, y: 1)
                .multilineTextAlignment(.center)
        case .large:
            Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 1)
                .multilineTextAlignment(.center)
        case .contrast:
            Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func toastView(_ msg: String) -> some View {
        VStack {
            Spacer()
            Text(msg)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.black.opacity(0.7))
                .clipShape(Capsule())
            Spacer().frame(height: 140)
        }
        .allowsHitTesting(false)
    }

    // MARK: Loading spinner (#3 initial load, #5 seek buffering)

    private var loadingSpinner: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.large)
            .scaleEffect(1.4)
            .tint(.white)
            .allowsHitTesting(false)
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
            .background(panelBG)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.18), lineWidth: 1))
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

    private func timeLabel(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? seconds : 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Input wiring

    private func installInput() {
        #if os(macOS)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event   // swallow handled keys
        }
        #endif
    }

    private func removeInput() {
        #if os(macOS)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        #endif
    }

    #if os(macOS)
    /// Returns true if the key was handled (and should be swallowed).
    private func handleKey(_ e: NSEvent) -> Bool {
        let menuOpen = controls.menu != nil
        switch e.keyCode {
        case 49: controls.togglePlay(); isPlaying = controls.isPlaying           // space
        case 123: if menuOpen { controls.closeMenu() } else { controls.seekBy(-10) } // ←
        case 124: if menuOpen { controls.activateFocused() } else { controls.seekBy(10) } // →
        case 126: if menuOpen { controls.navUp() } else { controls.wake() }      // ↑
        case 125: if menuOpen { controls.navDown() } else { controls.wake() }    // ↓
        case 36, 76: if menuOpen { controls.activateFocused() } else { controls.togglePlay() } // enter
        case 53:                                                                  // esc
            if menuOpen { controls.closeMenu() }
            else if controls.isFullscreen { controls.toggleFullscreen() }
            else { playback.stop() }
        case 3: controls.toggleFullscreen()                                       // f
        case 1: controls.toggleMenu(.subtitles)                                   // s
        case 0: controls.toggleMenu(.audio)                                       // a
        case 2: controls.toggleMenu(.speed)                                       // d
        case 13: controls.toggleMenu(.aspect)                                     // w
        case 34: controls.toggleInfo()                                            // i
        default: return false
        }
        return true
    }
    #endif
}

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
