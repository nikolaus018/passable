import AVFoundation

/// Live preview: an AVAudioSourceNode pulling straight from the MixRenderer.
final class PlaybackEngine {
    let renderer = MixRenderer()
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private(set) var isRunning = false

    init() {
        let renderer = self.renderer
        sourceNode = AVAudioSourceNode(format: AudioIO.stereoFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            renderer.render(left: left, right: right, count: Int(frameCount))
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: AudioIO.stereoFormat)
        engine.prepare()
    }

    func play() throws {
        guard !isRunning else { return }
        try engine.start()
        isRunning = true
    }

    func pause() {
        guard isRunning else { return }
        engine.pause()
        isRunning = false
    }
}

enum Exporter {
    /// Renders `range` (master frames) of the mix to an audio file (see
    /// `AudioWriter` for the formats), plus
    /// `tail` extra seconds so reverb and echo ring out instead of being cut.
    static func render(snapshot: MixSnapshot, range: Range<Int>, tail: Double, to url: URL,
                       progress: (Double) -> Void) throws {
        let renderer = MixRenderer(snapshot: snapshot)
        renderer.setPositionImmediately(range.lowerBound)
        let block = 4096
        let writer = try AudioWriter(url: url, blockSize: block)
        var left = [Float](repeating: 0, count: block)
        var right = [Float](repeating: 0, count: block)
        let total = range.count + Int(tail * AudioIO.sampleRate)
        var done = 0
        while done < total {
            if Task.isCancelled { throw CancellationError() }
            let n = min(block, total - done)
            try left.withUnsafeMutableBufferPointer { l in
                try right.withUnsafeMutableBufferPointer { r in
                    renderer.render(left: l.baseAddress!, right: r.baseAddress!, count: n)
                    try writer.write(left: l.baseAddress!, right: r.baseAddress!, count: n)
                }
            }
            done += n
            if done % (block * 64) == 0 || done == total { progress(Double(done) / Double(total)) }
        }
    }
}
