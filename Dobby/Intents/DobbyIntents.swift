import AppIntents
import Foundation

/// Siri control for Dobby.
///
/// Siri is the one part of the CarPlay interface open to apps without a CarPlay
/// entitlement, so this is how Dobby is driven from the steering wheel: ask for a
/// book, ask for something on YouTube, resume, or stop. Every intent opens the app
/// and hands a command to the web layer through `VoiceCommandQueue`.
///
/// Book titles are an `AppEntity` rather than free text on purpose — Siri's matching
/// against a resolved candidate set is far more reliable than against a raw string.

// MARK: - Book entity

struct BookEntity: AppEntity, Identifiable {
    let id: String
    let title: String
    let author: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Audiobook" }
    static var defaultQuery = BookEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(author)")
    }
}

struct BookEntityQuery: EntityStringQuery {
    func entities(for identifiers: [BookEntity.ID]) async throws -> [BookEntity] {
        let wanted = Set(identifiers)
        return try await allBooks().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [BookEntity] {
        let needle = string.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        return try await allBooks().filter {
            let haystack = ($0.title + " " + $0.author)
                .folding(options: .diacriticInsensitive, locale: .current).lowercased()
            return haystack.contains(needle)
        }
    }

    func suggestedEntities() async throws -> [BookEntity] {
        Array(try await allBooks().prefix(20))
    }

    /// #181, #508: the library lived on the Pi, which is retired, so there is none to offer.
    /// Audiobooks are hidden; how they come back is a later decision.
    private func allBooks() async throws -> [BookEntity] { [] }
}

// MARK: - Intents

struct PlayBookIntent: AppIntent {
    static var title: LocalizedStringResource { "Play audiobook" }
    static var description: IntentDescription {
        IntentDescription("Play an audiobook from your Dobby library, resuming where you left off.")
    }
    // Playback lives in the app's web view, so the app has to be frontmost.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Book")
    var book: BookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$book)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceCommandQueue.shared.send(["action": "playBook", "bookId": book.id])
        return .result()
    }
}

struct PlayYouTubeIntent: AppIntent {
    static var title: LocalizedStringResource { "Play on YouTube" }
    static var description: IntentDescription {
        IntentDescription("Search YouTube in Dobby and play the first result.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Search", requestValueDialog: "What should I play?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query) on YouTube")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceCommandQueue.shared.send(["action": "playVideo", "query": query])
        return .result()
    }
}

struct ResumePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource { "Resume listening" }
    static var description: IntentDescription {
        IntentDescription("Continue the audiobook you were last listening to.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceCommandQueue.shared.send(["action": "resume"])
        return .result()
    }
}

struct StopPlaybackIntent: AppIntent {
    static var title: LocalizedStringResource { "Stop playback" }
    static var description: IntentDescription { IntentDescription("Stop whatever Dobby is playing.") }
    // No app switch: stopping should not yank the driver's screen around.
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceCommandQueue.shared.send(["action": "stop"])
        return .result()
    }
}

// MARK: - Shortcuts

/// Phrases Siri accepts without the user configuring anything. Every phrase must
/// contain `\(.applicationName)`; "Dobby" is what the user actually says.
struct DobbyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Listen to \(\.$book) in \(.applicationName)",
                "Play the book \(\.$book) in \(.applicationName)",
            ],
            shortTitle: "Play audiobook",
            systemImageName: "headphones"
        )
        AppShortcut(
            intent: PlayYouTubeIntent(),
            // No `\(\.$query)` here: only AppEntity/AppEnum parameters may appear in a
            // shortcut phrase. Siri collects the search term with `requestValueDialog`
            // ("What should I play?") right after the phrase matches.
            phrases: [
                "Play something on \(.applicationName)",
                "Search YouTube in \(.applicationName)",
            ],
            shortTitle: "Play on YouTube",
            systemImageName: "play.rectangle"
        )
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Continue listening in \(.applicationName)",
            ],
            shortTitle: "Resume listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopPlaybackIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "Pause \(.applicationName)",
            ],
            shortTitle: "Stop playback",
            systemImageName: "stop.fill"
        )
    }
}
