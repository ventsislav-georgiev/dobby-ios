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
        serverURL = await ServerAddresses.resolve()
        resolving = false
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
                ProgressView()
                Text("Finding Dobby…").foregroundStyle(.secondary)
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
