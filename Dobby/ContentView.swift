import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator

    var body: some View {
        ZStack {
            WebContainer(url: AppConfig.serverURL)
                .ignoresSafeArea()
                .background(Color.black)

            if let url = playback.playURL, playback.request != nil {
                PlayerView(url: url, time: playback.player.timemodel, subtitles: playback.player.subtitleModel)
                    .environmentObject(playback)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playback.activeRef)
    }
}
