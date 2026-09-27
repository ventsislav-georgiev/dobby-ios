import Combine
import Foundation
import Network
import os
import Security

/// #237 Type on TV: the phone finds Dobby on a TV over DNS-SD, trades the 6-digit code the TV's
/// Settings guide shows for the TV's link token, keeps that token in the Keychain, and opens the
/// TV's own phone page with it (TvLinkSheet). The TV refuses a Host that is not an IP literal,
/// so every URL is built from the resolved address, never from the service name.
///
/// Nothing here logs or shows an address, port, token or code: logs carry an OSStatus only
/// (a textual guard in Tests/run-checks.sh pins it).
enum TvLink {
    static let serviceType = "_dobby-link._tcp"
    /// Posted by WebBridge for window.Dobby.openTvLink(); ContentView presents the sheet.
    static let open = Notification.Name("DobbyOpenTvLink")
    static let store = TvLinkStore.keychain

    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "tv-link")
    private static let session = URLSession(configuration: .ephemeral)

    struct Address {
        let host: NWEndpoint.Host
        let port: NWEndpoint.Port
    }

    /// The TV's token: 64 lower-case hex digits (PhoneLink.newToken). Anything else is refused.
    static func isToken(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Six ASCII digits, the guide's code.
    static func isCode(_ s: String) -> Bool {
        s.utf8.count == 6 && s.utf8.allSatisfy { (48...57).contains($0) }
    }

    enum Pair: Equatable { case paired(String), wrongCode, closed, refused }

    /// POST /v1/pair's answer. Only a 200 whose JSON says ok true with a well-formed token pairs;
    /// 401 is a wrong code, 409 is no live code (the guide is closed), anything else is refused.
    static func pairAnswer(status: Int, body: Data) -> Pair {
        switch status {
        case 200:
            guard let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  answer["ok"] as? Bool == true,
                  let token = answer["token"] as? String, isToken(token) else { return .refused }
            return .paired(token)
        case 401: return .wrongCode
        case 409: return .closed
        default: return .refused
        }
    }

    /// The pair answer applied to the store: a token is saved and handed back; a wrong code,
    /// a closed guide or a refusal leaves the store exactly as it was.
    static func settle(_ answer: Pair, tv: String, store: TvLinkStore) -> String? {
        guard case .paired(let token) = answer else { return nil }
        let status = store.save(tv, Data(token.utf8))
        if status != errSecSuccess { log.error("tv link token save failed: OSStatus \(status, privacy: .public)") }
        return token
    }

    enum Saved: Equatable { case token(String), none, refused }

    /// #189: only errSecItemNotFound is "not paired". Any other failed read is a refusal: it is
    /// never answered with a new pairing that would overwrite the item.
    static func saved(_ read: (data: Data?, status: OSStatus)) -> Saved {
        if read.status == errSecItemNotFound { return .none }
        guard read.status == errSecSuccess else { return .refused }
        guard let data = read.data, let token = String(data: data, encoding: .utf8), isToken(token) else { return .none }
        return .token(token)
    }

    /// A token-bearing call's HTTP status. 401 means the TV forgot this phone (its token was
    /// rotated): the item is dropped and false says "ask for a new code". Anything else keeps it.
    static func answered(_ http: Int, tv: String, store: TvLinkStore) -> Bool {
        guard http == 401 else { return true }
        let status = store.drop(tv)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("tv link token drop failed: OSStatus \(status, privacy: .public)")
        }
        return false
    }

    /// The host as the TV's Host check accepts it: dotted IPv4, or bracketed IPv6 with no zone.
    /// A link-local IPv6 needs a zone id, which the TV refuses, and a name is refused outright.
    static func hostLiteral(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let a):
            return a.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let a):
            guard a.interface == nil, !a.isLinkLocal else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let text = a.rawValue.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
            return text == nil ? nil : "[" + String(cString: buffer) + "]"
        default:
            return nil
        }
    }

    /// http://<literal>:<port><path>, with the token as the fragment for the page: a fragment
    /// never travels in a request line.
    static func url(_ at: Address, path: String = "/", token: String? = nil) -> URL? {
        guard let literal = hostLiteral(at.host), token.map(isToken) ?? true else { return nil }
        let fragment = token.map { "#" + $0 } ?? ""
        return URL(string: "http://\(literal):\(at.port.rawValue)\(path)\(fragment)")
    }

    /// The service's address. IPv4 first; IPv6 only when no IPv4 path came up.
    static func resolve(_ service: NWEndpoint) async -> Address? {
        for v4 in [true, false] {
            if let at = await remote(service, v4Only: v4), hostLiteral(at.host) != nil { return at }
        }
        return nil
    }

    /// One TCP connection to the service, only to read which address and port it reached.
    private static func remote(_ service: NWEndpoint, v4Only: Bool) async -> Address? {
        let parameters = NWParameters.tcp
        if v4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: service, using: parameters)
        let queue = DispatchQueue(label: "tv-link.resolve")
        return await withCheckedContinuation { done in
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ at: Address?) {
                guard !finished.withLock({ was in defer { was = true }; return was }) else { return }
                connection.cancel()
                done.resume(returning: at)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        finish(Address(host: host, port: port))
                    } else {
                        finish(nil)
                    }
                case .waiting, .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }

    /// POST /v1/pair. nil when the TV did not answer.
    static func pair(code: String, at: Address) async -> Pair? {
        guard isCode(code), let url = url(at, path: "/v1/pair") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])
        guard let (body, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return pairAnswer(status: http.statusCode, body: body)
    }

    /// GET /v1/state with the token, only for its status: does the TV still know this phone?
    /// nil when the TV did not answer.
    static func probe(token: String, at: Address) async -> Int? {
        guard let url = url(at, path: "/v1/state") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue(token, forHTTPHeaderField: "X-Dobby-Link")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return http.statusCode
    }
}

/// The token's Keychain item, one per TV service name, through SettingsMirrorStore's
/// readWithStatus/write. A seam so TvLinkCheck can see what is saved and dropped.
struct TvLinkStore {
    var read: (String) -> (data: Data?, status: OSStatus)
    var save: (String, Data) -> OSStatus
    var drop: (String) -> OSStatus

    static let keychain = TvLinkStore(read: SettingsMirrorStore.tvLinkToken,
                                      save: SettingsMirrorStore.saveTvLinkToken,
                                      drop: SettingsMirrorStore.dropTvLinkToken)
}

/// Dobby TVs on the LAN. A TV advertises only while Dobby is in front on it.
final class TvLinkBrowser: ObservableObject {
    struct Tv: Identifiable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var tvs: [Tv] = []
    @Published private(set) var failed = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: TvLink.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.tvs = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Tv(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.failed = true }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
