import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Tracks whether audio is currently routed to a car head unit.
///
/// Reading the audio route needs no CarPlay entitlement — `.carAudio` is the port
/// type both CarPlay and a wired/wireless car stereo report. Bluetooth A2DP is
/// deliberately NOT treated as a car: headphones report the same port type and
/// there is no reliable way to tell the two apart.
@MainActor
final class CarRoute: ObservableObject {
    @Published private(set) var isCar = false

    /// Fired on every transition so the web layer can switch into car mode.
    var onChange: ((Bool) -> Void)?

    init() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
        #endif
    }

    func refresh() {
        #if os(iOS)
        let car = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .carAudio }
        guard car != isCar else { return }
        isCar = car
        NSLog("%@", "Dobby car route \(car ? "connected" : "disconnected")")
        onChange?(car)
        #endif
    }
}
