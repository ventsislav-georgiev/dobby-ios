import Foundation

// #068: the timeout-staging decision in ServerAddresses.classify(connected:httpStatus:),
// checked as a pure function — no networking, no simulator. Same standalone-binary
// pattern as ApiSchemeHandlerCheck (see its header for why there is no XCTest target).
//
//   ./Tests/run-checks.sh

@main
enum ServerAddressesCheck {
    static func main() async {
        if CommandLine.arguments.contains("--expect-no-server") {
            await expectNoServer()
            return
        }
        classification()
        normalization()
        noServerSeam()
        autoOfflineSeam()
        piEnabledRule()
        piEnabledPersistence()
        piOriginRule()
        appBoundRule()
        appBoundStoreAndCandidates()
        appBoundPlatformPin()
        piOriginIgnoresTheAppBoundFilter()
        print("ServerAddressesCheck: all checks passed")
    }

    /// Wiring pin for the #068 seam (run-checks.sh builds a separate `-D DEBUG` binary, OUT3,
    /// and runs `DOBBY_NO_SERVER=1 "$OUT3" --expect-no-server`): unlike
    /// `noServerSeam()` below, which only pins how the predicate parses its input, this exercises
    /// the actual call site in `probe(_:)` through `resolve()` — it fails if the guard is ever
    /// deleted or moved out from under the DEBUG gate.
    static func expectNoServer() async {
        let resolved = await ServerAddresses.resolve()
        check(resolved == nil, "DOBBY_NO_SERVER=1 makes resolve() report every candidate absent")
        print("ServerAddressesCheck --expect-no-server: seam wiring verified")
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

    /// #068 device done-condition test seam.
    static func noServerSeam() {
        check(ServerAddresses.noServerSeamActive(["DOBBY_NO_SERVER": "1"]) == true,
              "DOBBY_NO_SERVER=1 activates the seam")
        check(ServerAddresses.noServerSeamActive([:]) == false,
              "seam is off when the var is unset")
        check(ServerAddresses.noServerSeamActive(["DOBBY_NO_SERVER": "0"]) == false,
              "any value other than exactly \"1\" leaves the seam off")
        check(ServerAddresses.noServerSeamActive(["DOBBY_NO_SERVER": "true"]) == false,
              "no truthy-string coercion — exact match only")
    }

    /// #181: Android's three-input rule, every row of the truth table. An explicit
    /// answer wins both ways; only an unanswered setting follows hasLastGood.
    static func piEnabledRule() {
        for value in [false, true] {
            for lastGood in [false, true] {
                check(ServerAddresses.piEnabled(explicitlySet: true, explicitValue: value, hasLastGood: lastGood) == value,
                      "an explicit \(value) wins whatever hasLastGood (\(lastGood)) says")
                check(ServerAddresses.piEnabled(explicitlySet: false, explicitValue: value, hasLastGood: lastGood) == lastGood,
                      "unset follows hasLastGood (\(lastGood)), never the unread value (\(value))")
            }
        }
    }

    /// #181: the same rule through the stored keys — "explicitly set" is the key's
    /// presence, so an explicit off must not read as unset and fall back to the origin.
    static func piEnabledPersistence() {
        let suite = "dobby.check.piEnabled.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "test defaults suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        check(ServerAddresses.piEnabled(defaults) == false, "a fresh install is Pi-less")
        defaults.set("http://192.0.2.31:8080", forKey: "dobby.serverAddresses.lastGood")
        check(ServerAddresses.piEnabled(defaults) == true, "a device that reached a Pi before reads on")
        ServerAddresses.setPiEnabled(false, defaults)
        check(ServerAddresses.piEnabled(defaults) == false, "an explicit off is not re-enabled by the stored origin")
        defaults.removeObject(forKey: "dobby.serverAddresses.lastGood")
        ServerAddresses.setPiEnabled(true, defaults)
        check(ServerAddresses.piEnabled(defaults) == true, "an explicit on holds with no stored origin")
    }

    /// #217: the video download gate's origin test. Host against every candidate's host,
    /// any scheme and port, hostless = page-relative = the Pi; everything else downloads.
    static func piOriginRule() {
        let pi = [URL(string: "http://192.0.2.31:8080")!, URL(string: "https://pi.example.invalid")!]
        check(ServerAddresses.isPiOrigin("http://192.0.2.31:8080/stream/x.mkv", candidates: pi), "the Pi's LAN address is the Pi")
        check(ServerAddresses.isPiOrigin("https://PI.example.invalid/api/proxy?url=x", candidates: pi), "a candidate host in any case is the Pi")
        check(ServerAddresses.isPiOrigin("https://192.0.2.31/x", candidates: pi), "a candidate host on another scheme and port is the Pi")
        check(ServerAddresses.isPiOrigin("https://pi.example.invalid/x", candidates: [URL(string: "https://PI.example.invalid")!]),
              "a candidate saved in upper case is the Pi for a lower-case URL host (#225, URL.host keeps case)")
        check(ServerAddresses.isPiOrigin("/api/subtitles/fetch?provider=a4k&download=1", candidates: pi), "a page-relative URL is the Pi")
        check(!ServerAddresses.isPiOrigin("https://cdn.example.net/dl/x.mkv", candidates: pi), "a debrid link is not the Pi")
        check(!ServerAddresses.isPiOrigin("http://192.0.2.32:8080/x", candidates: pi), "a neighbouring LAN host is not the Pi")
        check(!ServerAddresses.isPiOrigin("https://pi.example.invalid.cdn.example.net/x", candidates: pi), "a host that only starts like the Pi is not the Pi")
        check(!ServerAddresses.isPiOrigin(nil, candidates: pi), "no URL is nothing to fetch")
        check(!ServerAddresses.isPiOrigin("https://cdn.example.net/x", candidates: []), "no candidates means nothing is the Pi")
    }

    static func autoOfflineSeam() {
        check(ServerAddresses.autoOfflineSeamActive(["DOBBY_AUTO_OFFLINE": "1"]) == true,
              "DOBBY_AUTO_OFFLINE=1 activates the seam")
        check(ServerAddresses.autoOfflineSeamActive([:]) == false,
              "seam is off when the var is unset")
        check(ServerAddresses.autoOfflineSeamActive(["DOBBY_AUTO_OFFLINE": "0"]) == false,
              "any value other than exactly \"1\" leaves the seam off")
        check(ServerAddresses.autoOfflineSeamActive(["DOBBY_AUTO_OFFLINE": "true"]) == false,
              "no truthy-string coercion — exact match only")
    }

    /// #245: the domains the app ships, read off Dobby/Info.plist (Bundle.main has none here).
    static func shippedDomains() -> [String] {
        guard let data = FileManager.default.contents(atPath: "Dobby/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let domains = plist["WKAppBoundDomains"] as? [String], !domains.isEmpty
        else { check(false, "#245 test setup: Dobby/Info.plist carries WKAppBoundDomains"); return [] }
        return domains
    }

    static let iOSDevice = ServerAddresses.AppBound(enforced: true, loopback: false, domains: shippedDomains())
    static let iOSSimulator = ServerAddresses.AppBound(enforced: true, loopback: true, domains: shippedDomains())
    static let unenforced = ServerAddresses.AppBound(enforced: false, loopback: false, domains: shippedDomains())

    /// The addresses the iOS guard must drop: an IP literal, a LAN name, a non-Tailscale https
    /// name, http to the app-bound name, a look-alike that only starts with it, and loopback.
    static var refused: [URL] {
        let host = AppConfig.serverURL.host!
        return ["http://192.0.2.10:8080", "http://box.home.arpa:8080", "https://dobby.example.com",
                "http://\(host)", "https://\(host).example.com", "http://127.0.0.1:8080"].map { URL(string: $0)! }
    }

    static func appBoundRule() {
        check(iOSDevice.keeps(AppConfig.serverURL), "#245 appBoundRule: iOS keeps the baked https app-bound name")
        check(iOSDevice.keeps(URL(string: "https://" + AppConfig.serverURL.host!.uppercased())!),
              "#245 appBoundRule: iOS keeps the app-bound name in any case")
        for url in refused {
            check(!iOSDevice.keeps(url), "#245 appBoundRule: an iOS device drops \(url.absoluteString)")
        }
        check(iOSSimulator.keeps(URL(string: "http://127.0.0.1:8080")!) && iOSSimulator.keeps(URL(string: "http://localhost:8080")!),
              "#245 appBoundRule: the iOS simulator keeps loopback, where a dev server on the Mac lives")
        check(!iOSSimulator.keeps(URL(string: "http://192.0.2.10:8080")!), "#245 appBoundRule: the simulator still drops an IP literal")
        for url in refused {
            check(unenforced.keeps(url), "#245 appBoundRule: macOS keeps \(url.absoluteString)")
        }
    }

    static func appBoundStoreAndCandidates() {
        let suite = "dobby.check.appBound.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "test defaults suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = AppConfig.serverURL
        let push = "[\"192.0.2.10:8080\", \"https://dobby.example.com\", \"http://box.home.arpa:8080\", \"\(good.absoluteString)\"]"

        ServerAddresses.store(json: push, defaults, rule: iOSDevice)
        check(ServerAddresses.stored(defaults) == [good], "#245 storeFilter: iOS stores only the app-bound entry of a mixed push")
        ServerAddresses.store(json: "[\"192.0.2.10:8080\", \"https://dobby.example.com\"]", defaults, rule: iOSDevice)
        check(ServerAddresses.stored(defaults) == [good], "#245 storeFilter: a push with nothing usable never erases the stored list")
        ServerAddresses.store(refused, defaults, rule: iOSDevice)
        check(ServerAddresses.stored(defaults) == [good], "#245 storeFilter: the native editor path drops the same entries")

        ServerAddresses.store(json: push, defaults, rule: unenforced)
        check(ServerAddresses.stored(defaults).count == 4, "#245 storeFilter: macOS stores every entry of the push")

        // A last known-good and a list written before the guard: skipped on iOS, not cleared.
        defaults.set("http://192.0.2.10:8080", forKey: "dobby.serverAddresses.lastGood")
        check(ServerAddresses.candidates(defaults, rule: iOSDevice) == [good],
              "#245 candidatesSkip: iOS never probes a non-app-bound lastGood or legacy entry, only the app-bound one")
        check(defaults.string(forKey: "dobby.serverAddresses.lastGood") == "http://192.0.2.10:8080"
              && ServerAddresses.piEnabled(defaults),
              "#245 candidatesSkip: the stored lastGood is kept, so an unanswered device stays Pi-enabled")
        check(ServerAddresses.candidates(defaults, rule: unenforced).map(\.absoluteString)
              == ["http://192.0.2.10:8080", "https://dobby.example.com", "http://box.home.arpa:8080", good.absoluteString],
              "#245 candidatesSkip: macOS keeps the order lastGood, list, default with every entry")
        defaults.set(good.absoluteString, forKey: "dobby.serverAddresses.lastGood")
        check(ServerAddresses.candidates(defaults, rule: iOSDevice).first == good,
              "#245 candidatesSkip: an app-bound lastGood still goes first on iOS")
    }

    /// The platform switch itself: this check runs on macOS, where the guard must be off, and
    /// the iOS arm is textual (no iOS runtime here). Both arms pinned.
    static func appBoundPlatformPin() {
        check(!ServerAddresses.AppBound.current.enforced, "#245 platformPin: the guard is off on macOS")
        check(!ServerAddresses.AppBound.current.loopback, "#245 platformPin: loopback is a simulator-only allowance")
        let src = (try? String(contentsOfFile: "Dobby/ServerAddresses.swift", encoding: .utf8)) ?? ""
        for arm in ["        #if os(iOS)\n        static let enforcedHere = true\n        #else\n        static let enforcedHere = false\n        #endif\n",
                    "        #if targetEnvironment(simulator)\n        static let loopbackHere = true\n        #else\n        static let loopbackHere = false\n        #endif\n",
                    "        static let current = AppBound(enforced: enforcedHere, loopback: loopbackHere,\n"] {
            check(src.components(separatedBy: arm).count == 2, "#245 platformPin: ServerAddresses.swift carries \(arm.debugDescription) exactly once")
        }
    }

    /// #245 review: isPiOrigin is identity, not usability. On iOS a stored LAN address of the Pi
    /// is dropped from candidates() but must still count as the Pi, or the #217 Pi-off download
    /// refusal lets it through. The default argument is pinned textually: on this macOS host the
    /// filtered and unfiltered sets are equal, so only the text tells them apart.
    static func piOriginIgnoresTheAppBoundFilter() {
        let suite = "dobby.check.piOrigin.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "test defaults suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["http://192.0.2.10:8080", AppConfig.serverURL.absoluteString], forKey: "dobby.serverAddresses")
        defaults.set("http://198.51.100.20:8080", forKey: "dobby.serverAddresses.lastGood")
        let usable = ServerAddresses.candidates(defaults, rule: iOSDevice)
        check(!usable.contains { ["192.0.2.10", "198.51.100.20"].contains($0.host ?? "") },
              "#245 piOriginUnfiltered: candidates(rule: iOS) excludes the LAN entry and the LAN lastGood")
        let all = ServerAddresses.candidates(defaults, rule: .keepAll)
        for raw in ["http://192.0.2.10:8080/stream/x.mkv", "http://198.51.100.20:8080/x"] {
            check(ServerAddresses.isPiOrigin(raw, candidates: all),
                  "#245 piOriginUnfiltered: with the iOS rule on, \(raw) is still the Pi")
        }
        check(!ServerAddresses.AppBound.keepAll.enforced, "#245 piOriginUnfiltered: keepAll never filters")
        let src = (try? String(contentsOfFile: "Dobby/ServerAddresses.swift", encoding: .utf8)) ?? ""
        let decl = "    static func isPiOrigin(_ raw: String?, candidates: [URL] = candidates(rule: .keepAll)) -> Bool {\n"
        check(src.components(separatedBy: decl).count == 2,
              "#245 piOriginUnfiltered: isPiOrigin defaults to the unfiltered candidates(rule: .keepAll)")
    }
}
