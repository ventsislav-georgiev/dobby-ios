import Foundation
import Security
import os

/// #639: the core's key-value store (account tokens, settings blobs), one Keychain item per key under
/// its own service, so no key can collide with the settings mirror. The core calls `get`/`put` from its
/// own thread through the C callbacks in CoreBridge; this file has no core import so Tests/run-checks.sh
/// compiles it alone.
///
/// Refused is not absent: only errSecItemNotFound reads as empty. A refused read (a locked device,
/// entitlement drift) still answers nil, the only "no value" the C API has, but marks the key, and a put
/// to a marked key re-reads first and is dropped while the Keychain still refuses: the core built that
/// write on a blind read, so it would overwrite or delete the one good copy (the #185 lesson).
final class CoreStore {
    typealias Read = (_ key: String) -> (data: Data?, status: OSStatus)
    /// nil value deletes.
    typealias Write = (_ key: String, _ value: Data?) -> OSStatus

    private let read: Read
    private let write: Write
    private var refused = Set<String>()
    private let lock = NSLock()
    private static let log = Logger(subsystem: "eu.illegible.dobbyios", category: "core-store")

    init(read: @escaping Read, write: @escaping Write) {
        self.read = read
        self.write = write
    }

    func get(_ key: String) -> String? {
        let r = read(key)
        lock.lock(); defer { lock.unlock() }
        switch r.status {
        case errSecSuccess:
            refused.remove(key)
            return r.data.map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound:
            refused.remove(key)
            return nil
        default:
            refused.insert(key)
            Self.log.error("core store read refused: \(key, privacy: .public) OSStatus \(r.status, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func put(_ key: String, _ value: String?) -> OSStatus {
        lock.lock(); let blind = refused.contains(key); lock.unlock()
        if blind {
            let status = read(key).status
            guard status == errSecSuccess || status == errSecItemNotFound else {
                Self.log.error("core store write dropped after a refused read: \(key, privacy: .public) OSStatus \(status, privacy: .public)")
                return status
            }
            lock.lock(); refused.remove(key); lock.unlock()
        }
        let status = write(key, value.map { Data($0.utf8) })
        if status != errSecSuccess {
            Self.log.error("core store write failed: \(key, privacy: .public) OSStatus \(status, privacy: .public)")
        }
        return status
    }

    /// The app's store: AfterFirstUnlock like the settings mirror, update first and add only when the
    /// update found no item, so a refused update never destroys the stored copy.
    static let keychain = CoreStore(read: { key in
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return (status == errSecSuccess ? item as? Data : nil, status)
    }, write: { key, value in
        guard let value else {
            let status = SecItemDelete(query(key) as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let attributes: [String: Any] = [kSecValueData as String: value,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let updated = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        return SecItemAdd(query(key).merging(attributes) { _, new in new } as CFDictionary, nil)
    })

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "eu.illegible.dobbyios.core",
         kSecAttrAccount as String: key]
    }
}
