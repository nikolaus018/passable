import SwiftUI

/// The whole set as one waveform. Each song has its deck colour, and across a
/// blend the colour slides from the outgoing song to the incoming one, so the
/// transitions are visible at a glance. Played bars are bright, the rest dim.
struct WaveformView: View {
    let manifest: PassableMix.Manifest
    let peaks: [Float]?
    let duration: Double
    /// Seconds into the file, or nil for no playhead.
    var playhead: Double?
    var barWidth: CGFloat = 3
    var gap: CGFloat = 2
    var showsMarkers = true

    var body: some View {
        Canvas { context, size in
            guard duration > 0, size.width > 0 else { return }
            let step = barWidth + gap
            let count = max(1, Int(size.width / step))
            let perBar = duration / Double(count)

            for i in 0..<count {
                let t0 = Double(i) * perBar
                let mid = t0 + perBar / 2
                let amplitude = Self.amplitude(peaks, from: t0, to: t0 + perBar)
                let h = max(barWidth, amplitude * size.height)
                let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: barWidth, height: h)
                let played = playhead.map { mid <= $0 } ?? true
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(Self.color(at: mid, manifest).opacity(played ? 1 : 0.34)))
            }

            if showsMarkers {
                for song in manifest.songs.dropFirst() {
                    let x = CGFloat(song.handover / duration) * size.width
                    let dot = CGRect(x: x - 1.5, y: 0, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.55)))
                }
            }

            if let playhead {
                let x = min(size.width - 1, max(1, CGFloat(playhead / duration) * size.width))
                let line = CGRect(x: x - 1, y: 0, width: 2, height: size.height)
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: .white.opacity(0.6), radius: 4))
                    layer.fill(Path(roundedRect: line, cornerRadius: 1), with: .color(.white))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Loudness 0...1 over a stretch, eased so quiet parts still show.
    static func amplitude(_ peaks: [Float]?, from t0: Double, to t1: Double) -> CGFloat {
        guard let peaks, !peaks.isEmpty else { return 0.10 }
        let a = Int(t0 * Waveform.bucketsPerSecond)
        guard a < peaks.count else { return 0.04 }
        let b = min(peaks.count, max(a + 1, Int(t1 * Waveform.bucketsPerSecond)))
        var m: Float = 0
        for k in a..<b { m = max(m, peaks[k]) }
        return CGFloat(max(0.05, pow(Double(m), 0.6)))
    }

    static func color(at time: Double, _ manifest: PassableMix.Manifest) -> Color {
        if let t = manifest.transitions.first(where: { $0.begins <= time && time < $0.end }), t.end > t.begins {
            let p = (time - t.begins) / (t.end - t.begins)
            let eased = p * p * (3 - 2 * p)
            return Theme.deckRGB(t.from).mixed(with: Theme.deckRGB(t.to), eased).color
        }
        return Theme.deck(manifest.songIndex(at: time))
    }
}

/// Three little bars that dance while a song plays.
struct PlayingBars: View {
    var isPlaying: Bool
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = Double(i) * 1.7
                    let h = isPlaying ? 0.35 + 0.65 * abs(sin(t * (3.2 + Double(i) * 0.9) + phase)) : 0.3
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 14 * h)
                }
            }
            .frame(width: 14, height: 14, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
