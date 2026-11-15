import Foundation
import Security

/// #639: the core lane's host-side rules, no network and no Keychain: the store maps a refused read apart
/// from an absent one (simulated statuses), the scheme path maps to the core's /api/smarttube path, and
/// the playback/proxy descriptor becomes the upstream request with the page's Range (and POST body).
@main
enum CoreLaneCheck {
    static func main() {
        refusedReadIsNotAbsent()
        schemePathMapsToTheCorePath()
        proxyDescriptorForwardsRange()
        print("CoreLaneCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what) (#639)\n".utf8))
            exit(1)
        }
    }

    final class FakeKeychain {
        var items: [String: Data] = [:]
        var readStatus: OSStatus? // nil: answer from items
        var writes: [String] = []
        lazy var store = CoreStore(read: { [unowned self] key in
            if let s = self.readStatus { return (nil, s) }
            return self.items[key].map { ($0, errSecSuccess) } ?? (nil, errSecItemNotFound)
        }, write: { [unowned self] key, value in
            self.writes.append(key); self.items[key] = value; return errSecSuccess
        })
    }

    static func refusedReadIsNotAbsent() {
        let k = FakeKeychain()
        k.items["account"] = Data("fake-token-1".utf8)
        check(k.store.get("account") == "fake-token-1", "a stored value reads back")
        check(k.store.get("missing") == nil, "an absent key reads nil")
        k.store.put("missing", "v")
        check(k.writes == ["missing"], "a put after an absent read is written")

        k.readStatus = errSecInteractionNotAllowed
        check(k.store.get("account") == nil, "a refused read still answers nil (the C API has no other no-value)")
        k.store.put("account", nil)
        k.store.put("account", "fake-blank")
        check(k.writes == ["missing"] && k.items["account"] == Data("fake-token-1".utf8),
              "a put or delete after a refused read must not touch the stored value while the Keychain refuses")

        k.readStatus = nil
        k.store.put("account", "fake-token-2")
        check(k.items["account"] == Data("fake-token-2".utf8), "once the Keychain answers again, the put lands")
    }

    static func schemePathMapsToTheCorePath() {
        let t = ApiSchemeHandler.corePath(URL(string: "dobby-api://smarttube/channels/UC%2Fx?continuation=a%3D&b=1")!)
        check(t.path == "/api/smarttube/channels/UC%2Fx" && t.query == "continuation=a%3D&b=1",
              "the scheme URL maps to /api/smarttube/<path> with path and query still encoded: \(t)")
        let bare = ApiSchemeHandler.corePath(URL(string: "dobby-api://smarttube/config")!)
        check(bare.path == "/api/smarttube/config" && bare.query == nil, "no query maps to nil: \(bare)")
    }

    static func proxyDescriptorForwardsRange() {
        let up = "https://rr1.example.googlevideo.com/videoplayback?id=fake&c=IOS"
        let reply = ApiSchemeHandler.CoreReply(status: 307, headers: [
            "Location": up, "Cache-Control": "no-store",
            "X-Ytcore-Upstream-User-Agent": "fake-ua", "X-Ytcore-Upstream-Referer": "https://www.youtube.com/",
        ], body: Data())
        let get = ApiSchemeHandler.upstreamRequest(reply, method: "GET", range: "bytes=100-", body: nil)
        check(get?.url?.absoluteString == up, "the upstream URL is the descriptor's Location")
        check(get?.value(forHTTPHeaderField: "Range") == "bytes=100-", "the page's Range must be forwarded upstream")
        check(get?.value(forHTTPHeaderField: "User-Agent") == "fake-ua"
              && get?.value(forHTTPHeaderField: "Referer") == "https://www.youtube.com/"
              && get?.value(forHTTPHeaderField: "X-Ytcore-Upstream-User-Agent") == nil
              && get?.value(forHTTPHeaderField: "Cache-Control") == nil,
              "the upstream headers are sent under their own names, nothing else of the descriptor")
        check(get?.httpMethod == "GET", "a GET stays a GET")
        let post = ApiSchemeHandler.upstreamRequest(reply, method: "POST", range: nil, body: Data("fake-body".utf8))
        check(post?.httpMethod == "POST" && post?.httpBody == Data("fake-body".utf8)
              && post?.value(forHTTPHeaderField: "Range") == nil, "a POST forwards its body and no invented Range")
        let refused = ApiSchemeHandler.CoreReply(status: 400, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        check(ApiSchemeHandler.upstreamRequest(refused, method: "GET", range: "bytes=0-", body: nil) == nil,
              "a 400 passes through, no upstream fetch")
        let odd = ApiSchemeHandler.CoreReply(status: 307, headers: ["Location": "file:///etc/hosts"], body: Data())
        check(ApiSchemeHandler.upstreamRequest(odd, method: "GET", range: nil, body: nil) == nil, "only http(s) is fetched")
    }
}
