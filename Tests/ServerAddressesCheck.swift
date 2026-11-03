import Foundation

// #508: what is left of ServerAddresses once the Pi is retired: the origin the bundled shell's
// data is keyed to, and the Pi-origin identity rule. No networking, no simulator. Same
// standalone-binary pattern as ApiSchemeHandlerCheck (see its header for why there is no XCTest target).
//
//   ./Tests/run-checks.sh

@main
enum ServerAddressesCheck {
    static func main() {
        normalization()
        piOriginRule()
        appBoundRule()
        originFromStoredKeys()
        appBoundPlatformPin()
        piOriginIgnoresTheAppBoundFilter()
        print("ServerAddressesCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    // MARK: normalize(), which reads every stored address

    static func normalization() {
        check(ServerAddresses.normalize("192.0.2.31:8080")?.absoluteString == "http://192.0.2.31:8080",
              "bare host:port is treated as a LAN box over http")
        check(ServerAddresses.normalize("https://pi.example.ts.net")?.absoluteString
              == "https://pi.example.ts.net", "an explicit https origin round-trips")
        check(ServerAddresses.normalize("ftp://x") == nil, "a non-http(s) scheme is refused")
        check(ServerAddresses.normalize("   ") == nil, "blank input is refused")
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
        check(ServerAddresses.isPiOrigin("/api/subtitles/fetch?provider=x&download=1", candidates: pi), "a page-relative URL is the Pi")
        check(!ServerAddresses.isPiOrigin("https://cdn.example.net/dl/x.mkv", candidates: pi), "a hosted link is not the Pi")
        check(!ServerAddresses.isPiOrigin("http://192.0.2.32:8080/x", candidates: pi), "a neighbouring LAN host is not the Pi")
        check(!ServerAddresses.isPiOrigin("https://pi.example.invalid.cdn.example.net/x", candidates: pi), "a host that only starts like the Pi is not the Pi")
        check(!ServerAddresses.isPiOrigin(nil, candidates: pi), "no URL is nothing to fetch")
        check(!ServerAddresses.isPiOrigin("https://cdn.example.net/x", candidates: []), "no candidates means nothing is the Pi")
    }

    /// #245: the domains the app ships. #491: Dobby/Info.plist carries only the build setting
    /// (the real host is injected at build time), so the check pins that and uses a placeholder.
    static func shippedDomains() -> [String] {
        guard let data = FileManager.default.contents(atPath: "Dobby/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["WKAppBoundDomains"] as? [String] == ["$(DOBBY_PI_HOST)"]
        else { check(false, "#491 test setup: Dobby/Info.plist WKAppBoundDomains is exactly [$(DOBBY_PI_HOST)]"); return [] }
        return [piHost.host!]
    }

    /// Stands in for the injected Pi name (piHost is nil here: no Info.plist).
    static let piHost = URL(string: "https://pi.example.ts.net")!

    static let iOSDevice = ServerAddresses.AppBound(enforced: true, loopback: false, domains: shippedDomains())
    static let iOSSimulator = ServerAddresses.AppBound(enforced: true, loopback: true, domains: shippedDomains())
    static let unenforced = ServerAddresses.AppBound(enforced: false, loopback: false, domains: shippedDomains())

    /// The addresses the iOS guard must drop: an IP literal, a LAN name, a non-Tailscale https
    /// name, http to the app-bound name, a look-alike that only starts with it, and loopback.
    static var refused: [URL] {
        let host = piHost.host!
        return ["http://192.0.2.10:8080", "http://box.home.arpa:8080", "https://dobby.example.com",
                "http://\(host)", "https://\(host).example.com", "http://127.0.0.1:8080"].map { URL(string: $0)! }
    }

    static func appBoundRule() {
        check(iOSDevice.keeps(piHost), "#245 appBoundRule: iOS keeps the baked https app-bound name")
        check(iOSDevice.keeps(URL(string: "https://" + piHost.host!.uppercased())!),
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

    /// #508: the owner-data pin. The origin is the first candidate over the keys earlier builds
    /// wrote, in their order (last known-good, the pushed list, the build's name), which is the
    /// origin the old Pi-less start (`continueOffline`) loaded. The key names are seeded as literals
    /// here, so renaming one, or reordering, moves the origin and fails this.
    static func originFromStoredKeys() {
        let suite = "dobby.check.origin.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "test defaults suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = piHost
        check(ServerAddresses.origin(defaults, rule: iOSDevice) == nil,
              "#508 origin: nothing stored and no build name (no Info.plist here) is no origin")
        defaults.set(["192.0.2.10:8080", "https://dobby.example.com", "http://box.home.arpa:8080", good.absoluteString],
                     forKey: "dobby.serverAddresses")
        check(ServerAddresses.origin(defaults, rule: iOSDevice) == good,
              "#508 origin: on iOS the first app-bound entry of the stored list")
        check(ServerAddresses.origin(defaults, rule: unenforced)?.absoluteString == "http://192.0.2.10:8080",
              "#508 origin: on macOS the first stored entry, LAN address included")
        // #245: a last known-good written before the iOS guard is skipped there, not cleared.
        defaults.set("http://192.0.2.10:8080", forKey: "dobby.serverAddresses.lastGood")
        check(ServerAddresses.candidates(defaults, rule: iOSDevice) == [good],
              "#245 candidatesSkip: iOS never picks a non-app-bound lastGood or legacy entry, only the app-bound one")
        check(defaults.string(forKey: "dobby.serverAddresses.lastGood") == "http://192.0.2.10:8080",
              "#245 candidatesSkip: the stored lastGood is kept, not cleared")
        check(ServerAddresses.candidates(defaults, rule: unenforced).map(\.absoluteString)
              == ["http://192.0.2.10:8080", "https://dobby.example.com", "http://box.home.arpa:8080", good.absoluteString],
              "#245 candidatesSkip: macOS keeps the order lastGood, list, default with every entry")
        defaults.set("https://PI.example.ts.net/some/path", forKey: "dobby.serverAddresses.lastGood")
        check(ServerAddresses.origin(defaults, rule: iOSDevice)?.absoluteString == "https://PI.example.ts.net",
              "#508 origin: the stored last known-good wins, normalized exactly as before (path dropped, host case kept)")
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
        defaults.set(["http://192.0.2.10:8080", piHost.absoluteString], forKey: "dobby.serverAddresses")
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
