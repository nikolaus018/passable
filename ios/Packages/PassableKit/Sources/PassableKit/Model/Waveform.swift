import Accelerate
import AVFoundation

/// The loudness outline of a mix, for drawing: one peak per bucket.
enum Waveform {
    static let bucketsPerSecond = 4.0

    /// One peak (0...1, loudest sample of either channel) per quarter second.
    static func peaks(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let perBucket = max(1, Int(format.sampleRate / bucketsPerSecond))
        let capacity: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }

        var peaks: [Float] = []
        peaks.reserveCapacity(Int(Double(file.length) / Double(perBucket)) + 1)
        var current: Float = 0
        var filled = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: capacity)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            var offset = 0
            while offset < n {
                let take = min(perBucket - filled, n - offset)
                for c in 0..<Int(format.channelCount) {
                    var m: Float = 0
                    vDSP_maxmgv(channels[c] + offset, 1, &m, vDSP_Length(take))
                    current = max(current, m)
                }
                filled += take
                offset += take
                if filled == perBucket {
                    peaks.append(min(1, current))
                    current = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { peaks.append(min(1, current)) }
        return peaks
    }

    static func encode(_ peaks: [Float]) -> Data {
        peaks.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
