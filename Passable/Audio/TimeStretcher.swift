import AVFoundation

/// Offline tempo and pitch matching through Apple's AUNewTimePitch, run in a
/// manual-rendering engine so it goes as fast as the CPU allows.
///
/// Matching is baked into new stem files rather than applied live: the render
/// and the preview then read identical samples, and the beat grid of the
/// stretched track is exact arithmetic instead of whatever a real-time unit
/// happens to be doing.
enum TimeStretcher {
    /// - Parameters:
    ///   - rate: playback speed, >1 is faster (target BPM ÷ source BPM).
    ///   - semitones: pitch shift independent of the rate.
    static func process(_ input: StereoBuffer, rate: Double, semitones: Int) throws -> StereoBuffer {
        if abs(rate - 1) < 1e-6 && semitones == 0 { return input }
        let latency = try measureLatency(rate: rate, semitones: semitones)
        let expected = Int((Double(input.count) / rate).rounded())
        let raw = try render(input, rate: rate, semitones: semitones, frames: expected + latency + 4096)
        let end = min(raw.count, latency + expected)
        return StereoBuffer(left: Array(raw.left[latency..<end]), right: Array(raw.right[latency..<end]))
    }

    /// The unit's group delay at these settings, found by stretching a click
    /// and seeing where it lands. Without this, a matched track would sit a
    /// few milliseconds behind its own beat grid — audible as flamming kicks.
    private static func measureLatency(rate: Double, semitones: Int) throws -> Int {
        let sr = Int(AudioIO.sampleRate)
        var probe = StereoBuffer(count: sr * 2)
        // A short raised-cosine burst survives the phase vocoder better than a
        // single-sample impulse, which it smears into a plateau.
        for i in 0..<64 {
            let v = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / 64))
            probe.left[sr + i] = v
            probe.right[sr + i] = v
        }
        let out = try render(probe, rate: rate, semitones: semitones, frames: Int(Double(probe.count) / rate) + 8192)
        var bestIndex = 0
        var best: Float = 0
        for i in 0..<out.count where abs(out.left[i]) > best {
            best = abs(out.left[i])
            bestIndex = i
        }
        let ideal = Int((Double(sr + 32) / rate).rounded())
        return max(0, bestIndex - ideal)
    }

    private static func render(_ input: StereoBuffer, rate: Double, semitones: Int, frames: Int) throws -> StereoBuffer {
        let format = AudioIO.stereoFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(rate)
        timePitch.pitch = Float(semitones * 100)
        timePitch.overlap = 16 // highest quality
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        try engine.start()
        defer { engine.stop() }

        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count)),
              let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)
        else { throw PassableError.message("Out of memory while matching tempo.") }
        source.frameLength = AVAudioFrameCount(input.count)
        source.floatChannelData![0].update(from: input.left, count: input.count)
        source.floatChannelData![1].update(from: input.right, count: input.count)
        player.scheduleBuffer(source)
        player.play()

        var result = StereoBuffer(count: 0)
        result.left.reserveCapacity(frames)
        result.right.reserveCapacity(frames)
        while result.count < frames {
            let want = AVAudioFrameCount(min(Int(block), frames - result.count))
            let status = try engine.renderOffline(want, to: out)
            guard status == .success else {
                if status == .error { throw PassableError.message("Tempo matching failed.") }
                continue
            }
            let n = Int(out.frameLength)
            let data = out.floatChannelData!
            result.left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            result.right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: n))
        }
        return result
    }
}
