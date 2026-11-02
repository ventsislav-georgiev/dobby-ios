import Foundation
import AVFoundation
import CoreGraphics
import VideoToolbox
import KSPlayer

// #477 (E12): the letterbox pixel sampler for auto stretch, a port of Android's
// startLetterboxSamplerIfNeeded / sampleForLetterbox. Bars baked into a 16:9 frame are invisible
// to the metadata pass; this looks at the pixels a handful of times at start, then stops.
// The rules (detector, min across samples, apply then only correct down, when it ends) are pure
// in AspectModel.swift (Letterbox, foldLetterbox); this file only fetches frames.

extension PlayerControls {
    /// Once per playback, after the restore and the metadata pass (AspectSheet.swift). First sample
    /// 1 s in, then every 2 s; paused or portrait rounds wait without counting. Ends after 5
    /// usable frames or 20 rounds, on a new request (token gone) or when the player closes.
    func startLetterboxSampler() {
        let token = Int.random(in: 1...Int.max)
        guard aspect.startLetterbox(token: token) else { return }
        Task { @MainActor [weak self] in
            var delay: UInt64 = 1_000_000_000
            while true {
                try? await Task.sleep(nanoseconds: delay)
                delay = 2_000_000_000
                guard let self, self.aspect.lbToken == token, !self.aspect.lbDone else { return }
                let screen = self.aspectViewAspect
                guard self.isPlaying, screen >= 1, let player = self.playback?.player.playerLayer?.player else { continue }
                let image = await Self.currentFrame(player)
                let bars = await Task.detached { image.flatMap(Self.detectBars) }.value
                // The player may have moved on while the frame was fetched.
                guard self.aspect.lbToken == token else { return }
                self.letterboxResult(bars, screenAspect: screen)
            }
        }
    }

    private func letterboxResult(_ bars: (top: Int, bottom: Int)?, screenAspect: Double) {
        let outcome = aspect.foldLetterbox(bars, screenAspect: screenAspect)
        let a = aspect
        let seen = bars.map { "\($0.top)/\($0.bottom)" } ?? "none"
        playback?.markSelftest("letterbox round=\(a.lbRounds) bars=\(seen) need=\(String(format: "%.3f", a.autoNeed)) "
            + "stretchV=\(a.stretchV) outcome=\(outcome) done=\(a.lbDone)")
        switch outcome {
        case .applied(let p, let fills):
            rememberAspect(knob: "stretchV", source: "auto")
            flash("Auto stretch: \(p)% (fills \(String(format: "%.2f", fills)):1)")
        case .corrected(let p):
            rememberAspect(knob: "stretchV", source: "auto")
            flash(p == 100 ? "Auto stretch off" : "Auto stretch: \(p)%")
        case .noFill:
            rememberAspect(knob: "stretchV", source: "auto")    // a rewatch skips sampling
        case .none:
            break
        }
    }

    /// The frame on screen now. AVPlayer lane: a video output attached for this one grab and
    /// removed again, so no frame is copied outside a sample. FFmpeg lane: KSMEPlayer's last
    /// rendered pixel buffer. nil when the lane gives nothing (counted as an unusable round).
    private static func currentFrame(_ player: MediaPlayerProtocol) async -> CGImage? {
        guard let av = player as? KSAVPlayer else { return await player.thumbnailImageAtCurrentTime() }
        guard let item = av.player.currentItem else { return nil }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        defer { item.remove(output) }
        for _ in 0..<20 {                                   // a decoded frame usually lands within 100 ms
            try? await Task.sleep(nanoseconds: 50_000_000)
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t),
               let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                var image: CGImage?
                VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
                return image
            }
        }
        return nil
    }

    /// Android sampleForLetterbox's PixelCopy into a 128 x 216 bitmap, luma = max(R, G, B).
    nonisolated private static func detectBars(_ image: CGImage) -> (top: Int, bottom: Int)? {
        let w = Letterbox.sampleW, h = Letterbox.sampleH
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let luma = (0..<(w * h)).map { i in max(rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2]) }
        return Letterbox.detectBars(luma, width: w, height: h)
    }
}
