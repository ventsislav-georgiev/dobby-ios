import Foundation
import Combine
import KSPlayer
import MediaPlayer
import os

#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#else
import AppKit
private typealias PlatformImage = NSImage
#endif

/// Owns native playback. Drives KSPlayer (AVPlayer for HLS/MP4 → keeps PiP/AirPlay/
/// lock-screen; FFmpeg/Metal for DASH/MKV/VP9/AV1). KSPlayer wires Now Playing +
/// remote-command center itself (`registerRemoteControll` defaults true), so media-
/// control resume works without hand-rolled MPNowPlayingInfoCenter code.
@MainActor
final class PlaybackCoordinator: ObservableObject {
    weak var bridge: WebBridge?

    /// Current playback request; non-nil drives the player overlay to appear.
    @Published private(set) var request: PlayNativePayload?
    @Published private(set) var activeRef: String?

    /// Single reused KSPlayer coordinator (the SwiftUI view binds to this).
    let player = KSVideoPlayer.Coordinator()

    /// Car head unit connected? Drives audio-only stream selection.
    let carRoute = CarRoute()

    /// #541: the native remote player this phone shows while it controls another device (the sender).
    let remote = RemotePlayerModel()

    // KSOptions.isAutoPlay is a static (default true); plain options autoplay.
    // automaticWindowResize snaps the macOS window to the video's aspect ratio on
    // readyToPlay (shrinks it); we manage sizing / fullscreen ourselves.
    let options: PreferredTrackOptions = {
        let o = PreferredTrackOptions()
        o.automaticWindowResize = false
        // Render as soon as 2 frames are decoded instead of gating readyToPlay
        // on preferredForwardBufferDuration (3s) of buffered video. The buffer
        // still fills in the background; this only unblocks the first frame.
        o.isSecondOpen = true
        return o
    }()

    private var didSeekToStart = false
    private var lastPositionMs = 0
    private var lastDurationMs = 0
    private var lastReportSec = 0.0
    private var perfLogged = false
    /// #541: the paused state the last tick reported, so a pause or a resume ticks at once.
    private var lastPaused = false

    // Headless e2e: unified log is unreadable from the test sandbox, so when the
    // selftest harness is active we append state transitions to a file the runner
    // can tail. No-op in normal use (env unset). ponytail: test-only hook.
    private static let selftestLog = ProcessInfo.processInfo.environment["DOBBY_SELFTEST_LOG"]
        ?? (ProcessInfo.processInfo.environment["DOBBY_SELFTEST_URL"] != nil
            ? NSTemporaryDirectory() + "dobby-selftest.log" : nil)
    func markSelftest(_ s: String) { mark(s) }
    private func mark(_ s: String) {
        NSLog("%@", "Dobby \(s)")
        guard let path = Self.selftestLog, let data = (s + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    /// Audio-only stream in car mode (adaptive pairs only) — see `play`.
    @Published private(set) var audioOnlyURL: URL?

    /// Local synthesized MPD for the ytdlpAdaptive pair (nil for single-stream).
    /// Published: a quality switch writes a new MPD here and the player view
    /// reopens on the URL change.
    @Published private(set) var adaptiveManifestURL: URL?

    /// Video URL of the currently playing adaptive representation (for the
    /// quality menu's checkmark).
    private(set) var currentVideoUrl: String?

    /// Position to restore after a quality switch reopens the stream.
    private var resumeSeconds: Double?

    var qualityOptions: [PlayNativePayload.QualityOption] { request?.qualityOptions ?? [] }

    /// Resolved playable URL for the current request.
    var playURL: URL? {
        if let audioOnlyURL { return audioOnlyURL }
        if let adaptiveManifestURL { return adaptiveManifestURL }
        guard let req = request else { return nil }
        return (req.url ?? req.videoUrl).flatMap { URL(string: $0) }
    }

    // MARK: Web → native

    func play(_ req: PlayNativePayload) {
        // ytdlpAdaptive = separate video-only + audio-only googlevideo streams. Android
        // muxes them via MergingMediaSource; KSPlayer has no remote-stream muxing, so
        // wrap both in a synthesized static MPD — FFmpeg's dash demuxer fetches and
        // muxes the two single-file representations itself.
        adaptiveManifestURL = nil
        audioOnlyURL = nil
        // Car mode: play the pair's audio representation alone. No video decode means
        // no heat, no battery burn, and playback survives the phone going in a pocket —
        // and the head unit only ever shows Now Playing anyway. Single-stream lanes
        // (HLS/DASH/direct file) carry no separate audio URL, so they are unaffected.
        if req.isAdaptivePair, carRoute.isCar, let audio = req.audioUrl,
           let audioURL = URL(string: audio) {
            audioOnlyURL = audioURL
            mark("car route active — audio-only stream")
        } else if req.isAdaptivePair {
            guard let mpd = Self.writeAdaptivePairMPD(req) else {
                NSLog("%@", "Dobby: ytdlpAdaptive MPD synth failed (missing duration?); reporting fallback ref=\(req.ref)")
                activeRef = req.ref
                lastPositionMs = req.startMs ?? 0
                emit("dobbyNativePlaybackEnded", completed: false)
                activeRef = nil
                return
            }
            adaptiveManifestURL = mpd
            mark("adaptive-pair via synthesized MPD \(mpd.lastPathComponent)")
        }
        guard (req.url ?? req.videoUrl) != nil else {
            NSLog("%@", "Dobby: play missing url ref=\(req.ref)")
            return
        }
        didSeekToStart = false
        lastPositionMs = req.startMs ?? 0
        lastDurationMs = 0
        lastReportSec = 0
        lastPaused = false
        currentVideoUrl = req.videoUrl
        resumeSeconds = nil
        attached = []
        // Clear the reused KSPlayer state so the OSD never shows the PREVIOUS video's
        // length / resume position before the new stream reports its own.
        player.timemodel.currentTime = 0
        player.timemodel.totalTime = 1
        player.subtitleModel.subtitleDelay = 0
        // #537: KSPlayer edits these per track on the options it is handed (KSOptions.process:
        // interlaced turns hardwareDecode off and appends yadif; MEPlayerItem: rotation turns it off
        // and appends transpose), and this one object serves every open. One interlaced title left
        // every later title of the session decoding in software behind a stale deinterlacer.
        options.hardwareDecode = KSOptions.hardwareDecode
        options.asynchronousDecompression = KSOptions.asynchronousDecompression
        options.videoFilters = []
        #if os(iOS)
        // #537: KSPlayer asks its display link for fps..2*fps (24..48, preferred 24, at 23.976 fps).
        // On a 120 Hz iPhone that link fired about 14 times a second, a frame per call, so the picture
        // ran at 14 fps and fell a second behind the audio. With it off KSPlayer never touches the
        // link's range, and readyToPlay sets it to 120 Hz (Self.fastDisplayLink) so 24 fps lands on
        // an even five refreshes a frame instead of 60 Hz 3:2 (33/50 ms). Each call picks the frame
        // by the audio clock; most return early.
        KSOptions.preferredFrame = false
        RenderProbe.beforeOpen()   // #537: selftest-only experiment switches, inert otherwise
        #endif
        // FFmpeg/HTTP layer headers for direct googlevideo / origin streams.
        options.userAgent = AppConfig.streamUserAgent
        options.referer = AppConfig.serverURL?.absoluteString
        // Resume: native demuxer seek for the FFmpeg/ME path (MKV etc). AVPlayer (HLS/
        // MP4) ignores this, so onStateChanged also seeks manually at readyToPlay.
        options.startPlayTime = req.startSeconds
        options.audioPriority = TrackPreference.priority(req.preferredAudioLang, deviceLanguage: Self.deviceLanguage)
        // #586: KSPlayer's own fallback (the first enabled embedded track, a second after
        // readyToPlay) is an auto-pick too, so it runs only in on mode. Set per open: one shared object.
        options.autoSelectEmbedSubtitle = SubtitleMode(req.subtitleMode) == .on
        // KSPlayerLayer instantiates KSOptions.firstPlayerType and only falls
        // back to the second on failure. The synthesized MPD is FFmpeg-only,
        // so the default (KSAVPlayer) burns an async AVFoundation failure on
        // every open — including each quality switch. Route per lane instead.
        KSOptions.firstPlayerType = req.isAdaptivePair ? KSMEPlayer.self : KSAVPlayer.self
        activeRef = req.ref
        request = req
        loadArtwork(req)
        mark("play ref=\(req.ref) start=\(req.startSeconds)s url=\(req.url ?? req.videoUrl ?? "-")")
    }

    func attachSubtitle(_ json: String) {
        guard let p = AttachSubtitlePayload.decode(json),
              let url = subtitleURL(p.url, p.dataBase64, mime: p.mimeType) else {
            NSLog("Dobby attachSubtitle bad payload")
            return
        }
        let name = p.label ?? p.lang ?? url.lastPathComponent
        let info = URLSubtitleInfo(subtitleID: url.absoluteString, name: name, url: url)
        player.subtitleModel.addSubtitle(info: info)
        player.subtitleModel.selectedSubtitleInfo = info
        if let cid = p.catalogId { attachedCatalogIds.insert(cid) }
    }

    /// Online-subtitle catalog pushed by the web (same contract as the Android
    /// wrapper's setSubtitleCatalog). Entries render as pick-to-download rows in
    /// the native subtitles menu.
    @Published private(set) var subtitleCatalog: [SubtitleCatalogEntry] = []
    /// Catalog ids already fetched+attached — hidden from the catalog rows.
    @Published private(set) var attachedCatalogIds: Set<String> = []

    func setSubtitleCatalog(_ json: String) {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([SubtitleCatalogEntry].self, from: data) else {
            NSLog("Dobby setSubtitleCatalog bad payload")
            return
        }
        subtitleCatalog = items
    }

    /// Ask the web layer to download a catalog subtitle; it responds with attachSubtitle.
    func requestCatalogSubtitle(id: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["catalogId": id]),
              let json = String(data: data, encoding: .utf8) else { return }
        bridge?.callJS("window.dobbyNativeRequestSubtitle && window.dobbyNativeRequestSubtitle(\(json));")
    }

    /// Post {ref, positionMs} to the page's window.dobbyNativeBookmarkRequest (Android
    /// requestBookmark :7268-7284); the page saves the bookmark against its active video. The
    /// caller (PlayerControls.bookmark) already checked allowBookmarks and shows the toast.
    func requestBookmark() {
        guard let ref = activeRef else { return }
        let live = player.playerLayer?.player.currentPlaybackTime ?? 0
        let positionMs = live.isFinite && live > 0 ? Int(live * 1000) : lastPositionMs
        guard let json = Self.json(["ref": ref, "positionMs": positionMs]) else { return }
        bridge?.callJS("window.dobbyNativeBookmarkRequest && window.dobbyNativeBookmarkRequest(\(json));")
        mark("bookmark ref=\(ref) positionMs=\(positionMs)")
    }

    func setSubtitleOffset(ref: String, ms: Int) {
        player.subtitleModel.subtitleDelay = Double(ms) / 1000.0
    }

    /// Attach the subtitle tracks carried in the playNative envelope; auto-select a
    /// track only when the web flagged it default (applyPreferredTracks, right after, may
    /// override it with a preferred-language track). #586: the flag is an auto-pick too, so only in
    /// on mode; forced and off leave the choice to applyPreferredTracks.
    private func applyInitialSubtitles() {
        guard let subs = request?.subs, !subs.isEmpty else { return }
        var selected: URLSubtitleInfo?
        for t in subs {
            guard let url = subtitleURL(t.url, t.dataBase64, mime: t.mimeType) else { continue }
            let name = t.label ?? t.lang ?? url.lastPathComponent
            let info = URLSubtitleInfo(subtitleID: url.absoluteString, name: name, url: url)
            player.subtitleModel.addSubtitle(info: info)
            attached.append((info, t.lang))
            if t.isDefault == true { selected = info }
        }
        if let selected, SubtitleMode(request?.subtitleMode) == .on { player.subtitleModel.selectedSubtitleInfo = selected }
    }

    /// The payload's subtitle tracks as attached on first open, with their languages.
    private var attached: [(info: URLSubtitleInfo, lang: String?)] = []

    private static var deviceLanguage: String? { Locale.current.language.languageCode?.identifier }

    /// E8 (#473), first open only. Start on the preferred audio language (MEPlayer already
    /// opened on it through PreferredTrackOptions.wantedAudio; this covers the AVPlayer lane)
    /// and on the first track in the preferred subtitle languages, embedded before attached
    /// (Android selectDefaultSubtitleIfNeeded: a preferred-language track beats DEFAULT flags,
    /// and an online catalog entry is never downloaded just to have one). Then report the
    /// embedded subtitle languages to window.dobbyNativeSubtitleTracks (Android
    /// emitEmbeddedSubtitleTracks), so the page only auto-attaches an online subtitle when
    /// embedded lacks the preferred language.
    private func applyPreferredTracks() {
        guard let req = request, let p = player.playerLayer?.player else { return }
        let audio = p.tracks(mediaType: .audio)
        if let i = TrackPreference.pick(audio.map(\.languageCode), priority: options.audioPriority),
           !audio[i].isEnabled {
            p.select(track: audio[i])
        }

        let embedded = p.tracks(mediaType: .subtitle)
        // AVPlayer's legible tracks are not SubtitleInfo; they are reported, never picked here.
        // #586 forced marking: KSPlayer keeps an image track enabled at open only when its stream is
        // flagged forced (FFmpegAssetTrack); a text track or side-loaded file says so only in its title.
        let pickable: [(info: any SubtitleInfo, lang: String?, forced: Bool)] =
            embedded.compactMap { t in
                (t as? any SubtitleInfo).map { ($0, t.languageCode, (t.isImageSubtitle && t.isEnabled) || TrackPreference.isForcedLabel(t.name)) }
            }
            + attached.map { ($0.info, $0.lang, TrackPreference.isForcedLabel($0.info.name)) }
        let mode = SubtitleMode(req.subtitleMode)
        let subPriority = TrackPreference.priority(req.preferredSubtitleLang, deviceLanguage: Self.deviceLanguage)
        var selectedLang: String?
        // A track the page flagged default (the offline sidecar the user picked, #228) stands.
        let pageFlagged = mode == .on && (req.subs?.contains { $0.isDefault == true } ?? false)
        if !pageFlagged, let i = TrackPreference.pickSubtitle(pickable.map { $0.lang }, forced: pickable.map { $0.forced },
                                                             priority: subPriority, mode: mode) {
            player.subtitleModel.selectedSubtitleInfo = pickable[i].info
            if i < pickable.count - attached.count { selectedLang = TrackPreference.normalize(pickable[i].lang) }
        }

        var langs: [String] = []
        for t in embedded {
            let l = TrackPreference.normalize(t.languageCode) ?? "und"
            if !langs.contains(l) { langs.append(l) }
        }
        var report: [String: Any] = ["ref": req.ref, "langs": langs]
        if let selectedLang { report["selectedLang"] = selectedLang }
        guard let json = Self.json(report) else { return }
        bridge?.callJS("window.dobbyNativeSubtitleTracks && window.dobbyNativeSubtitleTracks(\(json));")
        mark("subtitle tracks mode=\(mode.rawValue) langs=\(langs) selected=\(selectedLang ?? "-") audio=\(audio.first { $0.isEnabled }?.languageCode ?? "-")")
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Resolve a subtitle to a URL: remote/file URL as-is, or base64 written to a temp file.
    private func subtitleURL(_ urlStr: String?, _ base64: String?, mime: String?) -> URL? {
        if let urlStr, let url = URL(string: urlStr) { return url }
        guard let base64 else { return nil }
        let raw = base64.contains(",") ? String(base64.split(separator: ",", maxSplits: 1).last ?? "") : base64
        guard let data = Data(base64Encoded: raw) else { return nil }
        let ext = subtitleExt(mime)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dobby-sub-\(abs(raw.hashValue)).\(ext)")
        do { try data.write(to: file); return file } catch { return nil }
    }

    private func subtitleExt(_ mime: String?) -> String {
        let m = (mime ?? "").lowercased()
        if m.contains("vtt") { return "vtt" }
        if m.contains("ass") || m.contains("ssa") { return "ass" }
        return "srt"
    }

    /// Web-initiated stop, or user closed the overlay. Reports a non-final position.
    func stop() {
        guard activeRef != nil else { return }
        emit("dobbyNativePlaybackEnded", completed: false)
        clear()
    }

    /// #541: window.Dobby.remoteCommand, the hub's command for this film (RemoteControl.run, which ticks after).
    func remoteCommand(_ json: String) {
        guard activeRef != nil else { mark("remote command ignored: nothing playing"); return }
        let result = RemoteControl.run(json, on: self)
        mark("remote command \(RemoteCommand.parse(json).map { "\($0)" } ?? "unparsed") -> \(result)")
    }

    func togglePlayPause() {
        guard let layer = player.playerLayer else { return }
        layer.state.isPlaying ? layer.pause() : layer.play()
    }

    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "playback")

    /// Seeks and observes the KSPlayer result, logging (never surfacing to the
    /// UI — see #117's review HOLD) the one case where the seek is genuinely
    /// dropped rather than merely deferred.
    ///
    /// KSPlayerLayer.seek(time:autoPlay:completion:) (KSPlayerLayer.swift:332-349
    /// in the vendored checkout) calls `completion(false)` from two places:
    ///   - :333-334 `time.isInfinite || time.isNaN` — this call does NOT
    ///     `return`, so a non-finite target falls through into :336 and can
    ///     call `completion` a second time; guarded below so the coordinator
    ///     never hands KSPlayerLayer a value that can double-fire.
    ///   - :344-347, the `else` of `if player.isReadyToPlay, player.seekable`,
    ///     which ALWAYS reports false, for two different reasons:
    ///       - CASE A, `!isReadyToPlay`: KSPlayerLayer stashes `shouldSeekTo`
    ///         and replays it once ready (readyToPlay(player:), :382-391) — no
    ///         restore here, or the knob would jump to a stale live value only
    ///         to be corrected again moments later, which is worse than
    ///         today's silence. Exception: readyToPlay only replays
    ///         `shouldSeekTo > 0` (:383), so a target of exactly 0 is silently
    ///         dropped even in this case — treated like CASE B below.
    ///       - CASE B, `isReadyToPlay && !seekable`: readyToPlay(player:) has
    ///         already fired and nothing reads `shouldSeekTo` again, so this
    ///         seek never happens — log it.
    /// When `isReadyToPlay && seekable` are both true, KSPlayerLayer forwards
    /// the real player's own completion (:337-343) instead; a `false` there
    /// (the underlying seek was superseded by a newer one) is treated like
    /// CASE A — silent — since whatever superseded it is already correcting
    /// the position.
    ///
    /// `autoPlay: layer.options.isSeekedAutoPlay` (not `layer.state.isPlaying`)
    /// matches the old convenience `seek(time:)` (KSPlayerLayer.swift:540-543)
    /// in BOTH branches: the else branch stashes it into `isAutoPlay`, and
    /// `readyToPlay(player:)` (:382) only calls `play()`/replays the deferred
    /// seek when `isAutoPlay` is true. `layer.state.isPlaying` is
    /// `.buffering || .bufferFinished` and is never true pre-ready (the layer
    /// sits in `.preparing`), so it would silently break autostart-after-seek
    /// and the CASE A replay for every seek issued before ready — not #117's
    /// bug to introduce.
    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, let layer = player.playerLayer else {
            if !seconds.isFinite {
                Self.log.info("seek rejected non-finite target=\(seconds, privacy: .public)")
            }
            return
        }
        let wasReadyToPlay = layer.player.isReadyToPlay
        let wasSeekable = layer.player.seekable
        layer.seek(time: seconds, autoPlay: layer.options.isSeekedAutoPlay) { [weak self] finished in
            guard let self, !finished else { return }
            let dropped = (wasReadyToPlay && !wasSeekable) || (!wasReadyToPlay && seconds == 0)
            if dropped {
                let live = self.player.timemodel.currentTime
                Self.log.info("seek dropped target=\(seconds, privacy: .public)s live=\(live, privacy: .public)s")
            }
        }
    }

    /// Swap the adaptive pair's video representation (audio stream unchanged):
    /// write a new MPD and let the published URL change reopen the player at
    /// the current position. ytdlpAdaptive-only — HLS quality is AVPlayer ABR.
    func selectQuality(_ option: PlayNativePayload.QualityOption) {
        guard audioOnlyURL == nil else { return }   // no video stream to switch in car mode
        guard let req = request, req.isAdaptivePair,
              let videoUrl = option.videoUrl, videoUrl != currentVideoUrl,
              let mpd = Self.writeAdaptivePairMPD(
                  req,
                  videoUrl: videoUrl,
                  videoMimeType: option.videoMimeType,
                  fileSuffix: "-h\(option.height ?? 0)"
              ) else { return }
        let position = Double(player.timemodel.currentTime)
        currentVideoUrl = videoUrl
        resumeSeconds = position
        didSeekToStart = false
        options.startPlayTime = position
        adaptiveManifestURL = mpd
        mark("quality switch \(option.label ?? "?") pos=\(Int(position))s")
    }

    // MARK: KSPlayer callbacks (wired from PlayerView)

    func onStateChanged(_ state: KSPlayerState) {
        mark("state=\(state)")
        // #541: a pause or a resume, from any source, reaches a remote sender at once. From the state handed in:
        // the layer's own state still reads the old value inside this callback (measured, a pause ticked paused=false).
        if didSeekToStart, (state == .paused) != lastPaused { remoteTick(paused: state == .paused) }
        if state == .readyToPlay {
            // #132: log which engine actually opened the stream. firstPlayerType above is
            // only a request - KSPlayerLayer silently swaps to KSOptions.secondPlayerType
            // (KSMEPlayer) when the first player fails to open, so a device round gating a
            // KSPlayer revision move has to READ the engine, never infer it from the lane.
            let engine = player.playerLayer.map { String(describing: type(of: $0.player)) } ?? "?"
            mark("engine=\(engine) adaptive=\(request?.isAdaptivePair ?? false)")
            perfLogged = false   // #537: the perf line follows on the first tick with a frame on screen
            #if os(iOS)
            RenderProbe.start(player: { [weak self] in self?.player.playerLayer?.player }, owner: self, web: bridge?.webView) { [weak self] in self?.mark($0) }
            mark(Self.fastDisplayLink(player.playerLayer?.player))
            #endif
        }
        if state == .readyToPlay, !didSeekToStart {
            didSeekToStart = true
            let start = resumeSeconds ?? request?.startSeconds ?? 0
            // The adaptive pair plays on MEPlayer, which already seeked to
            // options.startPlayTime at open (avformat_seek_file in readThread);
            // seeking again here flushes and re-buffers. Manual seek is only
            // for the AVPlayer lane, which ignores startPlayTime.
            if start > 1, !(request?.isAdaptivePair ?? false) { player.seek(time: start) }
            // Only on first open — a quality switch keeps the subtitleModel
            // (it lives on the coordinator), re-adding would duplicate tracks.
            if resumeSeconds == nil { applyInitialSubtitles() }
            if resumeSeconds == nil { applyPreferredTracks() }
            resumeSeconds = nil
            configureRemoteCommands()   // after KSPlayer's own registration on this layer
            #if os(iOS)
            let started = NowPlayingActivity.shared.start(
                title: request?.title ?? "Dobby",
                subtitle: request?.artist ?? request?.album ?? "",
                kind: "video",
                elapsed: Double(player.timemodel.currentTime),
                duration: Double(player.timemodel.totalTime),
                isLive: request?.isLive ?? false
            )
            mark("liveactivity started=\(started)")
            #endif
        }
        applyNowPlaying()
    }

    // MARK: - Now Playing (lock screen, Control Center, car head unit)

    /// KSPlayer fills duration/elapsed and only takes a title when the *stream* carries one —
    /// direct stream and YouTube URLs carry none, so the car shows a blank card. Merge in the title
    /// and poster the web app already sent us. Merging (never replacing) keeps KSPlayer's keys.
    private var nowPlayingArtwork: MPMediaItemArtwork?

    private func applyNowPlaying() {
        guard let req = request else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let title = req.title { info[MPMediaItemPropertyTitle] = title }
        if let artist = req.artist, !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let album = req.album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = artwork }
        // Audio, not video: a `.video` media type makes CarPlay and the lock screen
        // treat the card as a video the head unit refuses to show. Dobby's car story
        // is listening, so declare audio and keep a full Now Playing card everywhere.
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = req.isLive ?? false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        mark("nowplaying title=\(info[MPMediaItemPropertyTitle] ?? "-") "
            + "artist=\(info[MPMediaItemPropertyArtist] ?? "-") "
            + "album=\(info[MPMediaItemPropertyAlbumTitle] ?? "-") "
            + "artwork=\(info[MPMediaItemPropertyArtwork] != nil) "
            + "mediaType=\(info[MPNowPlayingInfoPropertyMediaType] ?? "-")")
    }

    /// KSPlayer's `registerRemoteControllEvent()` runs on every layer creation and wires
    /// next/previous track to its playlist API — Dobby has no playlist, so the car and
    /// lock screen show two dead buttons. Disable them (skip ±30 s takes their slots,
    /// matching the web player's `seekRel(±30)`; KSPlayer's own default is 15 s).
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [30]
        mark("remotecommands next=\(center.nextTrackCommand.isEnabled) "
            + "prev=\(center.previousTrackCommand.isEnabled) "
            + "skipFwd=\(center.skipForwardCommand.preferredIntervals) "
            + "skipBack=\(center.skipBackwardCommand.preferredIntervals) "
            + "carRoute=\(carRoute.isCar)")
    }

    private func loadArtwork(_ req: PlayNativePayload) {
        nowPlayingArtwork = nil
        guard let poster = req.poster, let url = URL(string: poster) else { return }
        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let image = PlatformImage(data: data) else { return }
            await MainActor.run {
                guard let self, self.activeRef == req.ref else { return }   // a later play() won the race
                self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.applyNowPlaying()
            }
        }
    }

    func onProgress(current: TimeInterval, total: TimeInterval) {
        guard current.isFinite, current > 0 else { return }
        if !perfLogged, let line = perfLine() { perfLogged = true; mark(line) }
        lastPositionMs = Int(current * 1000)
        lastDurationMs = Int(max(0, total) * 1000)
        #if os(iOS)
        // Self-throttled to one push per 15 s — the widget runs its own clock between them.
        NowPlayingActivity.shared.update(
            title: request?.title ?? "Dobby",
            subtitle: request?.artist ?? request?.album ?? "",
            elapsed: current, duration: total,
            isLive: request?.isLive ?? false,
            isPlaying: player.playerLayer?.state.isPlaying ?? true
        )
        #endif
        // ponytail: report every ~5s — matches the web's SmartTube save cadence. abs: after a seek back
        // the reports must not wait until the film is past the old place again (#541).
        if abs(current - lastReportSec) >= 5 {
            lastReportSec = current
            remoteTick()
        }
    }

    /// #537: once per open, whether the picture is decoded in hardware, and the device state that
    /// throttles a decode. Not at readyToPlay: no frame is on screen yet there. decode= reads the
    /// pixel format of the frame on screen: VideoToolbox (FFmpeg's hwaccel or KSPlayer's own
    /// session) hands out bi-planar 4:2:0, FFmpeg's software path planar y420 (no CVPixelBuffer at
    /// all above 8 bits), AVPlayer always decodes in hardware. hwOpt is KSOptions.hardwareDecode
    /// after KSPlayer's per-track edits. No URL, host or source name. nil until a frame is shown.
    private func perfLine() -> String? {
        let p = player.playerLayer?.player
        let v = p?.tracks(mediaType: .video).first { $0.isEnabled }
        var decode = p is KSAVPlayer ? "avplayer" : "none"
        if let me = p as? KSMEPlayer, v != nil {
            guard let pb = me.videoOutput?.pixelBuffer else { return nil }
            let pix = pb.cvPixelBuffer.map { Self.fourCC(CVPixelBufferGetPixelFormatType($0)) } ?? "none"
            decode = (["420v", "420f", "x420", "xf20"].contains(pix) ? "hw" : "sw") + " pix=" + pix
        }
        let sz = p?.naturalSize ?? .zero
        let info = ProcessInfo.processInfo
        return "perf codec=\(Self.fourCC(v?.codecType ?? 0)) size=\(Int(sz.width))x\(Int(sz.height))"
            + " fps=\(String(format: "%.3f", v?.nominalFrameRate ?? 0)) decode=\(decode)"
            + " hwOpt=\(options.hardwareDecode) thermal=\(info.thermalState.rawValue) lowPower=\(info.isLowPowerModeEnabled)"
    }

    #if os(iOS)
    /// #537: KSMEPlayer's display link, KSPlayer keeps it private and Mirror reads the stored
    /// property (no fork). nil on the AVPlayer lane, which presents on its own.
    nonisolated static func playerDisplayLink(_ p: MediaPlayerProtocol?) -> CADisplayLink? {
        guard let v = (p as? KSMEPlayer)?.videoOutput else { return nil }
        return Mirror(reflecting: v).children.first { $0.label == "displayLink" }?.value as? CADisplayLink
    }

    /// #537: the link's 120 Hz range, set on every open (a new KSMEPlayer has a new link). At the
    /// default 60 Hz a 23.976 fps film shows 3:2 judder, frames held 33 and 50 ms in turn. At 120 Hz
    /// each frame holds five refreshes (42 ms) and 25/30/60 fps land evenly or within one refresh.
    /// Needs CADisableMinimumFrameDurationOnPhone in Info.plist; a 60 Hz screen or Low Power Mode
    /// clamps it to 60, today's behaviour. The returned line names the lane and the panel maximum.
    static func fastDisplayLink(_ p: MediaPlayerProtocol?) -> String {
        guard p is KSMEPlayer else { return "link=none" }
        guard let l = playerDisplayLink(p) else { return "link=missing" }
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, __preferred: 120)
        return "link=120 screenMax=\(UIScreen.main.maximumFramesPerSecond)"
    }
    #endif

    private static func fourCC(_ c: UInt32) -> String {
        let s = String(bytes: (0..<4).map { UInt8((c >> (24 - 8 * $0)) & 0xff) }, encoding: .ascii) ?? ""
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? "none" : s
    }

    /// The natural end, or #560's Next episode (SkipOverlay.swift) with `next: true` for the page.
    func onFinish(error: Error?, next: Bool = false) {
        mark("finish err=\(error?.localizedDescription ?? "nil")\(next ? " next" : "")")
        emit("dobbyNativePlaybackEnded", completed: error == nil, extra: next ? ["next": true] : [:])
        clear()
    }

    // MARK: Internals

    private func clear() {
        // Don't resetPlayer() here: it nils playerLayer, and KSVideoPlayer.updateView
        // then sees playerLayer.url != url and recreates+autoplays the layer (infinite
        // loop on finish). Setting request=nil removes the overlay; SwiftUI's
        // dismantleNSView/dismantleUIView calls resetPlayer() for us.
        #if os(iOS)
        RenderProbe.stop(web: bridge?.webView)
        #endif
        request = nil
        activeRef = nil
        lastReportSec = 0
        adaptiveManifestURL = nil
        audioOnlyURL = nil
        currentVideoUrl = nil
        resumeSeconds = nil
        subtitleCatalog = []
        attachedCatalogIds = []
        attached = []
        nowPlayingArtwork = nil
        #if os(iOS)
        NowPlayingActivity.shared.end()
        #endif
    }

    /// Static single-Period MPD wrapping the ytdlpAdaptive video+audio URLs.
    /// Each Representation is one whole-file BaseURL (no SegmentBase) — FFmpeg's
    /// dash demuxer probes and streams such representations progressively.
    private static func writeAdaptivePairMPD(
        _ req: PlayNativePayload,
        videoUrl videoOverride: String? = nil,
        videoMimeType videoMimeOverride: String? = nil,
        fileSuffix: String = ""
    ) -> URL? {
        guard let videoUrl = videoOverride ?? req.videoUrl, let audioUrl = req.audioUrl,
              let durationMs = req.durationMs, durationMs > 0 else { return nil }
        let videoMime = videoMimeOverride ?? req.videoMimeType

        func xmlEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        // "video/mp4; codecs=\"avc1.64002a\"" → ("video/mp4", "avc1.64002a")
        func splitMime(_ raw: String?, fallback: String) -> (mime: String, codecs: String?) {
            guard let raw, !raw.isEmpty else { return (fallback, nil) }
            let parts = raw.split(separator: ";", maxSplits: 1)
            let mime = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? fallback
            var codecs: String?
            if parts.count > 1, let range = parts[1].range(of: "codecs=") {
                codecs = parts[1][range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            return (mime, codecs)
        }
        func adaptationSet(_ raw: String?, fallback: String, id: String, bandwidth: Int, url: String) -> String {
            let (mime, codecs) = splitMime(raw, fallback: fallback)
            let codecAttr = codecs.map { " codecs=\"\($0)\"" } ?? ""
            return """
                <AdaptationSet mimeType="\(mime)"\(codecAttr)>
                  <Representation id="\(id)" bandwidth="\(bandwidth)">
                    <BaseURL>\(xmlEscape(url))</BaseURL>
                  </Representation>
                </AdaptationSet>
            """
        }

        let duration = String(format: "PT%.3fS", Double(durationMs) / 1000.0)
        let mpd = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" \
        mediaPresentationDuration="\(duration)" minBufferTime="PT2S" \
        profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
          <Period duration="\(duration)">
        \(adaptationSet(videoMime, fallback: "video/mp4", id: "video", bandwidth: 4_000_000, url: videoUrl))
        \(adaptationSet(req.audioMimeType, fallback: "audio/mp4", id: "audio", bandwidth: 128_000, url: audioUrl))
          </Period>
        </MPD>
        """
        // Suffix keeps quality-switch MPDs at distinct paths — KSVideoPlayer only
        // reopens when the URL actually changes.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dobby-adaptive-\(abs(req.ref.hashValue))\(fileSuffix).mpd")
        guard let data = mpd.data(using: .utf8) else { return nil }
        do { try data.write(to: file) } catch {
            NSLog("Dobby: MPD write failed: \(error.localizedDescription)")
            return nil
        }
        return file
    }

    private func emit(_ fn: String, completed: Bool, extra: [String: Any] = [:]) {
        guard let ref = activeRef else { return }
        let payload: [String: Any] = [
            "ref": ref,
            "positionMs": lastPositionMs,
            "durationMs": lastDurationMs,
            "completed": completed,
        ].merging(extra) { base, _ in base }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        bridge?.callJS("window.\(fn) && window.\(fn)(\(json));")
    }
}

// MARK: - #541 receiver: the hub's commands, relayed by the PWA (RemoteControl.swift)

extension PlaybackCoordinator: RemoteTarget {
    var remotePosition: Double {
        let live = player.playerLayer?.player.currentPlaybackTime ?? .nan
        return live.isFinite ? live : Double(lastPositionMs) / 1000
    }

    var remoteDuration: Double {
        let d = player.playerLayer?.player.duration ?? .nan
        return d.isFinite && d > 0 ? d : Double(lastDurationMs) / 1000
    }

    var remotePaused: Bool { player.playerLayer?.state == .paused }
    func remotePlay() { player.playerLayer?.play() }
    func remotePause() { player.playerLayer?.pause() }

    /// The tick right after reports the target: the seek itself lands a moment later. A paused film stays paused,
    /// as the web player's does: seek(to:) passes the options' isSeekedAutoPlay, read once at the call.
    func remoteSeek(to seconds: Double) {
        lastPositionMs = Int(seconds * 1000)
        let autoPlay = options.isSeekedAutoPlay
        if remotePaused { options.isSeekedAutoPlay = false }
        seek(to: seconds)
        options.isSeekedAutoPlay = autoPlay
    }

    /// Ids are the rows of the player's own lists, labels the native sheets' (AudioSheet, SubtitleSheet), so a
    /// sender picks what a tap on that row picks here; subtitle "off" is a row of its own. The online catalog's
    /// rows are left out: they are not tracks until the page downloads one.
    func remoteTracks(_ kind: RemoteTrackKind) -> [RemoteTrack] {
        switch kind {
        case .audio:
            let tracks = player.playerLayer?.player.tracks(mediaType: .audio) ?? []
            return tracks.enumerated().map { i, t in
                RemoteTrack(id: "\(i)", label: PlayerControls.audioLabel(t, index: i), selected: t.isEnabled)
            }
        case .subtitle:
            let model = player.subtitleModel
            let on = model.selectedSubtitleInfo?.subtitleID
            return [RemoteTrack(id: "off", label: "Off", selected: on == nil)]
                + model.subtitleInfos.enumerated().map { i, info in
                    RemoteTrack(id: "\(i)", label: PlayerControls.subtitleLabel(info), selected: info.subtitleID == on)
                }
        }
    }

    func remoteSelect(_ kind: RemoteTrackKind, id: String) {
        switch kind {
        case .audio:
            let tracks = player.playerLayer?.player.tracks(mediaType: .audio) ?? []
            if let i = Int(id), tracks.indices.contains(i) { player.playerLayer?.player.select(track: tracks[i]) }
        case .subtitle:
            let infos = player.subtitleModel.subtitleInfos
            if id == "off" { player.subtitleModel.selectedSubtitleInfo = nil }
            else if let i = Int(id), infos.indices.contains(i) { player.subtitleModel.selectedSubtitleInfo = infos[i] }
        }
    }

    /// window.dobbyNativePlaybackProgress with paused and tracks: the 5 s tick, and at once after a command,
    /// a pause or a resume (protocol.md). It restarts the 5 s count.
    func remoteTick() { remoteTick(paused: remotePaused) }

    func remoteTick(paused: Bool) {
        lastPaused = paused
        lastReportSec = Double(lastPositionMs) / 1000
        let audio = remoteTracks(.audio), subtitle = remoteTracks(.subtitle)
        emit("dobbyNativePlaybackProgress", completed: false,
             extra: ["paused": paused, "tracks": RemoteControl.tracksPayload(audio: audio, subtitle: subtitle)])
        if Self.selftestLog != nil {
            let rows = { (l: [RemoteTrack]) in l.map { "\($0.id):\($0.label)\($0.selected ? "*" : "")" }.joined(separator: "|") }
            mark("tick paused=\(paused) posMs=\(lastPositionMs) durMs=\(lastDurationMs) audio=[\(rows(audio))] subtitle=[\(rows(subtitle))]")
        }
    }
}

/// MEPlayer asks for its audio stream at open; answering here starts on the preferred
/// language without the seek a later select(track:) costs. Set per play() on the main actor
/// before the layer opens, read on KSPlayer's open thread.
final class PreferredTrackOptions: KSOptions {
    var audioPriority: [String] = []

    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        TrackPreference.pick(tracks.map(\.languageCode), priority: audioPriority)
    }
}
