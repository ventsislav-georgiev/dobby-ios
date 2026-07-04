import Foundation
import Combine
import KSPlayer

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

    // KSOptions.isAutoPlay is a static (default true); plain options autoplay.
    // automaticWindowResize snaps the macOS window to the video's aspect ratio on
    // readyToPlay (shrinks it); we manage sizing / fullscreen ourselves.
    let options: KSOptions = {
        let o = KSOptions()
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
        if req.isAdaptivePair {
            guard let mpd = Self.writeAdaptivePairMPD(req) else {
                NSLog("%@", "Dobby: ytdlpAdaptive MPD synth failed (missing duration?); reporting fallback ref=\(req.ref)")
                activeRef = req.ref
                lastPositionMs = req.startMs ?? 0
                emit("bookPlayNativePlaybackEnded", completed: false)
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
        currentVideoUrl = req.videoUrl
        resumeSeconds = nil
        // Clear the reused KSPlayer state so the OSD never shows the PREVIOUS video's
        // length / resume position before the new stream reports its own.
        player.timemodel.currentTime = 0
        player.timemodel.totalTime = 1
        player.subtitleModel.subtitleDelay = 0
        // FFmpeg/HTTP layer headers for direct googlevideo / origin streams.
        options.userAgent = AppConfig.streamUserAgent
        options.referer = AppConfig.serverURL.absoluteString
        // Resume: native demuxer seek for the FFmpeg/ME path (MKV etc). AVPlayer (HLS/
        // MP4) ignores this, so onStateChanged also seeks manually at readyToPlay.
        options.startPlayTime = req.startSeconds
        // KSPlayerLayer instantiates KSOptions.firstPlayerType and only falls
        // back to the second on failure. The synthesized MPD is FFmpeg-only,
        // so the default (KSAVPlayer) burns an async AVFoundation failure on
        // every open — including each quality switch. Route per lane instead.
        KSOptions.firstPlayerType = req.isAdaptivePair ? KSMEPlayer.self : KSAVPlayer.self
        activeRef = req.ref
        request = req
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
    }

    func setSubtitleOffset(ref: String, ms: Int) {
        player.subtitleModel.subtitleDelay = Double(ms) / 1000.0
    }

    /// Attach the subtitle tracks carried in the playNative envelope; auto-select a
    /// track only when the web flagged it default (never force subtitles on).
    private func applyInitialSubtitles() {
        guard let subs = request?.subs, !subs.isEmpty else { return }
        var selected: URLSubtitleInfo?
        for t in subs {
            guard let url = subtitleURL(t.url, t.dataBase64, mime: t.mimeType) else { continue }
            let name = t.label ?? t.lang ?? url.lastPathComponent
            let info = URLSubtitleInfo(subtitleID: url.absoluteString, name: name, url: url)
            player.subtitleModel.addSubtitle(info: info)
            if t.isDefault == true { selected = info }
        }
        if let selected { player.subtitleModel.selectedSubtitleInfo = selected }
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
        emit("bookPlayNativePlaybackEnded", completed: false)
        clear()
    }

    func togglePlayPause() {
        guard let layer = player.playerLayer else { return }
        layer.state.isPlaying ? layer.pause() : layer.play()
    }

    func seek(to seconds: TimeInterval) {
        player.seek(time: seconds)
    }

    /// Swap the adaptive pair's video representation (audio stream unchanged):
    /// write a new MPD and let the published URL change reopen the player at
    /// the current position. ytdlpAdaptive-only — HLS quality is AVPlayer ABR.
    func selectQuality(_ option: PlayNativePayload.QualityOption) {
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
            resumeSeconds = nil
        }
    }

    func onProgress(current: TimeInterval, total: TimeInterval) {
        guard current.isFinite, current > 0 else { return }
        lastPositionMs = Int(current * 1000)
        lastDurationMs = Int(max(0, total) * 1000)
        // ponytail: report every ~5s — matches the web's SmartTube save cadence.
        if current - lastReportSec >= 5 {
            lastReportSec = current
            emit("bookPlayNativePlaybackProgress", completed: false)
        }
    }

    func onFinish(error: Error?) {
        mark("finish err=\(error?.localizedDescription ?? "nil")")
        emit("bookPlayNativePlaybackEnded", completed: error == nil)
        clear()
    }

    // MARK: Internals

    private func clear() {
        // Don't resetPlayer() here: it nils playerLayer, and KSVideoPlayer.updateView
        // then sees playerLayer.url != url and recreates+autoplays the layer (infinite
        // loop on finish). Setting request=nil removes the overlay; SwiftUI's
        // dismantleNSView/dismantleUIView calls resetPlayer() for us.
        request = nil
        activeRef = nil
        lastReportSec = 0
        adaptiveManifestURL = nil
        currentVideoUrl = nil
        resumeSeconds = nil
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

    private func emit(_ fn: String, completed: Bool) {
        guard let ref = activeRef else { return }
        let payload: [String: Any] = [
            "ref": ref,
            "positionMs": lastPositionMs,
            "durationMs": lastDurationMs,
            "completed": completed,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        bridge?.callJS("window.\(fn) && window.\(fn)(\(json));")
    }
}
