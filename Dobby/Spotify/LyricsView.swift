#if os(iOS)
import SwiftUI
import AuthenticationServices

/// The phone half of the Spotify lyrics lane. Big type, centred current line,
/// scrolls itself — a mounted phone is glanceable at arm's length, which the
/// CarPlay Dashboard card (three lines in a corner) is not.
struct LyricsView: View {
    @ObservedObject var session: SpotifyLyricsSession
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !session.connected {
                ConnectView(session: session)
            } else if session.lines.isEmpty {
                idle
            } else {
                lyrics
            }
            controls
        }
        .preferredColorScheme(.dark)
    }

    private var idle: some View {
        VStack(spacing: 12) {
            Text(session.track.isEmpty ? "Nothing playing in Spotify" : session.track)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if !session.artist.isEmpty {
                Text(session.artist).foregroundStyle(.secondary)
            }
            if let status = session.status {
                Text(status).font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .padding(40)
    }

    private var lyrics: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Padding rows, not real content: they let the first and last
                    // lines sit in the middle of the screen like every other line.
                    Color.clear.frame(height: 160)
                    ForEach(Array(session.lines.enumerated()), id: \.offset) { offset, line in
                        Text(line.text)
                            .font(.system(size: offset == session.index ? 30 : 24,
                                          weight: offset == session.index ? .bold : .medium))
                            .foregroundStyle(offset == session.index ? .white
                                             : (offset < session.index ? .white.opacity(0.25) : .white.opacity(0.45)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(offset)
                    }
                    Color.clear.frame(height: 260)
                }
                .padding(.horizontal, 28)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.index) { index in
                guard index >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.track).font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(session.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer()
            if !session.synced, !session.lines.isEmpty {
                Text("Unsynced lyrics — scroll manually")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.bottom, 12)
            }
        }
    }
}

/// First-run: hand the browser to the server, which owns the OAuth round trip.
private struct ConnectView: View {
    @ObservedObject var session: SpotifyLyricsSession
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.tint)
            Text("Connect Spotify").font(.title2.weight(.semibold))
            Text("Dobby follows what Spotify plays and shows the words — on the phone and on the CarPlay Dashboard. It never plays audio itself.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !session.configured {
                Text("Set a Spotify client ID in Dobby settings first.")
                    .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .disabled(!session.configured)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(40)
    }

    private func connect() {
        guard let url = session.loginURL(callbackScheme: "dobby") else { return }
        let context = PresentationAnchor()
        let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "dobby") { _, err in
            if let err, (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                error = err.localizedDescription
            }
            Task { await session.refreshStatus() }
        }
        auth.presentationContextProvider = context
        auth.prefersEphemeralWebBrowserSession = false
        anchorKeeper = context
        auth.start()
    }

    @State private var anchorKeeper: PresentationAnchor?
}

private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
#endif
