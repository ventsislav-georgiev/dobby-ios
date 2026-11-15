import Foundation
import YtCore

/// #639: the core package in-process. One isolate per process, and every call from the one thread
/// that created it: a dedicated 16 MB-stack thread (the 512 KB secondary-thread default overflows in
/// native-image code) draining a FIFO of jobs, so calls are serial. Started on first use; the store
/// callbacks below run on that same thread, inside a request.
final class CoreBridge {
    static let shared = CoreBridge()

    private let store = CoreStore.keychain
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []
    /// Set once on the core thread before the first job runs; read only on it.
    private var thread: OpaquePointer?

    private init() {
        let worker = Thread { [unowned self] in self.run() }
        worker.name = "core"
        worker.stackSize = 16 << 20
        worker.qualityOfService = .userInitiated
        worker.start()
    }

    /// One request; `done` runs on the core thread. `query` is the still-encoded query string.
    func request(_ method: String, _ path: String, _ query: String?, _ body: Data?, _ headers: [String: String],
                 _ done: @escaping (ApiSchemeHandler.CoreReply) -> Void) {
        cond.lock()
        jobs.append { [unowned self] in done(self.call(method, path, query, body, headers)) }
        cond.signal()
        cond.unlock()
    }

    private func run() {
        var isolate: OpaquePointer?
        var th: OpaquePointer?
        if graal_create_isolate(nil, &isolate, &th) == 0, th != nil,
           ytcore_init_store(th, Unmanaged.passUnretained(store).toOpaque(), coreGet, corePut) == 0 {
            thread = th
        }
        while true {
            cond.lock()
            while jobs.isEmpty { cond.wait() }
            let job = jobs.removeFirst()
            cond.unlock()
            job()
        }
    }

    private func call(_ method: String, _ path: String, _ query: String?, _ body: Data?,
                      _ headers: [String: String]) -> ApiSchemeHandler.CoreReply {
        guard let th = thread else { return .init(status: 503, headers: [:], body: Data(#"{"error":"core unavailable"}"#.utf8)) }
        let hj = String(decoding: (try? JSONSerialization.data(withJSONObject: headers)) ?? Data("{}".utf8), as: UTF8.self)
        let payload = body ?? Data()
        let r: UnsafeMutablePointer<ytcore_response>? = payload.withUnsafeBytes { b in
            ytcore_request(th, method, path, query, body == nil ? nil : b.baseAddress, UInt64(b.count), hj)
        }
        guard let r else { return .init(status: 502, headers: [:], body: Data(#"{"error":"core failed"}"#.utf8)) }
        defer { ytcore_free(th, UnsafeMutableRawPointer(r)) }
        let p = r.pointee
        let h = p.headers_len == 0 ? [:] : (try? JSONSerialization.jsonObject(
            with: Data(bytes: p.headers_json, count: Int(p.headers_len)))) as? [String: String] ?? [:]
        let out = p.body_len == 0 ? Data() : Data(bytes: p.body, count: Int(p.body_len))
        return .init(status: Int(p.status), headers: h, body: out)
    }
}

/// The core frees what get returns (malloc'd via strdup); NULL is "no value".
private let coreGet: ytcore_get_fn = { ctx, key in
    guard let ctx, let key else { return nil }
    return Unmanaged<CoreStore>.fromOpaque(ctx).takeUnretainedValue().get(String(cString: key)).flatMap { strdup($0) }
}

private let corePut: ytcore_put_fn = { ctx, key, value in
    guard let ctx, let key else { return }
    Unmanaged<CoreStore>.fromOpaque(ctx).takeUnretainedValue().put(String(cString: key), value.map { String(cString: $0) })
}
