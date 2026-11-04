import KSPlayer

// E4 (#469) owns this file with QualitySheet.swift and AudioTrackLabel.swift: the audio sheet,
// Android populateTrackSheet "audio" + selectAudioTrack. Rows "✓ 🇬🇧 EN · DD+ 5.1"; a pick
// switches the track, toasts "Audio: <row>" and closes the sheet.

extension PlayerControls {
    func audioSheetContent() -> OSDSheetContent {
        let tracks = playback?.player.playerLayer?.player.tracks(mediaType: .audio) ?? []
        if tracks.isEmpty {
            return OSDSheetContent(title: "Audio", rows: [OSDItem(id: "none", label: "No audio tracks available", selected: false, enabled: false, action: {})])
        }
        let p = playback
        return OSDSheetContent(title: "Audio", rows: tracks.enumerated().map { idx, t in
            let label = Self.audioLabel(t, index: idx)
            return OSDItem(id: "a\(idx)", label: label, selected: t.isEnabled, action: { [weak self] in
                p?.player.playerLayer?.player.select(track: t)
                self?.flash("Audio: \(label)")
                self?.closeSheet()
            })
        })
    }

    /// Also the label a remote sender sees for this row (#541, PlaybackCoordinator.remoteTracks).
    static func audioLabel(_ t: MediaPlayerTrack, index: Int) -> String {
        let ffmpegName = (t as? FFmpegAssetTrack)?.codecName
        let c = t.codecType
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xff) }, encoding: .ascii) ?? ""
        return AudioTrackLabel.label(
            name: t.name, language: t.languageCode,
            codec: ffmpegName.flatMap { $0.isEmpty ? nil : $0 } ?? fourCC,
            codecName: ffmpegName,
            channels: Int(t.audioStreamBasicDescription?.mChannelsPerFrame ?? 0), index: index)
    }

    /// The generic sheet keys apply (up/down, Return picks, left closes, right picks).
    func audioSheetHandleKey(_ key: OSDKey) -> Bool { false }
}
