import Foundation

@main
enum OfflineStorePathCheck {
    static func main() {
        anchorsAStaleContainerPath()
        leavesACurrentPathUnchanged()
        fallsBackWhenNoOfflineMarker()
        print("OfflineStorePathCheck: all checks passed")
    }

    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    /// #125: a video downloaded before an app update was stored under the OLD
    /// container UUID; after the update the container is relocated but the file
    /// itself survives at the same path relative to Documents/Offline. Anchoring
    /// the stale stored path onto the CURRENT root must resolve to that same file.
    static func anchorsAStaleContainerPath() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineStorePathCheck-\(UUID().uuidString)", isDirectory: true)
        let root = tmp.appendingPathComponent("Documents/Offline", isDirectory: true)
        let videoDir = root.appendingPathComponent("tt1|series|1|1", isDirectory: true)
        try! FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
        let videoFile = videoDir.appendingPathComponent("video.mkv")
        try! Data("fake video bytes".utf8).write(to: videoFile)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let staleContainer = "/var/mobile/Containers/Data/Application/00000000-0000-0000-0000-000000000000"
        let stalePath = staleContainer + "/Documents/Offline/tt1|series|1|1/video.mkv"
        check(!FileManager.default.fileExists(atPath: stalePath),
              "test setup is broken: the stale (old-container) path must not exist on disk")

        let anchored = anchorOfflinePath(stalePath, root: root)
        check(anchored == videoFile.path,
              "anchored path does not point at the file under the CURRENT container: got \(anchored)")
        check(FileManager.default.fileExists(atPath: anchored),
              "anchored path does not resolve to a file on disk (#125 regression)")

        let uri = "file://" + anchored
        check(uri == "file://" + videoFile.path, "uri built from the anchored path is wrong")
    }

    /// A path already under the current root (the common case — no update happened
    /// since download) must come back byte-identical, not rebuilt into something else.
    static func leavesACurrentPathUnchanged() {
        let root = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/CURRENT-UUID/Documents/Offline")
        let current = root.appendingPathComponent("tt2/video.mp4").path
        check(anchorOfflinePath(current, root: root) == current,
              "a path already under the current root must come back unchanged")
    }

    /// No "/Offline/" marker at all (shouldn't happen for a real stored entry) — fail
    /// safe by returning the input unchanged rather than guessing.
    static func fallsBackWhenNoOfflineMarker() {
        let root = URL(fileURLWithPath: "/whatever/Documents/Offline")
        let weird = "/some/unrelated/path/video.mp4"
        check(anchorOfflinePath(weird, root: root) == weird,
              "a stored path with no /Offline/ marker should be returned as-is")
    }
}
