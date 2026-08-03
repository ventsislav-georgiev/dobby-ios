import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    /// Origin the web view is on. Resolved from `ServerAddresses` at launch so LAN
    /// and Tailscale both work without anyone switching a setting.
    @State private var serverURL: URL?
    @State private var resolving = true
    @State private var editingAddresses = false
    #if os(iOS)
    @ObservedObject private var spotify = SpotifyLyricsSession.shared
    #endif

    var body: some View {
        ZStack {
            if let serverURL {
                WebContainer(url: serverURL)
                    .ignoresSafeArea()
                    .background(Color.black)
            } else {
                ServerUnreachableView(resolving: resolving, edit: { editingAddresses = true })
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
        #if os(iOS)
        // Opened from the Audiobooks tab's "Spotify Lyrics" row, over the bridge.
        // A cover, not a sibling in the stack: the whole app is mounted with
        // `.ignoresSafeArea()` for the web view (DobbyApp), so anything laid out
        // alongside it lands under the status bar — which is where the title and the
        // close button were, unreachable. A modal presentation gets its own safe area.
        #if os(iOS)
        .fullScreenCover(isPresented: $spotify.presented) {
            LyricsView(session: spotify) { spotify.dismiss() }
        }
        #endif
        // Getting into the car with Spotify already going is the whole use case;
        // don't make it a tap. The Live Activity can only be *started* by a
        // foregrounded app, which is exactly where we are at this moment.
        .onChange(of: playback.carRoute.isCar) { isCar in
            guard isCar, spotify.connected, !spotify.track.isEmpty else { return }
            spotify.present()
        }
        #endif
    }

    private func resolve() async {
        resolving = true
        serverURL = await ServerAddresses.resolve()
        resolving = false
        #if os(iOS)
        spotify.serverURL = serverURL
        await spotify.refreshStatus()
        #endif
    }
}

private struct ServerUnreachableView: View {
    let resolving: Bool
    let edit: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if resolving {
                ProgressView()
                Text("Finding Dobby…").foregroundStyle(.secondary)
            } else {
                Text("Can't reach Dobby").font(.headline)
                Text(ServerAddresses.candidates().map(\.absoluteString).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Edit addresses", action: edit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

/// Native escape hatch for the address list. Normally the web app's Settings page
/// owns it and pushes it down over the bridge; this exists for when no address
/// works and that page is therefore unreachable.
private struct AddressEditor: View {
    let retry: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ServerAddresses.candidates().map(\.absoluteString).joined(separator: "\n")

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
