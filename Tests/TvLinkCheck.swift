import Foundation
import Network
import Security
import WebKit

/// #237 Type on TV, the pure parts: the pair answer, the Keychain decisions (a 401 drops the item,
/// a refusal never does, a refused read is not "not paired"), and the URL the TV's Host check
/// accepts. #248: the QR payload parser, the scanned address against the picked TV's, the key's
/// save and drop beside the token's, and the #token.key fragment. Fake values only: a token of
/// 64 'a', a key of 64 'b', code 123456, addresses from the documentation ranges. The store is a
/// fake that records what it was asked; the real Keychain is not touched.
@main
enum TvLinkCheck {
    static func main() {
        let checks: [(String, () -> Void)] = [
            ("pairAnswerTakesOnlyAWellFormedToken", pairAnswerTakesOnlyAWellFormedToken),
            ("pairRefusalsLeaveTheStoreAlone", pairRefusalsLeaveTheStoreAlone),
            ("aTokenCall401DropsTheTokenAndTheKey", aTokenCall401DropsTheTokenAndTheKey),
            ("onlyItemNotFoundIsNotPaired", onlyItemNotFoundIsNotPaired),
            ("aSavedTokenOpensWithOrWithoutAKey", aSavedTokenOpensWithOrWithoutAKey),
            ("urlIsAnIpLiteralTheTvAccepts", urlIsAnIpLiteralTheTvAccepts),
            ("urlCarriesTheKeyOnlyBesideAToken", urlCarriesTheKeyOnlyBesideAToken),
            ("scannedTakesOnlyTheGuideQrShape", scannedTakesOnlyTheGuideQrShape),
            ("aScanMustMatchThePickedTv", aScanMustMatchThePickedTv),
            ("aScanKeepsTheTokenAndTheKey", aScanKeepsTheTokenAndTheKey),
            ("codeIsSixAsciiDigits", codeIsSixAsciiDigits),
            ("thePageKeepsNothing", thePageKeepsNothing),
        ]
        let only = Set(CommandLine.arguments.dropFirst())
        for (name, run) in checks where only.isEmpty || only.contains(name) {
            running = name
            run()
        }
        print("TvLinkCheck: all checks passed")
    }

    static var running = ""

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(running): \(what) (#237, #248)\n".utf8))
            exit(1)
        }
    }

    static let token = String(repeating: "a", count: 64)
    static let key = String(repeating: "b", count: 64)

    /// A store that records every call and answers with the given statuses. The key's calls are
    /// recorded apart from the token's.
    final class Fake {
        var saved: [(String, Data)] = []
        var dropped: [String] = []
        var savedKeys: [(String, Data)] = []
        var droppedKeys: [String] = []
        var dropStatus: OSStatus = errSecSuccess
        var untouched: Bool { saved.isEmpty && dropped.isEmpty && savedKeys.isEmpty && droppedKeys.isEmpty }
        var store: TvLinkStore {
            TvLinkStore(read: { _ in (nil, errSecItemNotFound) },
                        save: { self.saved.append(($0, $1)); return errSecSuccess },
                        drop: { self.dropped.append($0); return self.dropStatus },
                        readKey: { _ in (nil, errSecItemNotFound) },
                        saveKey: { self.savedKeys.append(($0, $1)); return errSecSuccess },
                        dropKey: { self.droppedKeys.append($0); return self.dropStatus })
        }
    }

    static func body(_ json: String) -> Data { Data(json.utf8) }

    static func pairAnswerTakesOnlyAWellFormedToken() {
        check(TvLink.pairAnswer(status: 200, body: body("{\"ok\":true,\"token\":\"\(token)\"}")) == .paired(token),
              "a 200 with ok true and a 64 lower-case hex token must pair")
        check(TvLink.pairAnswer(status: 200, body: body("{\"ok\":true,\"token\":\"\(token)\",\"tv\":\"x\",\"v\":2}")) == .paired(token),
              "extra fields in a 200 pair answer must be ignored")
        let refused: [(String, String)] = [
            ("{\"ok\":true,\"token\":\"\(String(token.dropLast()))\"}", "a 63-digit token"),
            ("{\"ok\":true,\"token\":\"\(token)a\"}", "a 65-digit token"),
            ("{\"ok\":true,\"token\":\"\(token.uppercased())\"}", "an upper-case hex token"),
            ("{\"ok\":true,\"token\":\"\(String(repeating: "g", count: 64))\"}", "a non-hex token"),
            ("{\"ok\":true,\"token\":\"\(String(repeating: "a", count: 63)) \"}", "a token with a space"),
            ("{\"ok\":false,\"token\":\"\(token)\"}", "ok false"),
            ("{\"token\":\"\(token)\"}", "no ok"),
            ("{\"ok\":true}", "no token"),
            ("{\"ok\":true,\"token\":7}", "a number token"),
            ("[\"\(token)\"]", "an array"),
            ("not json", "a non-JSON body"),
            ("", "an empty body"),
        ]
        for (json, what) in refused {
            check(TvLink.pairAnswer(status: 200, body: body(json)) == .refused, "a 200 pair answer with \(what) must be refused")
        }
        let good = body("{\"ok\":true,\"token\":\"\(token)\"}")
        for status in [201, 204, 400, 403, 404, 405, 500] {
            check(TvLink.pairAnswer(status: status, body: good) == .refused, "a \(status) pair answer must be refused, token or not")
        }
        check(TvLink.pairAnswer(status: 401, body: body("{\"ok\":false,\"error\":\"code\"}")) == .wrongCode, "401 is a wrong code")
        check(TvLink.pairAnswer(status: 409, body: body("{\"ok\":false,\"error\":\"closed\"}")) == .closed, "409 is a closed guide")
        check(TvLink.pairAnswer(status: 429, body: body("{\"ok\":false,\"error\":\"busy\"}")) == .busy,
              "429 is the TV's lockout or rate limit (busy), not a refusal")
        check(TvLink.pairAnswer(status: 400, body: body("{\"ok\":false,\"error\":\"json\"}")) == .refused, "400 is refused")
    }

    static func pairRefusalsLeaveTheStoreAlone() {
        for answer in [TvLink.Pair.wrongCode, .closed, .busy, .refused] {
            let fake = Fake()
            check(TvLink.settle(answer, tv: "Dobby Fake TV", store: fake.store) == nil, "\(answer) must not pair")
            check(fake.untouched, "\(answer) must leave the store as it was")
        }
        for (status, json) in [(409, "{\"ok\":false,\"error\":\"closed\"}"), (400, "{\"ok\":false,\"error\":\"host\"}"),
                               (429, "{\"ok\":false,\"error\":\"busy\"}"),
                               (401, "{\"ok\":false,\"error\":\"code\"}")] {
            let fake = Fake()
            let answer = TvLink.pairAnswer(status: status, body: body(json))
            check(TvLink.settle(answer, tv: "Dobby Fake TV", store: fake.store) == nil && fake.untouched,
                  "a \(status) from /v1/pair must be not paired, with nothing saved or dropped")
        }
        let fake = Fake()
        check(TvLink.settle(.paired(token), tv: "Dobby Fake TV", store: fake.store) == token, "a pairing hands the token back")
        check(fake.saved.count == 1 && fake.saved[0].0 == "Dobby Fake TV" && fake.saved[0].1 == Data(token.utf8) && fake.dropped.isEmpty,
              "a pairing saves the token under the TV's name and drops nothing")
        check(fake.savedKeys.isEmpty && fake.droppedKeys.isEmpty, "a code pairing has no key to save and drops none")
    }

    static func aTokenCall401DropsTheTokenAndTheKey() {
        let fake = Fake()
        check(!TvLink.answered(401, tv: "Dobby Fake TV", store: fake.store), "a 401 must say ask for a new code")
        check(fake.dropped == ["Dobby Fake TV"] && fake.saved.isEmpty, "a 401 must drop that TV's token and save nothing")
        check(fake.droppedKeys == ["Dobby Fake TV"] && fake.savedKeys.isEmpty,
              "a 401 must drop that TV's key too: the TV rotates the token and the key together")
        let refusing = Fake()
        refusing.dropStatus = errSecInteractionNotAllowed
        check(!TvLink.answered(401, tv: "Dobby Fake TV", store: refusing.store) && refusing.dropped == ["Dobby Fake TV"]
              && refusing.droppedKeys == ["Dobby Fake TV"],
              "a 401 asks for a new code, and tries both drops, even when a drop is refused")
        for status in [200, 204, 400, 403, 404, 405, 409, 429, 500] {
            let kept = Fake()
            check(TvLink.answered(status, tv: "Dobby Fake TV", store: kept.store) && kept.untouched,
                  "a \(status) must keep the token and the key")
        }
    }

    static let noKey: (data: Data?, status: OSStatus) = (nil, errSecItemNotFound)

    static func onlyItemNotFoundIsNotPaired() {
        check(TvLink.saved((nil, errSecItemNotFound), key: noKey) == .none, "errSecItemNotFound is not paired")
        check(TvLink.saved((nil, errSecItemNotFound), key: (Data(key.utf8), errSecSuccess)) == .none,
              "a key without a token is not a pairing")
        check(TvLink.saved((Data(token.utf8), errSecSuccess), key: noKey) == .token(token, key: nil), "a stored token is read back")
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement, errSecNotAvailable, OSStatus(-1)] {
            check(TvLink.saved((nil, status), key: noKey) == .refused, "a read refused with \(status) must not read as not paired")
            check(TvLink.saved((Data(token.utf8), errSecSuccess), key: (nil, status)) == .refused,
                  "a key read refused with \(status) must not read as no key")
        }
    }

    /// A token with the key opens the page able to send Settings; a token alone (a #237 code
    /// pairing) still opens it, search-only; a malformed key item reads as no key.
    static func aSavedTokenOpensWithOrWithoutAKey() {
        let t: (data: Data?, status: OSStatus) = (Data(token.utf8), errSecSuccess)
        check(TvLink.saved(t, key: (Data(key.utf8), errSecSuccess)) == .token(token, key: key), "a stored token and key are read back")
        check(TvLink.saved(t, key: noKey) == .token(token, key: nil), "a token with no key item still opens, search-only")
        for bad in [String(key.dropLast()), key.uppercased(), key + "b", "", token + "." + key] {
            check(TvLink.saved(t, key: (Data(bad.utf8), errSecSuccess)) == .token(token, key: nil),
                  "a malformed key item must read as no key, the token still opening")
        }
    }

    static func urlIsAnIpLiteralTheTvAccepts() {
        // PhoneLink.IP_LITERAL_HOST, the TV's Host check, transcribed.
        let hostRule = try! NSRegularExpression(pattern: #"^(\d{1,3}(\.\d{1,3}){3}|\[[0-9A-Fa-f:.]+\])(:\d{1,5})?$"#)
        func hostHeader(_ url: URL) -> String {
            String(url.absoluteString.dropFirst("http://".count).prefix { $0 != "/" })
        }
        func accepted(_ url: URL) -> Bool {
            let h = hostHeader(url)
            return hostRule.firstMatch(in: h, range: NSRange(h.startIndex..., in: h)) != nil
        }
        let port = NWEndpoint.Port(rawValue: 8080)!
        let v4 = TvLink.Address(host: .ipv4(IPv4Address("192.0.2.1")!), port: port)
        check(TvLink.url(v4, token: token)?.absoluteString == "http://192.0.2.1:8080/#\(token)",
              "IPv4: http://<literal>:<port>/#<token>")
        check(TvLink.url(v4, path: "/v1/pair")?.absoluteString == "http://192.0.2.1:8080/v1/pair", "IPv4 route, no fragment")
        let v6 = TvLink.Address(host: .ipv6(IPv6Address("2001:db8::1")!), port: port)
        check(TvLink.url(v6, token: token)?.absoluteString == "http://[2001:db8::1]:8080/#\(token)",
              "IPv6: bracketed literal, no zone")
        for url in [TvLink.url(v4, token: token), TvLink.url(v6, path: "/v1/pair")].compactMap({ $0 }) {
            check(accepted(url), "the TV's Host rule must accept the URL's host and port")
        }
        check(TvLink.url(v4, token: token)?.fragment == token && TvLink.url(v4, token: token)?.path == "/",
              "the token rides only in the fragment")
        for (host, what) in [(NWEndpoint.Host.ipv6(IPv6Address("fe80::1%lo0")!), "a zone-id link-local IPv6"),
                             (.ipv6(IPv6Address("fe80::1")!), "a link-local IPv6 (it needs a zone)"),
                             (.ipv6(IPv6Address("2001:db8::1%lo0")!), "an IPv6 with a zone"),
                             (.name("dobby-tv.example", nil), "a host name")] {
            check(TvLink.hostLiteral(host) == nil && TvLink.url(TvLink.Address(host: host, port: port), token: token) == nil,
                  "\(what) must be refused")
        }
        check(TvLink.url(v4, token: token.uppercased()) == nil && TvLink.url(v4, token: "a") == nil,
              "a malformed token never reaches the fragment")
    }

    static let v4 = TvLink.Address(host: .ipv4(IPv4Address("192.0.2.1")!), port: NWEndpoint.Port(rawValue: 8080)!)

    static func urlCarriesTheKeyOnlyBesideAToken() {
        check(TvLink.url(v4, token: token, key: key)?.absoluteString == "http://192.0.2.1:8080/#\(token).\(key)",
              "with a key the fragment is token.key, the shape the page reads the settings key from")
        check(TvLink.url(v4, token: token, key: key)?.path == "/", "the key rides only in the fragment")
        check(TvLink.url(v4, token: token, key: nil)?.absoluteString == "http://192.0.2.1:8080/#\(token)",
              "without a key the fragment is the token alone")
        for bad in [String(key.dropLast()), key.uppercased(), key + "b", String(repeating: "g", count: 64), "", "x.y", key + "#"] {
            check(TvLink.url(v4, token: token, key: bad) == nil, "a key that is not 64 lower-case hex must never reach the fragment")
        }
        check(TvLink.url(v4, key: key) == nil && TvLink.url(v4, path: "/v1/state", key: key) == nil,
              "a key without a token must never reach a URL")
    }

    static var payload: String { "http://192.0.2.1:8080/#\(token).\(key)" }

    static func scannedTakesOnlyTheGuideQrShape() {
        let good = TvLink.Scanned(host: "192.0.2.1", port: 8080, token: token, key: key)
        check(TvLink.scanned(payload) == good, "the guide's QR payload is read")
        check(TvLink.scanned("http://192.0.2.1:8080#\(token).\(key)") == good, "an empty path is the root")
        check(TvLink.scanned("http://[2001:db8::1]:8080/#\(token).\(key)")?.host == "[2001:db8::1]",
              "a bracketed IPv6 as hostLiteral writes it is read")
        check(TvLink.scanned("http://192.0.2.254:1/#\(token).\(key)")?.port == 1
              && TvLink.scanned("http://192.0.2.254:65535/#\(token).\(key)")?.port == 65535, "the port range ends are read")
        let refused: [(String, String)] = [
            ("https://192.0.2.1:8080/#\(token).\(key)", "https"),
            ("HTTP://192.0.2.1:8080/#\(token).\(key)", "an upper-case scheme"),
            ("ftp://192.0.2.1:8080/#\(token).\(key)", "another scheme"),
            ("//192.0.2.1:8080/#\(token).\(key)", "no scheme"),
            ("http://tv.example.com:8080/#\(token).\(key)", "a hostname"),
            ("http://localhost:8080/#\(token).\(key)", "localhost"),
            ("http://192.0.2:8080/#\(token).\(key)", "a short IPv4"),
            ("http://192.0.2.01:8080/#\(token).\(key)", "an IPv4 with a leading zero"),
            ("http://192.0.2.256:8080/#\(token).\(key)", "an IPv4 octet over 255"),
            ("http://3221225985:8080/#\(token).\(key)", "an IPv4 as one number"),
            ("http://[2001:DB8::1]:8080/#\(token).\(key)", "an IPv6 not as hostLiteral writes it"),
            ("http://[fe80::1]:8080/#\(token).\(key)", "a link-local IPv6"),
            ("http://2001:db8::1:8080/#\(token).\(key)", "an unbracketed IPv6"),
            ("http://192.0.2.1/#\(token).\(key)", "no port"),
            ("http://192.0.2.1:/#\(token).\(key)", "an empty port"),
            ("http://192.0.2.1:0/#\(token).\(key)", "port 0"),
            ("http://192.0.2.1:65536/#\(token).\(key)", "a port over 65535"),
            ("http://192.0.2.1:08080/#\(token).\(key)", "a port with a leading zero"),
            ("http://192.0.2.1:+8080/#\(token).\(key)", "a signed port"),
            ("http://192.0.2.1:8080/x#\(token).\(key)", "an extra path"),
            ("http://192.0.2.1:8080//#\(token).\(key)", "a double slash path"),
            ("http://192.0.2.1:8080/?a=1#\(token).\(key)", "a query"),
            ("http://192.0.2.1:8080/?#\(token).\(key)", "an empty query"),
            ("http://user@192.0.2.1:8080/#\(token).\(key)", "userinfo"),
            ("http://user:pw@192.0.2.1:8080/#\(token).\(key)", "userinfo with a password"),
            ("http://192.0.2.1:8080/", "no fragment"),
            ("http://192.0.2.1:8080/#", "an empty fragment"),
            ("http://192.0.2.1:8080/#\(token)", "the token alone"),
            ("http://192.0.2.1:8080/#\(token).", "an empty key"),
            ("http://192.0.2.1:8080/#.\(key)", "an empty token"),
            ("http://192.0.2.1:8080/#\(token).\(String(key.dropLast()))", "a short key"),
            ("http://192.0.2.1:8080/#\(token).\(key)b", "a long key"),
            ("http://192.0.2.1:8080/#\(token).\(key.uppercased())", "an upper-case key"),
            ("http://192.0.2.1:8080/#\(token.uppercased()).\(key)", "an upper-case token"),
            ("http://192.0.2.1:8080/#\(String(token.dropLast())).\(key)", "a short token"),
            ("http://192.0.2.1:8080/#\(token).\(String(repeating: "g", count: 64))", "a non-hex key"),
            ("http://192.0.2.1:8080/#\(token).\(key).\(key)", "a third part"),
            ("http://192.0.2.1:8080/#\(token)\(key)", "no dot"),
            ("http://192.0.2.1:8080/#\(token).\(key)\n", "a trailing newline"),
            ("http://192.0.2.1:8080/#\(token).\(key) ", "a trailing space"),
            (" http://192.0.2.1:8080/#\(token).\(key)", "a leading space"),
            ("http://192.0.2.1:8080/#\(token).\(key)#x", "a second fragment"),
            ("http://192.0.2.1:8080/#\(token).\(key)?a=1", "a query after the fragment"),
            ("http://192.0.2.1:8080/#\(token).\(key)&x", "trailing junk"),
            ("http://192.0.2.1:8080/#\(token)%2E\(key)", "an encoded dot"),
            ("", "an empty payload"),
            ("123456", "a code"),
        ]
        for (text, what) in refused {
            check(TvLink.scanned(text) == nil, "a QR payload with \(what) must be refused")
        }
    }

    static func aScanMustMatchThePickedTv() {
        let scan = TvLink.scanned(payload)!
        check(TvLink.matches(scan, v4), "the picked TV's own QR matches")
        let other: [(TvLink.Address, String)] = [
            (TvLink.Address(host: .ipv4(IPv4Address("192.0.2.2")!), port: v4.port), "another host"),
            (TvLink.Address(host: v4.host, port: NWEndpoint.Port(rawValue: 8081)!), "another port"),
            (TvLink.Address(host: .ipv6(IPv6Address("2001:db8::1")!), port: v4.port), "an IPv6 path to the TV"),
            (TvLink.Address(host: .name("tv.example.com", nil), port: v4.port), "a name"),
        ]
        for (at, what) in other {
            check(!TvLink.matches(scan, at), "a QR must not match \(what)")
            let fake = Fake()
            check(TvLink.keep(payload, tv: "Dobby Fake TV", at: at, store: fake.store) == .otherTv && fake.untouched,
                  "a QR for \(what) must be another TV's, with nothing saved or dropped")
        }
        for text in ["https://192.0.2.1:8080/#\(token).\(key)", "http://192.0.2.1:8080/#\(token)", "123456"] {
            let fake = Fake()
            check(TvLink.keep(text, tv: "Dobby Fake TV", at: v4, store: fake.store) == .notALink && fake.untouched,
                  "a QR that is not the guide's must save nothing")
        }
    }

    static func aScanKeepsTheTokenAndTheKey() {
        let fake = Fake()
        check(TvLink.keep(payload, tv: "Dobby Fake TV", at: v4, store: fake.store) == .kept(token: token, key: key),
              "the picked TV's QR hands the token and the key back")
        check(fake.saved.count == 1 && fake.saved[0].0 == "Dobby Fake TV" && fake.saved[0].1 == Data(token.utf8),
              "a scan saves the token under the TV's name")
        check(fake.savedKeys.count == 1 && fake.savedKeys[0].0 == "Dobby Fake TV" && fake.savedKeys[0].1 == Data(key.utf8),
              "a scan saves the key as its own item under the TV's name")
        check(fake.dropped.isEmpty && fake.droppedKeys.isEmpty, "a scan drops nothing")
        let refusing = Fake()
        let store = refusing.store
        let saveRefused = TvLinkStore(read: store.read, save: { _, _ in errSecInteractionNotAllowed }, drop: store.drop,
                                      readKey: store.readKey, saveKey: { _, _ in errSecInteractionNotAllowed }, dropKey: store.dropKey)
        check(TvLink.keep(payload, tv: "Dobby Fake TV", at: v4, store: saveRefused) == .kept(token: token, key: key),
              "a refused save still opens this page with the scan (the next open asks again)")
    }

    static func codeIsSixAsciiDigits() {
        check(TvLink.isCode("123456"), "six digits is a code")
        for bad in ["12345", "1234567", "12345a", "", " 12345", "１２３４５６", "12 456"] {
            check(!TvLink.isCode(bad), "\(bad.debugDescription) is not a code")
        }
    }

    /// The TV's page runs in a non-persistent store: no cookie, storage or cache outlives the sheet.
    static func thePageKeepsNothing() {
        check(!TvLinkPage.configuration().websiteDataStore.isPersistent, "the TV page must not persist anything")
    }
}
