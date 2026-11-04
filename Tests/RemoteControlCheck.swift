import Foundation

// #541: the remote control's pure half (Dobby/Playback/RemoteControl.swift), standalone like ScrubStateCheck.
// The contract is the dobby repo's protocol.md, "#521 addendum", Native bridge contract.
//
//   ./Tests/run-checks.sh

@main
enum RemoteControlCheck {
    @MainActor static func main() {
        parsesTheCommandSet()
        refusesBadArgs()
        seekAndSkipClamp()
        trackLabelIsRechecked()
        ticksAfterEveryCommand()
        tracksPayloadShape()
        viewParsesTheCompactTracks()
        positionRunsOnOnlyWhilePlaying()
        endedDismissesThePlayer()
        eachControlCallsItsCommand()
        print("RemoteControlCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what) (#541)\n".utf8))
            exit(1)
        }
    }

    static func parsesTheCommandSet() {
        check(RemoteCommand.parse(#"{"cmd":"play","args":{}}"#) == .play, "play parses")
        check(RemoteCommand.parse(#"{"cmd":"pause","args":{}}"#) == .pause, "pause parses")
        check(RemoteCommand.parse(#"{"cmd":"toggle"}"#) == .toggle, "toggle parses without args")
        check(RemoteCommand.parse(#"{"cmd":"seek","args":{"pos":754}}"#) == .seek(754), "seek {pos} parses")
        check(RemoteCommand.parse(#"{"cmd":"skip","args":{"delta":-15}}"#) == .skip(-15), "skip {delta} keeps its sign")
        check(RemoteCommand.parse(#"{"cmd":"audio","args":{"track":"1","label":"Deutsch"}}"#)
              == .track(.audio, id: "1", label: "Deutsch"), "audio {track, label} parses")
        check(RemoteCommand.parse(#"{"cmd":"subtitle","args":{"track":"off","label":"Off"}}"#)
              == .track(.subtitle, id: "off", label: "Off"), "subtitle off parses")
        check(RemoteCommand.parse(#"{"cmd":"subtitle","args":{"track":3}}"#) == .track(.subtitle, id: "3", label: nil),
              "a numeric track id reads as its string, label optional")
    }

    static func refusesBadArgs() {
        check(RemoteCommand.parse(#"{"cmd":"seek","args":{"pos":"12"}}"#) == nil, "a string pos is refused")
        check(RemoteCommand.parse(#"{"cmd":"seek","args":{"pos":true}}"#) == nil, "a bool pos is refused")
        check(RemoteCommand.parse(#"{"cmd":"skip","args":{}}"#) == nil, "skip without delta is refused")
        check(RemoteCommand.parse(#"{"cmd":"audio","args":{"label":"x"}}"#) == nil, "a track without an id is refused")
        check(RemoteCommand.parse(#"{"cmd":"stop","args":{}}"#) == nil, "stop is not a remoteCommand (it keeps its own path)")
        check(RemoteCommand.parse(#"{"cmd":"next","args":{}}"#) == nil, "next is not a remoteCommand")
        check(RemoteCommand.parse("not json") == nil, "garbage is refused")
    }

    @MainActor static func seekAndSkipClamp() {
        let t = FakeTarget(position: 100, duration: 1000)
        RemoteControl.run(#"{"cmd":"seek","args":{"pos":5000}}"#, on: t)
        check(t.seeks.last == 1000, "seek past the end clamps to the duration")
        RemoteControl.run(#"{"cmd":"seek","args":{"pos":-3}}"#, on: t)
        check(t.seeks.last == 0, "seek before the start clamps to 0")
        RemoteControl.run(#"{"cmd":"skip","args":{"delta":-15}}"#, on: t)
        check(t.seeks.last == 85, "skip -15 at 100 s seeks to 85 s")
        RemoteControl.run(#"{"cmd":"skip","args":{"delta":-500}}"#, on: t)
        check(t.seeks.last == 0, "skip back past the start clamps to 0")
        RemoteControl.run(#"{"cmd":"skip","args":{"delta":5000}}"#, on: t)
        check(t.seeks.last == 1000, "skip past the end clamps to the duration")
        let open = FakeTarget(position: 100, duration: 0)
        RemoteControl.run(#"{"cmd":"skip","args":{"delta":30}}"#, on: open)
        check(open.seeks.last == 130, "an unknown duration clamps only at 0")
    }

    @MainActor static func trackLabelIsRechecked() {
        let rows = [RemoteTrack(id: "off", label: "Off", selected: true),
                    RemoteTrack(id: "0", label: "English", selected: false),
                    RemoteTrack(id: "1", label: "Deutsch", selected: false)]
        check(RemoteControl.pick(rows, id: "1", label: "Deutsch") == "1", "the id wins while its label matches")
        check(RemoteControl.pick(rows, id: "0", label: "Deutsch") == "1", "a moved row is found by its label")
        check(RemoteControl.pick(rows, id: "7", label: "English") == "0", "an unknown id falls back to the label")
        check(RemoteControl.pick(rows, id: "0", label: "Français") == nil, "neither id+label nor label: refused")
        check(RemoteControl.pick(rows, id: "1", label: nil) == "1", "no label: the id alone")
        let t = FakeTarget(position: 0, duration: 100)
        t.subs = rows
        check(RemoteControl.run(#"{"cmd":"subtitle","args":{"track":"0","label":"Deutsch"}}"#, on: t) == "ok"
              && t.selected.last == "subtitle:1", "run selects the re-checked row")
        check(RemoteControl.run(#"{"cmd":"subtitle","args":{"track":"0","label":"Français"}}"#, on: t) == "refused"
              && t.selected.count == 1, "run selects nothing for a refused track")
    }

    @MainActor static func ticksAfterEveryCommand() {
        let t = FakeTarget(position: 10, duration: 100)
        // (command, what it does before its tick; nil: refused, the tick alone)
        let commands: [(String, String?)] = [
            (#"{"cmd":"pause"}"#, "pause"), (#"{"cmd":"play"}"#, "play"),
            (#"{"cmd":"toggle"}"#, "pause"), (#"{"cmd":"toggle"}"#, "play"),
            (#"{"cmd":"seek","args":{"pos":50}}"#, "seek:50.0"), (#"{"cmd":"skip","args":{"delta":15}}"#, "seek:25.0"),
            (#"{"cmd":"audio","args":{"track":"1","label":"Deutsch"}}"#, "audio:1"),
            (#"{"cmd":"subtitle","args":{"track":"9","label":"nope"}}"#, nil), ("garbage", nil)]
        for (c, action) in commands {
            let before = t.events.count
            RemoteControl.run(c, on: t)
            let new = Array(t.events[before...])
            check(new == (action.map { [$0] } ?? []) + ["tick"], "\(c) runs \(action ?? "nothing") then one tick, got \(new)")
        }
    }

    static func tracksPayloadShape() {
        let p = RemoteControl.tracksPayload(audio: [RemoteTrack(id: "0", label: "English", selected: true)],
                                            subtitle: [RemoteTrack(id: "off", label: "Off", selected: true)])
        let audio = p["audio"] as? [[String: Any]] ?? []
        let sub = p["subtitle"] as? [[String: Any]] ?? []
        check(audio.count == 1 && audio[0]["id"] as? String == "0" && audio[0]["label"] as? String == "English"
              && audio[0]["selected"] as? Bool == true, "audio rows are {id, label, selected}")
        check(sub.first?["id"] as? String == "off", "subtitle off is a row of its own")
        check(JSONSerialization.isValidJSONObject(p), "the payload serializes")
    }

    static func viewParsesTheCompactTracks() {
        let json = #"{"device":"Living room","title":"A film","poster":"","started":true,"online":true,"paused":false,"pos":60,"dur":3600,"canNext":true,"tracks":{"a":[["0","English"],[1,"Deutsch"]],"as":1,"s":[["off","Off"]],"ss":"off"}}"#
        guard case .view(let v)? = RemoteView.parse(json) else { return check(false, "a view parses") }
        check(v.device == "Living room" && v.canNext && v.dur == 3600, "view fields read")
        check(v.audio.map(\.id) == [#""0""#, "1"], "ids keep their JSON type (string vs number): \(v.audio.map(\.id))")
        check(v.audio.map(\.selected) == [false, true], "as selects by the same typed id")
        check(v.subtitle.first?.selected == true, "ss selects off")
        check(RemoteView.parse(#"{"ended":true}"#) == .ended, "{ended:true} is the end")
        check(RemoteView.parse(#"{"device":"x","tracks":null}"#).map { if case .view(let v) = $0 { return v.audio.isEmpty } else { return false } } == true,
              "null tracks: no pickers")
        check(RemoteView.parse("[]") == nil, "not a view")
    }

    static func positionRunsOnOnlyWhilePlaying() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var v = RemoteView(started: true, online: true, paused: false, pos: 100, dur: 105, at: t0)
        check(v.position(at: t0.addingTimeInterval(3)) == 103, "playing: runs on with the clock")
        check(v.position(at: t0.addingTimeInterval(30)) == 105, "never past the duration")
        v.paused = true
        check(v.position(at: t0.addingTimeInterval(3)) == 100, "paused: frozen")
        v.paused = false; v.online = false
        check(v.position(at: t0.addingTimeInterval(3)) == 100, "offline: frozen")
        v.online = true; v.started = false
        check(v.position(at: t0.addingTimeInterval(3)) == 100, "not started: frozen")
        check(RemoteView(device: "TV", online: false).status == "TV is offline", "offline line")
        check(RemoteView(device: "TV", started: false).status == "Starting on TV…", "starting line")
        check(RemoteView(device: "TV", started: true).status == "Playing on TV", "playing line")
    }

    @MainActor static func endedDismissesThePlayer() {
        let m = RemotePlayerModel()
        m.update(#"{"device":"TV","started":true}"#)
        check(m.view == nil, "a state before open does not open the player")
        m.open(#"{"device":"TV","started":false}"#)
        check(m.view?.device == "TV", "open shows it")
        m.update(#"{"device":"TV","started":true,"paused":true}"#)
        check(m.view?.paused == true && m.view?.started == true, "a state updates it")
        m.sheet = .audio
        m.update(#"{"ended":true}"#)
        check(m.view == nil && m.sheet == nil, "remotePlayerState {ended:true} dismisses it and its picker")
        m.update(#"{"device":"TV","started":true}"#)
        check(m.view == nil, "a late state does not bring it back")
        var sent: [RemoteButton] = []
        m.send = { sent.append($0) }
        m.open(#"{"device":"TV"}"#)
        m.press(.close)
        check(m.view == nil && sent == [.close], "close dismisses it and tells the PWA")
        m.open(#"{"device":"TV"}"#)
        m.press(.stop)
        check(m.view == nil && sent.last == .stop, "stop dismisses it too")
        m.open(#"{"device":"TV"}"#)
        m.press(.pause)
        check(m.view != nil && sent.last == .pause, "other controls keep it up and reach send")
    }

    static func eachControlCallsItsCommand() {
        let want: [(RemoteButton, String)] = [
            (.play, "window.dobbyRemoteControl && window.dobbyRemoteControl('play', {})"),
            (.pause, "window.dobbyRemoteControl && window.dobbyRemoteControl('pause', {})"),
            (.back15, #"window.dobbyRemoteControl && window.dobbyRemoteControl('skip', {"delta":-15})"#),
            (.forward15, #"window.dobbyRemoteControl && window.dobbyRemoteControl('skip', {"delta":15})"#),
            (.seek(754.4), #"window.dobbyRemoteControl && window.dobbyRemoteControl('seek', {"pos":754})"#),
            (.next, "window.dobbyRemoteControl && window.dobbyRemoteControl('next', {})"),
            (.stop, "window.dobbyRemoteControl && window.dobbyRemoteControl('stop', {})"),
            (.close, "window.dobbyRemoteControl && window.dobbyRemoteControl('close', {})"),
            (.audio(#""1""#), #"window.dobbyRemoteControl && window.dobbyRemoteControl('audio', {"track":"1"})"#),
            (.subtitle("3"), #"window.dobbyRemoteControl && window.dobbyRemoteControl('subtitle', {"track":3})"#),
        ]
        for (b, js) in want { check(b.js == js, "\(b) calls \(js), got \(b.js)") }
    }
}

@MainActor final class FakeTarget: RemoteTarget {
    var remotePosition: Double
    var remoteDuration: Double
    var remotePaused = false
    var seeks: [Double] = []
    var selected: [String] = []
    var subs: [RemoteTrack] = []
    /// Every action and tick in order.
    var events: [String] = []

    init(position: Double, duration: Double) { remotePosition = position; remoteDuration = duration }

    func remotePlay() { remotePaused = false; events.append("play") }
    func remotePause() { remotePaused = true; events.append("pause") }
    func remoteSeek(to seconds: Double) { seeks.append(seconds); events.append("seek:\(seconds)") }
    func remoteTracks(_ kind: RemoteTrackKind) -> [RemoteTrack] {
        kind == .audio ? [RemoteTrack(id: "0", label: "English", selected: true), RemoteTrack(id: "1", label: "Deutsch", selected: false)] : subs
    }
    func remoteSelect(_ kind: RemoteTrackKind, id: String) { selected.append("\(kind.rawValue):\(id)"); events.append("\(kind.rawValue):\(id)") }
    func remoteTick() { events.append("tick") }
}
