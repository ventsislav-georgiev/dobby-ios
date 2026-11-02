import Foundation

@main
enum AppConfigCheck {
    static func main() {
        startPathComposition()
        startPathRejection()
        macUpdateConfig()
        piURL()
        print("AppConfigCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static let origin = URL(string: "https://pi.example.ts.net")!

    static func startPathComposition() {
        check(AppConfig.startURL(origin: origin, env: [:]) == origin,
              "no DOBBY_START_PATH set: bare origin is used")
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": "/tv/123"]).absoluteString
              == "https://pi.example.ts.net/tv/123",
              "a path-only value is appended to the origin")
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": "/tv/123?season=2"]).absoluteString
              == "https://pi.example.ts.net/tv/123?season=2",
              "the query string survives the composition")
    }

    /// #491: the default Pi address comes only from the build (DOBBY_PI_HOST in WKAppBoundDomains).
    static func piURL() {
        check(AppConfig.piURL([]) == nil, "#491 piURL: no app-bound domain means no default address")
        check(AppConfig.piURL([""]) == nil, "#491 piURL: DOBBY_PI_HOST unset (expanded empty) means no default address")
        check(AppConfig.piURL(["pi.example.ts.net"])?.absoluteString == "https://pi.example.ts.net",
              "#491 piURL: an injected host becomes the https default")
    }

    static func startPathRejection() {
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": ""]) == origin,
              "an empty value falls back to the bare origin")
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": "tv/123"]) == origin,
              "a value with no leading slash is rejected")
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": "//evil.example/x"]) == origin,
              "a scheme-relative value (host injection) is rejected")
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": "https://evil.example/x"]) == origin,
              "a value carrying its own scheme is rejected")
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": "http://evil.example//x"]) == origin,
              "a value carrying its own scheme+host is rejected even with a deeper path")
    }

    /// #464: a build missing any update setting starts no updater.
    static func macUpdateConfig() {
        let full: [String: Any] = ["SUFeedURL": "https://updates.invalid/v1/mac/appcast.xml",
                                   "SUPublicEDKey": "pub", "DobbyUpdateToken": "tok"]
        let on = AppConfig.macUpdateConfig(full)
        check(on?.feed.absoluteString == "https://updates.invalid/v1/mac/appcast.xml" && on?.token == "tok",
              "all three settings: the updater starts with that feed and token")
        for key in ["SUFeedURL", "SUPublicEDKey", "DobbyUpdateToken"] {
            var missing = full; missing[key] = ""
            check(AppConfig.macUpdateConfig(missing) == nil, "empty \(key): no updater")
            missing[key] = nil
            check(AppConfig.macUpdateConfig(missing) == nil, "absent \(key): no updater")
        }
        var http = full; http["SUFeedURL"] = "http://updates.invalid/v1/mac/appcast.xml"
        check(AppConfig.macUpdateConfig(http) == nil, "a plain-http feed: no updater")
        var unexpanded = full; unexpanded["SUFeedURL"] = "$(DOBBY_MAC_FEED_URL)"
        check(AppConfig.macUpdateConfig(unexpanded) == nil, "an unexpanded build setting: no updater")
    }
}
