import SwiftUI

// E10 (#475) owns this file: the pause media-info cards (Android buildMediaInfoPanel
// :2047-2140), from the payload's title, subtitle, description and thumb (else poster).
// #466 stub: draws nothing.

extension PlayerView {
    /// Always in the tree, just under the control bar layer. E10: draw only while paused, the
    /// bar is up and no layer is open (`!isPlaying && controls.visible && !controls.anyLayerOpen`).
    var pauseInfoCards: some View { EmptyView() }
}
