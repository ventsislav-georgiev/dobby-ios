import Foundation

// #068: the timeout-staging decision in ServerAddresses.classify(connected:httpStatus:),
// checked as a pure function — no networking, no simulator. Same standalone-binary
// pattern as ApiSchemeHandlerCheck (see its header for why there is no XCTest target).
//
//   ./Tests/run-checks.sh

@main
enum ServerAddressesCheck {
    static func main() {
        classification()
        normalization()
        print("ServerAddressesCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    // MARK: connect-vs-read staging (task #068, Android citations in ServerAddresses.swift)

    static func classification() {
        // "HTTP 200 in 800 ms" — answered inside the short budget: present.
        check(ServerAddresses.classify(connected: true, httpStatus: 200) == .present,
              "a 2xx inside the short budget is present")
        check(ServerAddresses.classify(connected: true, httpStatus: 301) == .present,
              "a redirect still counts as an answer (existing 200..<400 rule, unchanged)")

        // "connected at 300 ms, no bytes by 1500 ms" — TCP/TLS went through, nothing
        // answered yet: present-slow, worth the long budget, not absent.
        check(ServerAddresses.classify(connected: true, httpStatus: nil) == .presentSlow,
              "connected but no response yet is present-slow")

        // "no connection by 1500 ms" — never got as far as connecting: absent, and a
        // longer wait would not change that (Android's CONNECT_TIMEOUT_MS reasoning).
        check(ServerAddresses.classify(connected: false, httpStatus: nil) == .absent,
              "never connected is absent")

        // A fronter that accepted the TCP/TLS handshake and then answered with a server
        // error is still a rejection, not a hang — must not read as present-slow.
        check(ServerAddresses.classify(connected: true, httpStatus: 502) == .absent,
              "connected, then a 5xx, is absent — not presentSlow")
    }

    // MARK: normalize() is unchanged by #068, spot-checked so the check file exercises it

    static func normalization() {
        check(ServerAddresses.normalize("192.0.2.31:8080")?.absoluteString == "http://192.0.2.31:8080",
              "bare host:port is treated as a LAN box over http")
        check(ServerAddresses.normalize("https://dobby.solarflare-tarpon.ts.net")?.absoluteString
              == "https://dobby.solarflare-tarpon.ts.net", "an explicit https origin round-trips")
        check(ServerAddresses.normalize("ftp://x") == nil, "a non-http(s) scheme is refused")
        check(ServerAddresses.normalize("   ") == nil, "blank input is refused")
    }
}
