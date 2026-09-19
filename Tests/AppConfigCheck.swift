import Foundation

@main
enum AppConfigCheck {
    static func main() {
        startPathComposition()
        startPathRejection()
        print("AppConfigCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static let origin = URL(string: "https://dobby.solarflare-tarpon.ts.net")!

    static func startPathComposition() {
        check(AppConfig.startURL(origin: origin, env: [:]) == origin,
              "no DOBBY_START_PATH set: bare origin is used")
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": "/tv/123"]).absoluteString
              == "https://dobby.solarflare-tarpon.ts.net/tv/123",
              "a path-only value is appended to the origin")
        check(AppConfig.startURL(origin: origin, env: ["DOBBY_START_PATH": "/tv/123?season=2"]).absoluteString
              == "https://dobby.solarflare-tarpon.ts.net/tv/123?season=2",
              "the query string survives the composition")
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
}
