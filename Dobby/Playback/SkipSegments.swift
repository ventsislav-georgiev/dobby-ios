import Foundation

// #560 owns this file with SkipOverlay.swift: skip the intro and the recap, and offer the next
// episode at the credits, from the play payload's optional `skip`. Pure (Foundation only) and
// checked by Tests/SkipSegmentsCheck.swift; SkipOverlay.swift draws it and feeds it the
// position ticks. Same behaviour as the web and Android players.

/// The play payload's `skip`. Decoding never throws: a malformed field reads as absent (a mode
/// as `auto`), so an odd `skip` can never cost the whole payload, and with it playback.
struct SkipSegments: Equatable {
    struct Segment: Equatable {
        var start: Double
        var end: Double?            // nil for credits
        var confident = false
    }

    enum Mode: String { case auto, button, off }
    /// The skippable segments, checked in this order on every tick.
    enum Kind: String, CaseIterable { case recap, intro }

    var intro: Segment?
    var recap: Segment?
    var credits: Segment?
    /// The episode length the times were measured on, when known.
    var length: Double?
    var introMode = Mode.auto
    var recapMode = Mode.auto
    var creditsMode = Mode.auto
    var hasNext = false

    /// An auto-skip needs the times measured on this cut: within 20 s of the actual duration.
    static let lengthTolerance = 20.0

    func segment(_ k: Kind) -> Segment? { k == .intro ? intro : recap }
    func mode(_ k: Kind) -> Mode { k == .intro ? introMode : recapMode }

    /// Mode auto, a confident segment, and a length that is unknown or matches this duration.
    func autoSkips(_ k: Kind, duration: Double) -> Bool {
        guard mode(k) == .auto, segment(k)?.confident == true else { return false }
        guard let length else { return true }
        return duration.isFinite && abs(length - duration) <= Self.lengthTolerance
    }
}

extension SkipSegments: Decodable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) {
        typealias C = KeyedDecodingContainer<Key>
        func num(_ c: C?, _ k: String) -> Double? { (try? c?.decode(Double.self, forKey: Key(k))).flatMap { $0 } }
        func nested(_ c: C?, _ k: String) -> C? { (try? c?.nestedContainer(keyedBy: Key.self, forKey: Key(k))).flatMap { $0 } }
        func segment(_ c: C?, _ k: String, needsEnd: Bool) -> Segment? {
            let s = nested(c, k)
            guard let start = num(s, "start"), start >= 0 else { return nil }
            let end = num(s, "end")
            if needsEnd { guard let end, end > start else { return nil } }
            let confident = (try? s?.decode(Bool.self, forKey: Key("confident"))).flatMap { $0 } ?? false
            return Segment(start: start, end: needsEnd ? end : nil, confident: confident)
        }
        let c = try? decoder.container(keyedBy: Key.self)
        let m = nested(c, "mode")
        func mode(_ k: String) -> Mode {
            (try? m?.decode(String.self, forKey: Key(k))).flatMap { $0 }.flatMap(Mode.init(rawValue:)) ?? .auto
        }
        self.init(intro: segment(c, "intro", needsEnd: true), recap: segment(c, "recap", needsEnd: true),
                  credits: segment(c, "credits", needsEnd: false), length: num(c, "length"),
                  introMode: mode("intro"), recapMode: mode("recap"), creditsMode: mode("credits"),
                  hasNext: (try? c?.decode(Bool.self, forKey: Key("hasNext"))).flatMap { $0 } ?? false)
    }
}

/// What the overlay shows for one playback, advanced by the position ticks the OSD already
/// gets (no timer of its own: the label and the countdown run on the playback position, so a
/// pause holds them).
struct SkipState: Equatable {
    enum Action: Equatable { case seek(Double), next }

    /// The playback this state belongs to; a new ref starts over.
    var ref: String?
    /// Segments auto-skipped in this playback: seeking back into one shows the button instead.
    var autoSkipped: Set<SkipSegments.Kind> = []
    /// The "Skip intro" / "Skip recap" button.
    var button: SkipSegments.Kind?
    /// The "Skipped intro" / "Skipped recap" label after an auto-skip.
    var skipped: SkipSegments.Kind?
    /// The auto-skip's seek target, and whether a tick has reported the position there yet.
    var skipTarget = 0.0
    var landed = true
    /// The "Next episode" button.
    var nextShown = false
    /// Where the auto countdown fires, nil when none runs (button mode, or cancelled).
    var countdownEnd: Double?
    /// Whole seconds left on the countdown, drawn on the button.
    var countdown: Int?

    static let labelSeconds = 3.0
    static let countdownSeconds = 10.0

    /// One position tick. Returns the seek an auto-skip asks for, or `.next` when the
    /// countdown runs out. Without `skip` nothing ever shows.
    mutating func tick(ref: String?, position: Double, duration: Double, skip: SkipSegments?) -> Action? {
        if ref != self.ref { self = SkipState(ref: ref) }
        guard let skip, position.isFinite else { return nil }
        var action: Action?
        if !landed, position >= skipTarget - 1 { landed = true }

        // Intro and recap: inside [start, end - 1).
        button = nil
        for kind in SkipSegments.Kind.allCases {
            guard skip.mode(kind) != .off, let seg = skip.segment(kind), let end = seg.end,
                  position >= seg.start, position < end - 1 else { continue }
            if skip.autoSkips(kind, duration: duration), !autoSkipped.contains(kind) {
                autoSkipped.insert(kind)
                skipped = kind; skipTarget = end; landed = false
                action = .seek(end)
            } else if landed {
                button = kind   // not while the auto-skip's seek is still landing
            }
            break
        }
        // The label holds while the seek lands and for 3 s of playback after it; a seek back
        // into the segment (or anywhere before) or past those 3 s drops it.
        if skipped != nil, landed, position < skipTarget - 1 || position >= skipTarget + Self.labelSeconds {
            skipped = nil
        }

        // Credits: from credits.start on; seeking back before it hides the button again.
        let atCredits = skip.hasNext && skip.creditsMode != .off && skip.credits.map { position >= $0.start } == true
        if atCredits, !nextShown {
            nextShown = true
            if skip.creditsMode == .auto { countdownEnd = position + Self.countdownSeconds }
        } else if !atCredits, nextShown {
            nextShown = false; countdownEnd = nil
        }
        if let endAt = countdownEnd {
            let left = endAt - position
            countdown = max(0, Int(left.rounded(.up)))
            if left <= 0, action == nil { countdownEnd = nil; action = .next }
        } else {
            countdown = nil
        }
        return action
    }

    /// Any key or Back during the countdown: it stops, the button stays.
    mutating func cancelCountdown() { countdownEnd = nil; countdown = nil }

    /// Where the visible skip button seeks to.
    func buttonTarget(_ skip: SkipSegments?) -> Double? { button.flatMap { skip?.segment($0)?.end } }
}
