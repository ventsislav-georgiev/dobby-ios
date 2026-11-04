import Combine
import Foundation

// #541: the pure half of the remote control (the dobby repo's protocol.md, "#521 addendum", Native bridge
// contract). The receiver side: what a window.Dobby.remoteCommand does to the film and which tracks a tick
// reports. The sender side: the view the PWA pushes to the native remote player and the
// window.dobbyRemoteControl call each of its controls makes. No KSPlayer, no SwiftUI, no WebKit, so
// Tests/RemoteControlCheck.swift runs it standalone.

// MARK: - Receiver

enum RemoteTrackKind: String { case audio, subtitle }

/// A pickable row. On the receiver `id` is the id this app reports (a string: "0", "1"..., subtitle "off");
/// on the sender it is the target's id as a JSON fragment (`"0"` or `3`), so it goes back the type it came
/// (the PWA matches it with ===).
struct RemoteTrack: Equatable {
    let id: String
    let label: String
    let selected: Bool
}

/// The film the receiver plays, as a command sees it. PlaybackCoordinator is the one in the app.
@MainActor protocol RemoteTarget: AnyObject {
    /// Live position and duration in seconds; duration 0 when unknown.
    var remotePosition: Double { get }
    var remoteDuration: Double { get }
    var remotePaused: Bool { get }
    func remotePlay()
    func remotePause()
    func remoteSeek(to seconds: Double)
    func remoteTracks(_ kind: RemoteTrackKind) -> [RemoteTrack]
    func remoteSelect(_ kind: RemoteTrackKind, id: String)
    /// window.dobbyNativePlaybackProgress, now, with paused and tracks.
    func remoteTick()
}

enum RemoteCommand: Equatable {
    case play, pause, toggle
    case seek(Double)
    case skip(Double)
    case track(RemoteTrackKind, id: String, label: String?)

    /// `{"cmd", "args"}` as the PWA's hubNativeCommand sends it. nil: not that shape, a cmd outside the set
    /// (stop keeps its own path), a pos or delta that is not a finite number, a track without an id.
    static func parse(_ json: String) -> RemoteCommand? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cmd = obj["cmd"] as? String else { return nil }
        let args = obj["args"] as? [String: Any] ?? [:]
        switch cmd {
        case "play": return .play
        case "pause": return .pause
        case "toggle": return .toggle
        case "seek": return number(args["pos"]).map { .seek($0) }
        case "skip": return number(args["delta"]).map { .skip($0) }
        case "audio", "subtitle":
            guard let id = trackID(args["track"]) else { return nil }
            return .track(cmd == "audio" ? .audio : .subtitle, id: id, label: args["label"] as? String)
        default: return nil
        }
    }

    /// A JSON number, never a JSON bool (both arrive as NSNumber).
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func trackID(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }
}

enum RemoteControl {
    /// One remoteCommand on the film, then a tick whatever came of it: the PWA acked the hand-over already and
    /// sends that tick's state frame at once (hubForceReport). "ok", or "refused" for what was not done.
    @MainActor @discardableResult
    static func run(_ json: String, on t: RemoteTarget) -> String {
        defer { t.remoteTick() }
        guard let c = RemoteCommand.parse(json) else { return "refused" }
        switch c {
        case .play: t.remotePlay()
        case .pause: t.remotePause()
        case .toggle: if t.remotePaused { t.remotePlay() } else { t.remotePause() }
        case .seek(let s): t.remoteSeek(to: clamp(s, t.remoteDuration))
        case .skip(let d): t.remoteSeek(to: clamp(t.remotePosition + d, t.remoteDuration))
        case .track(let kind, let id, let label):
            guard let pick = pick(t.remoteTracks(kind), id: id, label: label) else { return "refused" }
            t.remoteSelect(kind, id: pick)
        }
        return "ok"
    }

    /// [0, duration], or only from 0 while the duration is unknown (the web player's rule).
    static func clamp(_ s: Double, _ duration: Double) -> Double {
        max(0, duration > 0 ? min(duration, s) : s)
    }

    /// The web player's hubPickTrack: the row at that id when it still carries that label, else the row with
    /// that label (the list reordered), else nothing.
    static func pick(_ rows: [RemoteTrack], id: String, label: String?) -> String? {
        if let r = rows.first(where: { $0.id == id }), label == nil || r.label == label { return r.id }
        guard let label else { return nil }
        return rows.first { $0.label == label }?.id
    }

    /// The tick's `tracks`: {audio: [{id, label, selected}], subtitle: [...]}.
    static func tracksPayload(audio: [RemoteTrack], subtitle: [RemoteTrack]) -> [String: Any] {
        func rows(_ l: [RemoteTrack]) -> [[String: Any]] { l.map { ["id": $0.id, "label": $0.label, "selected": $0.selected] } }
        return ["audio": rows(audio), "subtitle": rows(subtitle)]
    }
}

// MARK: - Sender

/// What the PWA pushes (Dobby.openRemotePlayer / remotePlayerState): {device, title, poster, started, online,
/// paused, pos, dur, canNext, tracks}, tracks the compact {a: [[id, label]], as, s: [[id, label]], ss} or null.
struct RemoteView: Equatable {
    var device = ""
    var title = ""
    var poster = ""
    var started = false
    var online = true
    var paused = false
    var canNext = false
    var pos = 0.0
    var dur = 0.0
    var audio: [RemoteTrack] = []
    var subtitle: [RemoteTrack] = []
    /// When this state arrived: the PWA does not push every second, the position runs on from here.
    var at = Date()

    enum Update: Equatable { case view(RemoteView), ended }

    /// nil when the payload is neither a view nor {"ended": true}.
    static func parse(_ json: String, at now: Date = Date()) -> Update? {
        guard let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if o["ended"] as? Bool == true { return .ended }
        guard let device = o["device"] as? String else { return nil }
        var v = RemoteView(at: now)
        v.device = device
        v.title = o["title"] as? String ?? ""
        v.poster = o["poster"] as? String ?? ""
        v.started = o["started"] as? Bool ?? false
        v.online = o["online"] as? Bool ?? true
        v.paused = o["paused"] as? Bool ?? false
        v.canNext = o["canNext"] as? Bool ?? false
        v.pos = (o["pos"] as? NSNumber)?.doubleValue ?? 0
        v.dur = (o["dur"] as? NSNumber)?.doubleValue ?? 0
        if let t = o["tracks"] as? [String: Any] {
            v.audio = rows(t["a"], selected: t["as"])
            v.subtitle = rows(t["s"], selected: t["ss"])
        }
        return .view(v)
    }

    private static func fragment(_ v: Any?) -> String? {
        guard let v, !(v is NSNull),
              let d = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func rows(_ list: Any?, selected: Any?) -> [RemoteTrack] {
        let on = fragment(selected)
        return (list as? [[Any]] ?? []).compactMap { row in
            guard row.count >= 2, let id = fragment(row[0]) else { return nil }
            return RemoteTrack(id: id, label: "\(row[1])", selected: id == on)
        }
    }

    /// The PWA's hubRemotePos: runs on with the clock while the target plays and is online, frozen otherwise.
    func position(at now: Date) -> Double {
        let run = started && !paused && online ? max(0, now.timeIntervalSince(at)) : 0
        return dur > 0 ? min(dur, pos + run) : pos + run
    }

    /// The line under the title, the web remote player's words.
    var status: String {
        !online ? "\(device) is offline" : started ? "Playing on \(device)" : "Starting on \(device)…"
    }
}

/// A control of the native remote player and the window.dobbyRemoteControl(cmd, args) it makes.
enum RemoteButton: Hashable {
    case play, pause, back15, forward15, next, stop, close
    case seek(Double)
    case audio(String)
    case subtitle(String)

    var cmd: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .back15, .forward15: return "skip"
        case .seek: return "seek"
        case .next: return "next"
        case .stop: return "stop"
        case .close: return "close"
        case .audio: return "audio"
        case .subtitle: return "subtitle"
        }
    }

    /// The args as JSON. A track id is already a JSON fragment (RemoteTrack on the sender).
    var args: String {
        switch self {
        case .back15: return #"{"delta":-15}"#
        case .forward15: return #"{"delta":15}"#
        case .seek(let p): return #"{"pos":\#(Int(max(0, p).rounded()))}"#
        case .audio(let id), .subtitle(let id): return #"{"track":\#(id)}"#
        default: return "{}"
        }
    }

    var js: String { "window.dobbyRemoteControl && window.dobbyRemoteControl('\(cmd)', \(args))" }
}

/// The native remote player's state (RemotePlayerView draws it). The PWA opens it, pushes every change and ends
/// it; each control goes back through `send` (WebBridge: window.dobbyRemoteControl).
@MainActor final class RemotePlayerModel: ObservableObject {
    /// Shown while non-nil.
    @Published private(set) var view: RemoteView?
    /// The open track picker.
    @Published var sheet: RemoteTrackKind?
    var send: ((RemoteButton) -> Void)?

    /// Dobby.openRemotePlayer: a session opened, or the PWA's mini bar was tapped.
    func open(_ json: String) {
        guard case .view(let v)? = RemoteView.parse(json) else { return }
        view = v
    }

    /// Dobby.remotePlayerState: the session's new state, or {"ended": true}, which takes the player down. A state
    /// for a player the user already closed does not bring it back (the PWA learns of the close from "close").
    func update(_ json: String) {
        switch RemoteView.parse(json) {
        case .ended?: view = nil; sheet = nil
        case .view(let v)? where view != nil: view = v
        default: break
        }
    }

    /// A control: its dobbyRemoteControl call. Close and Stop also take the player down here, Stop because a
    /// PWA with no session left (it returns false) would never end it.
    func press(_ b: RemoteButton) {
        send?(b)
        sheet = nil
        if b == .close || b == .stop { view = nil }
    }
}
