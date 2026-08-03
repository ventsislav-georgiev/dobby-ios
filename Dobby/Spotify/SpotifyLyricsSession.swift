#if os(iOS)
import Foundation
import AVFoundation
import Combine

/// Follows whatever Spotify is playing and turns it into a lyric line.
///
/// Dobby never touches the audio here — Spotify owns playback and the CarPlay
/// screen. All this does is know *where* in the song Spotify is, and put the
/// matching line on the CarPlay Dashboard (via the Live Activity) and on the
/// phone (via `LyricsView`).
///
/// Two things shape the design:
///
/// * **Position comes from the network, time comes from here.** Spotify's Web
///   API is quota-limited per developer account and `progress_ms` is known to go
///   stale between pause/seek events on some clients, so a poll is a *sync*, not
///   a tick. Between polls the line advances on a local clock and only snaps
///   back when the two disagree by more than a beat.
/// * **The app has to stay awake.** A Live Activity can only be updated by a
///   running process, and there is no widget primitive that walks arbitrary text
///   on its own. `AudioKeepAlive` buys that with a near-silent mixable stream —
///   see its note.
@MainActor
final class SpotifyLyricsSession: ObservableObject {
    /// Shared because the way in is the web app's Audiobooks row, which arrives
    /// over the bridge — `WebBridge` has no path to a view's `@StateObject`.
    static let shared = SpotifyLyricsSession()

    struct Line: Codable, Equatable {
        let t: Int
        let text: String
    }

    /// Lyrics screen on screen. Set by the bridge row and by plugging into a car.
    @Published var presented = false

    @Published private(set) var connected = false
    @Published private(set) var configured = false
    @Published private(set) var running = false
    @Published private(set) var isPlaying = false
    @Published private(set) var track = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: URL?
    @Published private(set) var lines: [Line] = []
    /// Index into `lines`, or -1 before the first line of the song.
    @Published private(set) var index = -1
    @Published private(set) var synced = false
    @Published private(set) var status: String?

    var serverURL: URL?

    private var trackId: String?
    private var durationMs = 0
    /// Playback position at `anchoredAt`, in milliseconds.
    private var anchorMs: Double = 0
    private var anchoredAt = Date()

    private var pollTask: Task<Void, Never>?
    private var endPollPending = false
    private var lastEndPoll = Date.distantPast
    private var ticker: Timer?
    private let keepAlive = AudioKeepAlive()

    /// A poll is a resync, not a heartbeat — the local clock covers the gaps.
    private static let playingPollInterval: TimeInterval = 10
    private static let idlePollInterval: TimeInterval = 15
    /// Below this the difference is network jitter, not a seek. Snapping on jitter
    /// makes the highlighted line jump backwards mid-word.
    private static let resyncThresholdMs: Double = 1500

    // MARK: - Lifecycle

    /// One-shot probe used to decide whether to offer the lyrics entry point.
    func refreshStatus() async {
        guard let url = endpoint("api/spotify/status") else { return }
        struct Status: Decodable { let connected: Bool; let configured: Bool }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return }
        connected = status.connected
        configured = status.configured
        if connected, !running { await poll() }
        // Just came back from the login sheet with the screen already open.
        if connected, presented, !running { start() }
    }

    /// Open the lyrics screen. Following only starts once Spotify is connected —
    /// before that the screen is the Connect prompt, with nothing to poll for.
    func present() {
        presented = true
        if connected { start() }
    }

    func dismiss() {
        presented = false
        stop()
    }

    func start() {
        guard !running else { return }
        running = true
        keepAlive.start()
        NowPlayingActivity.shared.startLyrics(track: track.isEmpty ? "Spotify" : track,
                                              artist: artist,
                                              duration: Double(durationMs) / 1000)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.isPlaying ? Self.playingPollInterval : Self.idlePollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        // 4 Hz is enough to land a line change within a frame of where it belongs
        // and costs nothing next to the radio that is already on.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        running = false
        pollTask?.cancel(); pollTask = nil
        ticker?.invalidate(); ticker = nil
        keepAlive.stop()
        NowPlayingActivity.shared.end()
    }

    /// URL the login sheet should open. The server owns the OAuth round trip —
    /// Spotify only accepts HTTPS redirect URIs and the Pi is the one with a
    /// certificate.
    func loginURL(callbackScheme: String) -> URL? {
        guard var components = endpoint("api/spotify/login").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        else { return nil }
        components.queryItems = [.init(name: "redirect", value: "\(callbackScheme)://spotify-connected")]
        return components.url
    }

    func logout() async {
        stop()
        guard let url = endpoint("api/spotify/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
        connected = false
        lines = []; index = -1; trackId = nil; track = ""; artist = ""
    }

    // MARK: - Sync

    private struct ServerState: Decodable {
        struct Lyrics: Decodable { let synced: Bool; let lines: [Line] }
        let connected: Bool
        let playing: Bool
        let trackId: String?
        let title: String?
        let artist: String?
        let artwork: String?
        let durationMs: Int?
        let progressMs: Int?
        let ageMs: Int
        let lyrics: Lyrics?
        let lyricsUnavailable: Bool
        let error: String?
    }

    private func poll() async {
        guard var components = endpoint("api/spotify/state").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        else { return }
        if let trackId { components.queryItems = [.init(name: "have", value: trackId)] }
        guard let url = components.url else { return }

        let sentAt = Date()
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let state = try? JSONDecoder().decode(ServerState.self, from: data) else {
            status = "Can't reach Dobby"
            return
        }
        let roundTrip = Date().timeIntervalSince(sentAt)

        connected = state.connected
        guard state.connected else { status = "Spotify not connected"; stop(); return }

        let trackChanged = state.trackId != trackId
        if trackChanged {
            trackId = state.trackId
            lines = state.lyrics?.lines ?? []
            synced = state.lyrics?.synced ?? false
            index = -1
            track = state.title ?? ""
            artist = state.artist ?? ""
            artwork = state.artwork.flatMap(URL.init(string:))
            durationMs = state.durationMs ?? 0
            if running {
                NowPlayingActivity.shared.startLyrics(track: track, artist: artist,
                                                      duration: Double(durationMs) / 1000)
            }
        } else if let lyrics = state.lyrics, lines.isEmpty {
            // Server dropped the payload because we said we had it, but a reload
            // cleared ours — take it when it does come back.
            lines = lyrics.lines
            synced = lyrics.synced
        }

        isPlaying = state.playing
        status = state.lyricsUnavailable && state.trackId != nil ? "No lyrics for this track"
               : (state.error == "rate_limited" ? "Spotify is throttling — following on the local clock" : nil)

        // The reading was taken `ageMs` ago on the Pi, plus about half the round
        // trip getting here — but only a *playing* track moved during that time.
        guard let progress = state.progressMs else { return }
        let serverMs = state.playing
            ? Double(progress + state.ageMs) + roundTrip * 500
            : Double(progress)
        // A new song always re-anchors: two tracks can be at the same offset, and
        // then the drift test would silently keep the old song's clock.
        if trackChanged || !running || abs(serverMs - positionMs()) > Self.resyncThresholdMs {
            anchorMs = serverMs
            anchoredAt = Date()
        }
        tick()
    }

    private func positionMs() -> Double {
        isPlaying ? anchorMs + Date().timeIntervalSince(anchoredAt) * 1000 : anchorMs
    }

    private func tick() {
        let position = positionMs()
        // The local clock ran off the end of the song, so Spotify is already on the
        // next one. Waiting out the poll interval would leave the last line of the
        // previous track sitting on the dashboard — this is the most visible way
        // for the lane to look broken, and one extra call per track is cheap.
        // Throttled: the Pi coalesces its own upstream call, so a still-stale answer
        // would otherwise have the 4 Hz ticker asking again every quarter second.
        if running, isPlaying, durationMs > 0, position > Double(durationMs) + 500,
           !endPollPending, Date().timeIntervalSince(lastEndPoll) > 5 {
            endPollPending = true
            lastEndPoll = Date()
            Task { await poll(); endPollPending = false }
        }
        guard synced, !lines.isEmpty else { return }
        // Songs run forwards; start from the current line instead of rescanning.
        var next = index
        while next + 1 < lines.count, Double(lines[next + 1].t) <= position { next += 1 }
        if next == index, index >= 0, Double(lines[index].t) > position {
            next = lines.lastIndex { Double($0.t) <= position } ?? -1   // seeked backwards
        }
        guard next != index else { return }
        index = next
        guard running else { return }
        NowPlayingActivity.shared.updateLyrics(
            track: track, artist: artist,
            line: index >= 0 ? lines[index].text : nil,
            nextLine: index + 1 < lines.count ? lines[index + 1].text : nil,
            elapsed: position / 1000, duration: Double(durationMs) / 1000,
            isPlaying: isPlaying
        )
    }

    private func endpoint(_ path: String) -> URL? {
        serverURL?.appendingPathComponent(path)
    }
}

/// Keeps the process scheduled while Spotify plays.
///
/// A Live Activity can only be updated in-process, and iOS suspends a
/// backgrounded app within seconds — so the lyrics would freeze on whatever line
/// was showing when the user switched to Spotify. The app already declares the
/// `audio` background mode; this holds it open with a mixable stream so Spotify
/// is neither interrupted nor ducked, and Dobby never claims Now Playing.
///
/// The buffer is *near*-silent rather than all zeroes on purpose: iOS reclaims
/// apps that hold an audio session without producing output.
private final class AudioKeepAlive {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // .mixWithOthers is the whole trick: without it, .playback interrupts
        // every other app's audio — i.e. it would stop the music we are following.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        guard let player = try? AVAudioPlayer(data: Self.tone()) else {
            NSLog("%@", "Dobby: lyrics keep-alive could not start; background updates will stall")
            return
        }
        player.numberOfLoops = -1
        player.volume = 0.001
        player.play()
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// One second of 8 kHz mono PCM at the lowest non-zero amplitude, as a WAV in
    /// memory — cheaper than shipping and decoding an asset.
    private static func tone() -> Data {
        let rate = 8000, seconds = 1
        let samples = rate * seconds
        var body = Data(capacity: samples * 2)
        for i in 0..<samples {
            let value: Int16 = i % 2 == 0 ? 1 : -1
            withUnsafeBytes(of: value.littleEndian) { body.append(contentsOf: $0) }
        }
        var wav = Data()
        func append(_ text: String) { wav.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + body.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(rate)); append32(UInt32(rate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(body.count))
        wav.append(body)
        return wav
    }
}
#endif
