import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    /// Origin the web view is on. Resolved from `ServerAddresses` at launch so LAN
    /// and Tailscale both work without anyone switching a setting.
    @State private var serverURL: URL?
    /// #151: this load is the bundled shell under `serverURL`, not the Pi at it.
    @State private var offlineShell = false
    @State private var resolving = true
    @State private var editingAddresses = false
    @State private var typingOnTv = false

    var body: some View {
        ZStack {
            if let serverURL {
                WebContainer(url: serverURL, offlineShell: offlineShell)
                    .ignoresSafeArea()
                    .background(Color.black)
            } else {
                ServerUnreachableView(
                    resolving: resolving,
                    edit: { editingAddresses = true },
                    offline: continueOffline
                )
            }

            if let url = playback.playURL, playback.request != nil {
                PlayerView(url: url, time: playback.player.timemodel, subtitles: playback.player.subtitleModel)
                    .environmentObject(playback)
                    .transition(.opacity)
            }

        }
        .animation(.easeInOut(duration: 0.2), value: playback.activeRef)
        .task { await resolve() }
        .sheet(isPresented: $editingAddresses) {
            AddressEditor { await resolve() }
        }
        .onReceive(NotificationCenter.default.publisher(for: TvLink.open)) { _ in typingOnTv = true }
        .sheet(isPresented: $typingOnTv) {
            TvLinkSheet()
        }
    }

    /// "Continue offline", and the headless seam that takes the same action. One
    /// function because it is two writes that must happen together: the origin the app
    /// comes up on, and that this is the bundled shell coming up on it rather than the
    /// Pi. Setting only the first is the pre-#151 behaviour — right for a box that has
    /// paired (the service worker's cache is keyed to that origin) and a blank page for
    /// one that never has, which is the case the shell exists for.
    ///
    /// `candidates()` is the app's existing memory of where the Pi is — last known-good,
    /// then the configured list, then the baked-in default — so this works on a fresh
    /// install that has never seen the Pi. Same choice as Android's `loadBundledShell()`.
    private func continueOffline() {
        serverURL = ServerAddresses.candidates().first
        offlineShell = true
    }

    private func resolve() async {
        resolving = true
        offlineShell = false
        // #181: Android's `skipsProbe` call site (MainActivity.resolveAndLoad). The Pi
        // turned off means there is nothing to probe for, so nothing is probed: straight
        // to the bundled shell, the #151 Pi-less cold start. A build with no shell gets
        // the unreachable screen instead, as Android's address dialog — its "Continue
        // offline" would otherwise be a plain load of the Pi origin nobody asked for.
        if !ServerAddresses.piEnabled() {
            NSLog("%@", "Dobby: Pi disabled by the user setting; probe skipped")
            resolving = false
            if BundledShell.root != nil { continueOffline() }
            return
        }
        serverURL = await ServerAddresses.resolve()
        resolving = false
        // #479: the Pi is on but nothing answered — Android's `resolveAndLoad` outcome two,
        // the bundled shell, not a blocking screen. Addresses are edited in the web app's
        // Settings from there; the unreachable screen is left to a build with no shell.
        if serverURL == nil, BundledShell.root != nil {
            continueOffline()
            return
        }
        #if DEBUG
        // #116 device round 3 test seam: DOBBY_AUTO_OFFLINE=1 performs the same
        // action as tapping "Continue offline" below, for a headless run.
        if serverURL == nil, ServerAddresses.autoOfflineSeamActive() {
            continueOffline()
        }
        #endif
    }
}

private struct ServerUnreachableView: View {
    let resolving: Bool
    let edit: () -> Void
    let offline: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if resolving {
                DobbyMark(trace: true).frame(width: 120, height: 120)
            } else {
                Text("Can't reach Dobby").font(.headline)
                Text(ServerAddresses.candidates().map(\.absoluteString).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Edit addresses", action: edit)
                Button("Continue offline", action: offline)
                // #155: a build made without the sibling dobby checkout
                // (scripts/copy-app-shell.sh) has no shell to synthesize, so
                // "Continue offline" is a blank page here, not a bug. Say so on the
                // exact screen a never-paired device lands on, driven by the same
                // BundledShell.root the offline load itself branches on — or a
                // device round spends itself deciding whether the feature or the
                // build is what is missing.
                if BundledShell.root == nil {
                    Text("This build has no offline shell — Continue offline will be blank.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        // #504: the launch screen centres the mark on the whole screen, so the loader does too.
        .ignoresSafeArea(edges: resolving ? .all : [])
    }
}

/// #504: the Android TV launch mark, in its 108 viewport: the glass plate at 12 %, the D outline at
/// 32 %, the play glyph opaque, and while loading a bright trace (28 % of the outline) running round
/// it every 1.6 s. The launch screen's LaunchMark.pdf is this view drawn without the trace.
struct DobbyMark: View {
    let trace: Bool

    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width, geo.size.height) / 108
            let line = StrokeStyle(lineWidth: 11 * k, lineCap: .round, lineJoin: .round)
            ZStack {
                DobbyOutline().fill(Color.white.opacity(0.12))
                DobbyOutline().stroke(Color.white.opacity(0.32), style: line)
                DobbyPlay().fill(Color.white)
                if trace {
                    TimelineView(.animation) { tl in
                        let o = CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6)
                        // The segment [o, o + 0.28], split in two where it wraps past the path's start.
                        ZStack {
                            DobbyOutline().trim(from: o, to: min(o + 0.28, 1)).stroke(Color.white, style: line)
                            DobbyOutline().trim(from: 0, to: max(o + 0.28 - 1, 0)).stroke(Color.white, style: line)
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// M29,23 H49 A31,31 0 0 1 49,85 H29 Z
private struct DobbyOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 29, y: 23))
        p.addLine(to: CGPoint(x: 49, y: 23))
        p.addRelativeArc(center: CGPoint(x: 49, y: 54), radius: 31, startAngle: .degrees(-90), delta: .degrees(180))
        p.addLine(to: CGPoint(x: 29, y: 85))
        p.closeSubpath()
        return p.applying(viewport(rect))
    }
}

/// The play glyph: the triangle (43,38) (70,54) (43,70) with 3.5 corners, as Android's arcs draw it.
private struct DobbyPlay: Shape {
    func path(in rect: CGRect) -> Path {
        let a = CGPoint(x: 43, y: 38), b = CGPoint(x: 70, y: 54), c = CGPoint(x: 43, y: 70)
        var p = Path()
        p.move(to: CGPoint(x: 43, y: 54))
        p.addArc(tangent1End: a, tangent2End: b, radius: 3.5)
        p.addArc(tangent1End: b, tangent2End: c, radius: 3.5)
        p.addArc(tangent1End: c, tangent2End: a, radius: 3.5)
        p.closeSubpath()
        return p.applying(viewport(rect))
    }
}

private func viewport(_ rect: CGRect) -> CGAffineTransform {
    let k = min(rect.width, rect.height) / 108
    return CGAffineTransform(translationX: rect.midX - 54 * k, y: rect.midY - 54 * k).scaledBy(x: k, y: k)
}

/// Native escape hatch for the address list. Normally the web app's Settings page
/// owns it and pushes it down over the bridge; this exists for when no address
/// works and that page is therefore unreachable.
private struct AddressEditor: View {
    let retry: () async -> Void
    @Environment(\.dismiss) private var dismiss
    /// #245: the whole stored list, not the probe order `candidates()` gives on iOS, or a Save
    /// here would drop the entries this device skips (the Pi's LAN address, still the Pi).
    @State private var text = ServerAddresses.candidates(rule: .keepAll).map(\.absoluteString).joined(separator: "\n")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dobby server addresses").font(.headline)
            Text("One per line, most preferred first.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .frame(minHeight: 120)
                .border(.secondary)
            #if os(iOS)
            // #245: the PWA's Settings note, word for word. Fixed text: no name, no address.
            Text("Only the https Tailscale address works on iPhone and iPad; the others are ignored on this device.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save & retry") {
                    let addresses = text.split(whereSeparator: \.isNewline).compactMap { ServerAddresses.normalize(String($0)) }
                    if !addresses.isEmpty { ServerAddresses.store(addresses) }
                    dismiss()
                    Task { await retry() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}
