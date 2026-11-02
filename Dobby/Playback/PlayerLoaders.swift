import SwiftUI

// E11 (#476) owns this file: the preparing screen and the buffering loader (Android
// buildPreparingOverlay :1137-1212, the comet :1544-1555). The Mac keeps its instant close.
// #466 moved the pre-#466 spinner here unchanged.

extension PlayerView {
    /// Always in the tree, above the subtitles; decides itself when to draw.
    var playerLoaders: some View {
        ZStack {
            if controls.buffering || !controls.loaded {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .scaleEffect(1.4)
                    .tint(.white)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}
