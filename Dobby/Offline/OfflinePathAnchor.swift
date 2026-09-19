import Foundation

/// Persisted offline paths are absolute and carry the app data container UUID from
/// download time. That container is relocated by a delete-plus-reinstall and by a
/// dev-signed reinstall (observed in #067 round 3: the stored path named container
/// 949FC145 while the live one differed, 067-device-report.md:536-537), so stored
/// paths are re-anchored onto the current `root` at read time. Writes stay untouched.
func anchorOfflinePath(_ stored: String, root: URL) -> String {
    guard let range = stored.range(of: "/Offline/") else { return stored }
    return root.path + "/" + stored[range.upperBound...]
}
