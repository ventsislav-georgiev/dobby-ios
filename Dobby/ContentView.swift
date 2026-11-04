import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var typingOnTv = false
    /// #508: the Pi is retired, so nothing is probed and nothing is waited for: the bundled
    /// shell, straight away, under the origin its data is keyed to (ServerAddresses.origin()).
    private let origin = ServerAddresses.origin()

    var body: some View {
        ZStack {
            if let origin, BundledShell.root != nil {
                WebContainer(url: origin)
                    .ignoresSafeArea()
                    .background(Color.black)
            } else {
                // #155: a build made without the sibling dobby checkout (scripts/copy-app-shell.sh),
                // or with no DOBBY_PI_HOST and nothing stored, has nothing to load. Say which.
                Text(origin == nil ? "This build has no app origin (DOBBY_PI_HOST)." : "This build has no app shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }

            if let url = playback.playURL, playback.request != nil {
                PlayerView(url: url, time: playback.player.timemodel, subtitles: playback.player.subtitleModel,
                           playback: playback)
                    .environmentObject(playback)
                    .transition(.opacity)
            }

            #if os(iOS)
            // #541: the native remote player (this phone controls another device), over everything.
            RemotePlayerView(model: playback.remote)
            #endif
        }
        .animation(.easeInOut(duration: 0.2), value: playback.activeRef)
        .onReceive(NotificationCenter.default.publisher(for: TvLink.open)) { _ in typingOnTv = true }
        .sheet(isPresented: $typingOnTv) {
            TvLinkSheet()
        }
    }
}
