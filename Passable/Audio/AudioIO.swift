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
