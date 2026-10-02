import Accelerate
import CoreML

/// Where a trained model hears the beats and the downbeats of a song:
/// Beat This! (Foscarin, Schlüter and Widmer, ISMIR 2024), exported to Core
/// ML by tools/convert-beats/convert.py.
///
/// What onset energy alone can't tell: which of several pulses that all fit
/// the hits is the beat (a dancehall kick pattern repeats every three
/// sixteenths, and a comb search then reads 117 BPM as 93.6), whether the
/// beat sits on the kicks or on the claps between them, and which beat is
/// the one. The model has learnt that from annotated music; it answers in
/// 20 ms frames, so `TempoEstimator` takes the metre from here and still
/// places the grid on the drum hits itself, to the millisecond.
final class BeatTracker: @unchecked Sendable {
    struct Beats: Equatable {
        /// Seconds from the start of the audio.
        var beats: [Double]
        var downbeats: [Double]
    }

    /// nil where the model isn't in the app bundle (not exported yet):
    /// analysis then goes by onset energy alone.
    static let shared: BeatTracker? = try? BeatTracker()

    /// The rate the model listens at, and its frames per second.
    static let sampleRate = 22_050.0
    static let framesPerSecond = 50.0
    private static let fftSize = 1024, hop = 441, bins = 513
    /// Frames the model takes at once (30 s), and those at either end of
    /// its answer that it wasn't trained to get right.
    private static let chunk = 1500, border = 6

    private let model: MLModel
    private let lock = NSLock()

    init() throws {
        guard let url = Bundle.main.url(forResource: "BeatThis", withExtension: "mlmodelc") else {
            throw PassableError.message("BeatThis model is missing from the app bundle. Run tools/convert-beats/convert.py and rebuild.")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: config)
    }

    /// Beats and downbeats of mono audio at `AudioIO.sampleRate`.
    func track(_ mono: [Float]) throws -> Beats {
        // Half the rate: 44.1 kHz is exactly twice the model's.
        let step = AudioIO.sampleRate / Self.sampleRate
        let signal = Resampler.resample(mono, step: step, count: Int(Double(mono.count) / step))
        let logits = try self.logits(spectrogram: Self.spectrogram(signal))
        return Self.beats(beat: logits.beat, downbeat: logits.downbeat)
    }

    /// Magnitude spectrogram as the model was trained on it (before its
    /// mel filterbank, which is part of the exported graph): 1024-sample
    /// periodic Hann window, hop 441, frames centred on `k · hop` with the
    /// ends reflected, magnitudes over the square root of the window
    /// length. Frames first, `bins` values each.
    static func spectrogram(_ signal: [Float]) -> [Float] {
        let n = fftSize, half = n / 2
        guard signal.count > half else { return [] }
        let frames = 1 + signal.count / hop
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        let log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: half), imag = real
        var frame = [Float](repeating: 0, count: n)
        var out = [Float](repeating: 0, count: frames * bins)
        // vDSP's real FFT returns twice the transform.
        let scale = 0.5 / Float(Double(n).squareRoot())
        for f in 0..<frames {
            let start = f * hop - half
            for k in 0..<n {
                var i = start + k
                // Reflected about the first and the last sample.
                if i < 0 { i = -i }
                if i >= signal.count { i = 2 * (signal.count - 1) - i }
                frame[k] = i >= 0 && i < signal.count ? signal[i] * window[k] : 0
            }
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // Packed: the first real is DC, the first imaginary the
                    // Nyquist bin.
                    let dc = abs(re[0]), nyquist = abs(im[0])
                    im[0] = 0
                    out.withUnsafeMutableBufferPointer { o in
                        vDSP_zvabs(&split, 1, o.baseAddress! + f * bins, 1, vDSP_Length(half))
                        o[f * bins] = dc
                        o[f * bins + half] = nyquist
                    }
                }
            }
        }
        var s = scale
        vDSP_vsmul(out, 1, &s, &out, 1, vDSP_Length(out.count))
        return out
    }

    /// The model's answer for every frame of a spectrogram, run 30 s at a
    /// time as its authors do: chunks overlap by the frames at their ends
    /// the model isn't sure of, the last one moved back to end with the
    /// song, and where two cover a frame the earlier one counts.
    func logits(spectrogram: [Float]) throws -> (beat: [Float], downbeat: [Float]) {
        let bins = Self.bins, chunk = Self.chunk, border = Self.border
        let frames = spectrogram.count / bins
        var beat = [Float](repeating: -1000, count: frames), downbeat = beat
        guard frames > 0 else { return (beat, downbeat) }
        var starts = Array(stride(from: -border, to: frames - border, by: chunk - 2 * border))
        if frames > chunk - 2 * border { starts[starts.count - 1] = frames - (chunk - border) }
        let input = try MLMultiArray(shape: [1, NSNumber(value: chunk), NSNumber(value: bins)], dataType: .float32)
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        lock.lock()
        defer { lock.unlock() }
        for start in starts.reversed() {
            vDSP_vclr(pointer, 1, vDSP_Length(chunk * bins))
            let from = max(start, 0), to = min(start + chunk, frames)
            spectrogram.withUnsafeBufferPointer { s in
                (pointer + (from - start) * bins).update(from: s.baseAddress! + from * bins, count: (to - from) * bins)
            }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spect": input]))
            guard let b = output.featureValue(for: "beat")?.multiArrayValue,
                  let d = output.featureValue(for: "downbeat")?.multiArrayValue else {
                throw PassableError.message("BeatThis returned no beats.")
            }
            for k in border..<(chunk - border) where start + k >= 0 && start + k < frames {
                beat[start + k] = b[k].floatValue
                downbeat[start + k] = d[k].floatValue
            }
        }
        return (beat, downbeat)
    }

    /// Beat and downbeat times from the model's frames, as its authors pick
    /// them: a frame the model is more sure of than not, and of all within
    /// 70 ms; neighbouring frames count as one; a downbeat is the beat
    /// nearest to it.
    static func beats(beat: [Float], downbeat: [Float]) -> Beats {
        func peaks(_ x: [Float]) -> [Double] {
            var frames: [Double] = []
            var run: (sum: Double, count: Int, last: Int)?
            for i in x.indices where x[i] > 0 {
                let lo = max(0, i - 3), hi = min(x.count - 1, i + 3)
                guard x[i] >= x[lo...hi].max()! else { continue }
                if let r = run, i - r.last <= 1 {
                    run = (r.sum + Double(i), r.count + 1, i)
                } else {
                    if let r = run { frames.append(r.sum / Double(r.count)) }
                    run = (Double(i), 1, i)
                }
            }
            if let r = run { frames.append(r.sum / Double(r.count)) }
            return frames.map { $0 / framesPerSecond }
        }
        let beats = peaks(beat)
        guard !beats.isEmpty else { return Beats(beats: [], downbeats: []) }
        var downbeats: [Double] = []
        for t in peaks(downbeat) {
            let nearest = beats.min { abs($0 - t) < abs($1 - t) }!
            if downbeats.last != nearest { downbeats.append(nearest) }
        }
        return Beats(beats: beats, downbeats: downbeats)
    }
}
