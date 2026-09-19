import Foundation

/// Persisted absolute offline-file paths encode the app's data-container UUID at
/// download time (`/var/mobile/Containers/Data/Application/<UUID>/Documents/Offline/…`).
/// iOS assigns a NEW UUID — and relocates the whole Documents directory — to that
/// container on every app update or reinstall (Apple, "File System Programming Guide":
/// an app's data container is not guaranteed to keep the same path across launches,
/// and is explicitly recreated at a new path on update; only the bundle identifier and
/// the files inside survive). The downloaded file itself survives at the same path
/// *relative to* `Documents/Offline`, so re-anchoring onto the CURRENT `root` at read
/// time is enough to keep old `index.json` entries resolving after every future
/// update — no migration/rewrite of the file on disk needed.
///
/// No dependency on `OfflineStore` or any other Dobby type on purpose: this is the
/// one piece of that flow worth unit-testing without dragging in the rest of the
/// download/playback graph (see `Tests/OfflineStorePathCheck.swift`).
func anchorOfflinePath(_ stored: String, root: URL) -> String {
    guard let range = stored.range(of: "/Offline/") else { return stored }
    return root.path + "/" + stored[range.upperBound...]
}
