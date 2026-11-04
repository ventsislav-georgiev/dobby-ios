#if DEBUG
import Foundation
import WebKit

/// Debug-only simulator seam for #541, the remote control, through the real WKWebView bridge. The environment
/// picks one of two fixed modes and nothing else; every step is written to the selftest log (markSelftest), and a
/// "shot <name>" line is the host's cue to take a screenshot (it then has 2.5 s).
/// - `receiver` (with DOBBY_SELFTEST_URL playing a local file): the PWA's own hubNativeCommand, the function a hub
///   command reaches, sends pause, seek, skip, play, toggle, an audio and a subtitle pick, a stale id that the label
///   re-check resolves, and an unknown track, each through window.Dobby.remoteCommand. Each tick logs paused, pos
///   and tracks (PlaybackCoordinator.remoteTick).
/// - `sender`: the PWA's own hubRemoteStart opens the native remote player through openRemotePlayer, a fake target
///   state goes in through hubRemoteSync, every control of the player is pressed (its dobbyRemoteControl call and
///   the page's answer are logged), then close (the mini bar), reopen, and hubRemoteEnd (remotePlayerState ended).
///   hubRemoteNext is stubbed first, so Next is recorded without starting a source search.
enum RemoteSelfTest {
    private static var ran = false

    @MainActor
    static func run(_ mode: String, web: WKWebView?, playback: PlaybackCoordinator) {
        guard ["receiver", "sender"].contains(mode), !ran, let web else { return }
        ran = true
        Task { @MainActor in
            if mode == "receiver" { await receiver(web, playback) } else { await sender(web, playback) }
            playback.markSelftest("remote selftest \(mode) done")
        }
    }

    @MainActor
    private static func js(_ web: WKWebView, _ p: PlaybackCoordinator, _ source: String) async {
        let result = try? await web.evaluateJavaScript(source)
        p.markSelftest("js \(source.prefix(160)) -> \(result.map { "\($0)" } ?? "nil")")
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private static func json(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    @MainActor
    private static func command(_ web: WKWebView, _ p: PlaybackCoordinator, _ cmd: String, _ args: [String: Any]) async {
        await js(web, p, "hubNativeCommand('\(cmd)', \(json(args)))")
        await wait(2.5)
    }

    @MainActor
    private static func receiver(_ web: WKWebView, _ p: PlaybackCoordinator) async {
        for _ in 0..<120 where !(p.player.playerLayer?.player.isReadyToPlay ?? false) { await wait(0.5) }
        await wait(6)
        p.markSelftest("shot receiver-playing")
        await wait(2.5)
        await command(web, p, "pause", [:])
        p.markSelftest("shot receiver-paused")
        await wait(2.5)
        await command(web, p, "seek", ["pos": 20])
        await command(web, p, "skip", ["delta": -5])
        await command(web, p, "skip", ["delta": 15])
        await command(web, p, "play", [:])
        await command(web, p, "toggle", [:])
        await command(web, p, "toggle", [:])
        if let a = p.remoteTracks(.audio).first(where: { !$0.selected }) {
            await command(web, p, "audio", ["track": a.id, "label": a.label])
        }
        let subs = p.remoteTracks(.subtitle)
        if let s = subs.last(where: { $0.id != "off" }) {
            await command(web, p, "subtitle", ["track": s.id, "label": s.label])
            p.markSelftest("shot receiver-subtitle")
            await wait(2.5)
            // A stale id: row "0" no longer carries the label "Off"; the label re-check picks off.
            await command(web, p, "subtitle", ["track": "0", "label": "Off"])
        }
        await command(web, p, "subtitle", ["track": "9", "label": "no such track"])
        await command(web, p, "seek", ["pos": "x"])
    }

    @MainActor
    private static func sender(_ web: WKWebView, _ p: PlaybackCoordinator) async {
        let poster = ProcessInfo.processInfo.environment["DOBBY_SELFTEST_POSTER"] ?? ""
        await wait(4)
        await js(web, p, "window.hubRemoteNext = function () { window.__remoteNext = (window.__remoteNext || 0) + 1; }; 'stubbed'")
        let video = json(["title": "Selftest Film", "seriesTitle": "Selftest Show", "episodeTitle": "The Remote", "poster": poster, "imdbId": "tt0000001", "type": "series",
                          "season": 1, "episode": 2])
        await js(web, p, "hubRemoteStart({ id: 'selftest-tv', name: 'Living room TV' }, 'r1', \(video), false); typeof hubRemote")
        await wait(2)
        p.markSelftest("remote view=\(p.remote.view.map { "\($0.status)" } ?? "nil")")
        p.markSelftest("shot sender-starting")
        await wait(2.5)
        await target(web, p, paused: false, pos: 754)
        p.markSelftest("remote view=\(p.remote.view.map { "\($0.status) paused=\($0.paused) audio=\($0.audio.count) subtitle=\($0.subtitle.count)" } ?? "nil")")
        p.markSelftest("shot sender-playing")
        await wait(2.5)
        guard let v = p.remote.view else { p.markSelftest("remote FAIL: no native remote player"); return }
        for b: RemoteButton in [.pause, .play, .back15, .forward15, .seek(1200), .audio(v.audio[1].id),
                                .subtitle(v.subtitle[1].id), .next] {
            p.remote.press(b)
            await wait(1.5)
        }
        await js(web, p, "String(window.__remoteNext || 0)")
        await target(web, p, paused: true, pos: 1200)
        p.markSelftest("shot sender-paused")
        await wait(2.5)
        p.remote.sheet = .audio
        p.markSelftest("shot sender-audio-sheet")
        await wait(2.5)
        p.remote.sheet = .subtitle
        p.markSelftest("shot sender-subtitle-sheet")
        await wait(2.5)
        p.remote.press(.close)
        await wait(1.5)
        p.markSelftest("remote view after close=\(p.remote.view == nil ? "nil" : "shown")")
        p.markSelftest("shot sender-closed-minibar")
        await wait(2.5)
        await js(web, p, "hubRemoteOpen(); String(hubRemote && hubRemote.native)")
        await wait(1.5)
        p.markSelftest("remote view after reopen=\(p.remote.view == nil ? "nil" : "shown")")
        await target(web, p, paused: false, pos: 1300, online: false)
        p.markSelftest("shot sender-offline")
        await wait(2.5)
        await js(web, p, "hubRemoteEnd(); String(hubRemote)")
        await wait(1.5)
        p.markSelftest("remote view after ended=\(p.remote.view == nil ? "nil" : "shown")")
        p.markSelftest("shot sender-ended")
        await wait(2.5)
        await js(web, p, "hubRemoteStart({ id: 'selftest-tv', name: 'Living room TV' }, 'r2', \(video), false); 'started'")
        await wait(1.5)
        p.remote.press(.stop)
        await wait(1.5)
        let alive = await sessionAlive(web)
        p.markSelftest("remote view after stop=\(p.remote.view == nil ? "nil" : "shown") session=\(alive)")
    }

    @MainActor
    private static func sessionAlive(_ web: WKWebView) async -> String {
        ((try? await web.evaluateJavaScript("String(!!hubRemote)")) as? String) ?? "?"
    }

    /// The target's state frame as the hub would deliver it (protocol.md, "State, tracks included").
    @MainActor
    private static func target(_ web: WKWebView, _ p: PlaybackCoordinator, paused: Bool, pos: Int, online: Bool = true) async {
        let tracks: [String: Any] = ["a": [["0", "English 5.1"], ["1", "Deutsch 2.0"]], "as": "0",
                                     "s": [["off", "Off"], ["0", "English"], ["1", "Deutsch"]], "ss": "off"]
        let state: [String: Any] = ["playing": true, "paused": paused, "pos": pos, "dur": 2732,
                                    "title": ["imdbId": "tt0000001", "season": 1, "episode": 2, "tracks": tracks]]
        await js(web, p, "hubRemoteSync([\(json(["id": "selftest-tv", "online": online, "state": state]))]); 'synced'")
        await wait(1)
    }
}
#endif
