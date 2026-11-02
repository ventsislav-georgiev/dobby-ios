import Foundation

// E9 (#474): the More menu's state and the Pause on OK rules, pure (Foundation only) so
// Tests/MoreMenuModelCheck.swift runs it on fake defaults. The views and the player calls are
// in MoreMenu.swift.

/// The More menu's rows, top to bottom. Speed and Info are Mac rows (owner ruling 2026-11-02);
/// Pause on OK is Android's one row on every lane (refreshMoreMenuItems :9254-9287).
enum MoreMenuRow: CaseIterable { case speed, info, pauseOnOk }

struct MoreMenuState {
    /// Saved on this machine, as Android keeps it in its own prefs (stretch_memory/pause_on_ok).
    static let pauseOnOkKey = "dobby.pauseOnOk"

    let defaults: UserDefaults
    /// The focused row (keys and hover move the same index).
    var focus = 0
    /// The bar was up when the menu opened; it comes back on close (Android closeMoreMenu).
    var restoreBar = false
    /// The owner's saved Pause on OK. Read once; written only by `togglePauseOnOk`, so an
    /// absent key reads Off and nothing is ever written over a saved value.
    private(set) var pauseOnOk: Bool
    /// The current pause is Pause on OK's own, so the return to the bare picture resumes it.
    private(set) var pausedByOk = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pauseOnOk = defaults.bool(forKey: Self.pauseOnOkKey)
    }

    mutating func togglePauseOnOk() {
        pauseOnOk.toggle()
        defaults.set(pauseOnOk, forKey: Self.pauseOnOkKey)
    }

    /// OK on the bare picture (Android handleSelectPress :7160-7166): true = pause now. Only a
    /// video that has started and is playing is paused.
    mutating func okShouldPause(playing: Bool, started: Bool) -> Bool {
        guard pauseOnOk, playing, started else { return false }
        pausedByOk = true
        return true
    }

    /// Back on the bare picture (Android resumeIfPausedByOk :2641-2649): true = resume now. The
    /// flag clears first, so the call is idempotent; a player the user already resumed
    /// (`paused` false) only clears it.
    mutating func bareShouldResume(paused: Bool) -> Bool {
        guard pausedByOk else { return false }
        pausedByOk = false
        return paused
    }

    /// The user chose the play state (Android togglePlay :7200): the pause is no longer OK's.
    mutating func cancelPausedByOk() { pausedByOk = false }

    mutating func move(_ delta: Int) {
        let n = MoreMenuRow.allCases.count
        focus = ((focus + delta) % n + n) % n
    }
}
