import AVFoundation
import Accelerate

enum PassableError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Stereo, non-interleaved float audio at the project sample rate.
struct StereoBuffer {
    var left: [Float]
    var right: [Float]

    var count: Int { left.count }

    init(left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        self.left = left
        self.right = right
    }

    init(count: Int) {
        left = [Float](repeating: 0, count: count)
        right = [Float](repeating: 0, count: count)
    }

    /// (L + R) / 2.
    func mono() -> [Float] {
        var out = [Float](repeating: 0, count: count)
        vDSP_vadd(left, 1, right, 1, &out, 1, vDSP_Length(count))
        var half: Float = 0.5
        vDSP_vsmul(out, 1, &half, &out, 1, vDSP_Length(count))
        return out
    }
}

enum AudioIO {
    /// Everything inside Passable runs at 44.1 kHz: it is what HTDemucs was
    /// trained on, so stems, the timeline and the render all share one clock.
    static let sampleRate: Double = 44_100

    static var stereoFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    }

    /// Decodes any Core Audio-readable file to stereo 44.1 kHz floats,
    /// resampling and up-mixing mono as needed.
    static func loadStereo(url: URL) throws -> StereoBuffer {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard file.length > 0, inFormat.channelCount > 0 else {
            throw PassableError.message("\(url.lastPathComponent) contains no audio.")
        }
        if inFormat.channelCount <= 2, let decoded = try resampledInParallel(file, url: url) { return decoded }
        file.framePosition = 0
        let outFormat = stereoFormat
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw PassableError.message("Can't convert \(url.lastPathComponent) to 44.1 kHz stereo.")
        }
        // YouTube's Opus is 48 kHz: resample with Apple's best filter.
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        if inFormat.channelCount == 1 {
            converter.channelMap = [0, 0]
        } else if inFormat.channelCount > 2 {
            converter.downmix = true
        }

        let chunk: AVAudioFrameCount = 1 << 16
        let ratio = sampleRate / inFormat.sampleRate
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 4096)
        else { throw PassableError.message("Out of memory decoding \(url.lastPathComponent).") }

        let expected = Int(Double(file.length) * ratio) + 4096
        var left = [Float](); left.reserveCapacity(expected)
        var right = [Float](); right.reserveCapacity(expected)
        var readError: Error?

        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                guard readError == nil, file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: chunk)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = inBuffer.frameLength > 0 ? .haveData : .endOfStream
                return inBuffer.frameLength > 0 ? inBuffer : nil
            }
            let n = Int(outBuffer.frameLength)
            if n > 0, let data = outBuffer.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
                right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: n))
            }
            if let conversionError { throw conversionError }
            if let readError { throw readError }
            if status == .endOfStream || status == .error { break }
        }
        guard !left.isEmpty else { throw PassableError.message("\(url.lastPathComponent) decoded to silence.") }
        return StereoBuffer(left: left, right: right)
    }

    /// The same samples as the converter above, five times sooner: the
    /// mastering resampler is most of a decode, so it runs per channel and
    /// per stretch of the song on every core. A stretch starts on a whole
    /// period of the rate ratio (160 in, 147 out for 48 kHz) and is read
    /// with a margin far longer than the filter, which is cut off again, so
    /// the stretches join without a seam (checked bit for bit against the
    /// one-pass converter). Nil where that can't be done (a rate that isn't
    /// a whole number, a ratio with no short period).
    private static func resampledInParallel(_ file: AVAudioFile, url: URL) throws -> StereoBuffer? {
        let inFormat = file.processingFormat
        guard inFormat.sampleRate == inFormat.sampleRate.rounded(), !inFormat.isInterleaved,
              inFormat.commonFormat == .pcmFormatFloat32 else { return nil }
        let inRate = Int(inFormat.sampleRate), outRate = Int(sampleRate)
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let common = gcd(inRate, outRate)
        let inPeriod = inRate / common, outPeriod = outRate / common
        guard inPeriod <= 4096 else { return nil }
        guard let source = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PassableError.message("Out of memory decoding \(url.lastPathComponent).")
        }
        try file.read(into: source)
        let n = Int(source.frameLength)
        guard n > 0, let data = source.floatChannelData else {
            throw PassableError.message("\(url.lastPathComponent) decoded to silence.")
        }

        guard let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false),
              let monoOut = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { return nil }
        let stretch = inPeriod * max(1, 320_000 / inPeriod)
        let margin = inPeriod * max(1, 16_000 / inPeriod)
        let stretches = (n + stretch - 1) / stretch
        let channels = Int(inFormat.channelCount)
        // Exactly what one pass over the whole song gives out.
        var total = 0
        var parts = [[Float]?](repeating: nil, count: channels * stretches)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: channels * stretches) { job in
            let channel = job / stretches, k = job % stretches
            let from = max(0, k * stretch - margin), to = min(n, (k + 1) * stretch + margin)
            guard let input = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: AVAudioFrameCount(to - from)),
                  let output = AVAudioPCMBuffer(pcmFormat: monoOut, frameCapacity: AVAudioFrameCount((to - from) / inPeriod * outPeriod + 8192)),
                  let converter = AVAudioConverter(from: monoIn, to: monoOut) else { return }
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            input.frameLength = AVAudioFrameCount(to - from)
            input.floatChannelData![0].update(from: data[channel] + from, count: to - from)
            var given = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if given { inputStatus.pointee = .endOfStream; return nil }
                given = true
                inputStatus.pointee = .haveData
                return input
            }
            guard error == nil, status != .error else { return }
            let produced = Int(output.frameLength)
            let skip = (k * stretch - from) / inPeriod * outPeriod
            let wanted = k == stretches - 1 ? produced - skip : stretch / inPeriod * outPeriod
            guard skip <= produced else { return }
            let part = Array(UnsafeBufferPointer(start: output.floatChannelData![0] + skip, count: min(wanted, produced - skip)))
            lock.lock()
            parts[job] = part
            if channel == 0 { total += part.count }
            lock.unlock()
        }
        guard parts.allSatisfy({ $0 != nil }), total > 0 else { return nil }
        func joined(_ channel: Int) -> [Float] {
            var out = [Float](); out.reserveCapacity(total)
            for k in 0..<stretches { out.append(contentsOf: parts[channel * stretches + k]!) }
            return out
        }
        let left = joined(0)
        return StereoBuffer(left: left, right: channels == 2 ? joined(1) : left)
    }
}

/// Writes a render as `.m4a` (AAC, 256 kbps) or, for any other extension,
/// a 24-bit WAV. The songs come in as YouTube AAC, so a WAV of the mix is
/// ten times the size and no better to the ear; it stays available for
/// editing in other software.
final class AudioWriter {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    init(url: URL, blockSize: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any]
        if url.pathExtension.lowercased() == "m4a" {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioIO.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ]
        } else {
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioIO.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        buffer = AVAudioPCMBuffer(pcmFormat: AudioIO.stereoFormat, frameCapacity: AVAudioFrameCount(blockSize))!
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) throws {
        precondition(count <= Int(buffer.frameCapacity))
        let data = buffer.floatChannelData!
        data[0].update(from: left, count: count)
        data[1].update(from: right, count: count)
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
    }
}
