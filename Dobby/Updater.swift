#if os(macOS)
import AppKit
import Sparkle

/// #464: the DMG build's self-update, Sparkle 2 shaped like the APK's UpdateChecker: a check
/// every 6 h (Info.plist SUScheduledCheckInterval), a silent background download, then a
/// Later/Install alert once the update is on disk. Later leaves it to Sparkle, which installs
/// on the next quit. "Check for Updates..." in the app menu is the forced check (checkNow).
///
/// The appcast and the DMG sit behind the same header token as the APK's manifest, so every
/// Sparkle request carries the APK's three headers. Feed URL, token and EdDSA public key are
/// build settings only scripts/mac-release.sh fills; a build missing any starts no updater,
/// the analogue of the APK's offReason for a debug or tokenless build.
///
/// The PWA's version stamp shows the state through the APK's contract (#460/#461):
/// window.dobbyUpdateProgress({phase, pct, version, vc}). The Mac has no synchronous bridge for
/// the stamp's read-at-start, so `push` re-sends the last state when a page attaches.
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// The X-Dobby-Key value the update host's auth map expects (UpdateChecker.TOKEN_KID).
    private static let tokenKid = "k1"

    private var controller: SPUStandardUpdaterController?
    private var state: [String: Any] = ["phase": "idle", "pct": 0, "version": "", "vc": 0]

    /// Set by the live WebBridge; receives the JSON for window.dobbyUpdateProgress.
    var push: ((String) -> Void)? { didSet { repush() } }

    var isOn: Bool { controller != nil }

    func start() {
        guard controller == nil else { return }
        guard let config = AppConfig.macUpdateConfig(Bundle.main.infoDictionary ?? [:]) else {
            NSLog("%@", "Dobby: updates off (no feed, token or EdDSA key in this build)")
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let vc = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        c.updater.httpHeaders = ["X-Dobby-Key": Self.tokenKid,
                                 "Authorization": "Bearer " + config.token,
                                 "X-Dobby-Version": vc]
        c.startUpdater()
        controller = c
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    func repush() {
        guard let push, let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        push(json)
    }

    private func set(_ phase: String, _ item: SUAppcastItem?) {
        let pct = phase == "ready" ? 100 : 0
        state = ["phase": phase, "pct": pct,
                 "version": item?.displayVersionString ?? "", "vc": Int(item?.versionString ?? "") ?? 0]
        repush()
    }

    // MARK: SPUUpdaterDelegate (Sparkle calls these on the main thread)

    /// Found: the stamp's found pulse. Sparkle's delegate reports no bytes for a silent
    /// download, so the percent stays 0 until ready.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { set("downloading", item) }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { set("ready", item) }

    /// No update, an error, or the user dismissed Sparkle's own alert: idle, unless one is
    /// downloaded and waiting for the quit.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if state["phase"] as? String != "ready" { set("idle", nil) }
    }

    /// The silently downloaded update is ready: Android's ready dialog. Returning true keeps
    /// Sparkle from scheduling further checks; it still installs on quit whatever is pressed.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        set("ready", item)
        let alert = NSAlert()
        alert.messageText = "Dobby \(item.displayVersionString) is ready"
        alert.informativeText = "Install now and Dobby restarts. Later installs it the next time you quit Dobby."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        let answer = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { immediateInstallHandler() }
        }
        // A sheet, so a playing film is not frozen behind an app-modal alert.
        if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
        return true
    }
}
#endif
