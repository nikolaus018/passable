import Accelerate
import CoreML

/// The vocal stem from Mel-Band RoFormer (Kim's vocal model) under Core ML.
///
/// HTDemucs' vocal stem is 2.9 dB further from the true vocal than this
/// model's (median SDR over the MUSDB18 test excerpts: 8.9 against 11.7 dB,
/// this better on 49 of 50 songs; tools/convert-roformer/evaluate.py): the
/// band bleeding into the voice and the voice into the band is what a vocal
/// handover is heard through. The other three stems stay HTDemucs' (see
/// `TrackProcessor`): this model separates the voice only.
///
/// Mirrors the model's own forward and upstream's `demix_track`: 8 s chunks,
/// half overlapping, faded in and out over a tenth of a chunk, the track
/// reflected a half chunk past both ends. The network gives the complex mask
/// of every (bin, channel) each mel band covers; a bin in several bands gets
/// their mean, the mix's STFT is multiplied by it and transformed back.
final class VocalSeparator {
    private let model: MLModel
    /// (bin·2 + channel) of each mask the network gives, in its order.
    private let freqIndices: [Int]
    /// How many bands cover each (bin·2 + channel).
    private let bandsPerFreq: [Float]
    private let stft = RoformerSTFT()
    /// The masks in single precision, where the network gives half.
    private var halves: [Float] = []

    static let chunk = RoformerSTFT.chunk
    static let fade = chunk / 10
    /// Samples from one chunk's start to the next's. Variable only for
    /// passable-render's trials.
    nonisolated(unsafe) static var step = chunk / 2

    init(model modelURL: URL? = nil) throws {
        guard let url = modelURL ?? Bundle.main.url(forResource: "VocalRoformer", withExtension: "mlmodelc")
                ?? ModelLocation.fallback(named: "VocalRoformer") else {
            throw PassableError.message("The vocal model is missing from the app bundle. Run tools/convert-roformer/convert.py and rebuild.")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: config)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        freqIndices = (metadata["freq_indices"] ?? "").split(separator: ",").compactMap { Int($0) }
        guard !freqIndices.isEmpty, freqIndices.allSatisfy({ $0 >= 0 && $0 < 2 * RoformerSTFT.bins }) else {
            throw PassableError.message("The vocal model has no band layout.")
        }
        var count = [Float](repeating: 0, count: 2 * RoformerSTFT.bins)
        for i in freqIndices { count[i] += 1 }
        bandsPerFreq = count.map { max($0, 1) }
    }

    /// Whether the app has the model (an older build, or a tool run
    /// without it, keeps HTDemucs' vocal).
    static var isAvailable: Bool {
        Bundle.main.url(forResource: "VocalRoformer", withExtension: "mlmodelc") != nil
            || ModelLocation.fallback(named: "VocalRoformer") != nil
    }

    func vocals(_ mix: StereoBuffer, progress: (Double) -> Void,
                isCancelled: () -> Bool = { false }) throws -> StereoBuffer {
        let size = Self.chunk, step = Self.step, fade = Self.fade
        let length = mix.count
        // Reflected half a chunk past both ends, where the song is long
        // enough to reflect (as upstream: the first and last seconds get a
        // full chunk's context).
        let border = size - step
        let padded = length > 2 * border
        let source = padded ? [mix.left, mix.right].map { Self.reflect($0, by: border) } : [mix.left, mix.right]
        let total = source[0].count

        var window = [Float](repeating: 1, count: size)
        for i in 0..<fade {
            window[i] = Float(i) / Float(fade - 1)
            window[size - 1 - i] = Float(i) / Float(fade - 1)
        }
        var out = [[Float]](repeating: [Float](repeating: 0, count: total), count: 2)
        var weight = [Float](repeating: 0, count: total)

        let frames = RoformerSTFT.frames, rows = 2 * RoformerSTFT.bins
        let specArray = try MLMultiArray(shape: [1, NSNumber(value: rows), NSNumber(value: frames), 2], dataType: .float32)
        let spec = specArray.dataPointer.assumingMemoryBound(to: Float.self)
        var part = [[Float]](repeating: [Float](repeating: 0, count: size), count: 2)
        var mask = [Float](repeating: 0, count: rows * frames * 2)
        var result = [Float](repeating: 0, count: size)

        let starts = Array(stride(from: 0, to: total, by: step))
        for (n, start) in starts.enumerated() {
            if isCancelled() { throw CancellationError() }
            let count = min(size, total - start)
            for c in 0..<2 {
                Self.fill(&part[c], from: source[c], start: start, count: count)
                stft.forward(part[c], channel: c, into: spec)
            }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "spec": MLFeatureValue(multiArray: specArray),
            ]))
            guard let masks = output.featureValue(for: "masks")?.multiArrayValue,
                  masks.dataType == .float32 || masks.dataType == .float16 else {
                throw PassableError.message("The vocal model returned no masks.")
            }
            averageMasks(masks, into: &mask)
            var w = window
            if n == 0 { for i in 0..<fade { w[i] = 1 } }
            if start + size >= total { for i in 0..<fade { w[size - 1 - i] = 1 } }
            for c in 0..<2 {
                stft.inverse(spec: spec, mask: mask, channel: c, into: &result)
                out[c].withUnsafeMutableBufferPointer { o in
                    vDSP_vma(result, 1, w, 1, o.baseAddress! + start, 1, o.baseAddress! + start, 1, vDSP_Length(count))
                }
            }
            weight.withUnsafeMutableBufferPointer { o in
                vDSP_vadd(o.baseAddress! + start, 1, w, 1, o.baseAddress! + start, 1, vDSP_Length(count))
            }
            progress(Double(n + 1) / Double(starts.count))
        }
        var vocals = StereoBuffer(count: length)
        let from = padded ? border : 0
        for c in 0..<2 {
            var v = [Float](repeating: 0, count: length)
            out[c].withUnsafeBufferPointer { o in
                weight.withUnsafeBufferPointer { wt in
                    vDSP_vdiv(wt.baseAddress! + from, 1, o.baseAddress! + from, 1, &v, 1, vDSP_Length(length))
                }
            }
            if c == 0 { vocals.left = v } else { vocals.right = v }
        }
        return vocals
    }

    /// The network's masks summed per (bin·2 + channel) and divided by how
    /// many bands cover it: [row][frame][re, im].
    private func averageMasks(_ masks: MLMultiArray, into mask: inout [Float]) {
        let frames = RoformerSTFT.frames
        let st = masks.strides.map(\.intValue)
        for i in mask.indices { mask[i] = 0 }
        func add(_ m: UnsafeBufferPointer<Float>) {
            for (j, row) in freqIndices.enumerated() {
                let base = row * frames * 2
                for t in 0..<frames {
                    let at = t * st[1] + j * st[2]
                    mask[base + 2 * t] += m[at]
                    mask[base + 2 * t + 1] += m[at + st[3]]
                }
            }
        }
        // (The FP16 network gives its masks in half precision; converted
        // with vImage, which unlike Swift's Float16 has Intel Macs too.)
        if masks.dataType == .float16 {
            // (Up to its last element, strides and all.)
            let count = zip(masks.shape, masks.strides).reduce(1) { $0 + ($1.0.intValue - 1) * $1.1.intValue }
            if halves.count != count { halves = [Float](repeating: 0, count: count) }
            halves.withUnsafeMutableBufferPointer { f in
                var src = vImage_Buffer(data: masks.dataPointer, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var dst = vImage_Buffer(data: f.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
            halves.withUnsafeBufferPointer { add($0) }
        } else {
            masks.withUnsafeBufferPointer(ofType: Float.self) { add($0) }
        }
        for row in 0..<bandsPerFreq.count {
            var scale = 1 / bandsPerFreq[row]
            mask.withUnsafeMutableBufferPointer { m in
                vDSP_vsmul(m.baseAddress! + row * frames * 2, 1, &scale, m.baseAddress! + row * frames * 2, 1,
                           vDSP_Length(frames * 2))
            }
        }
    }

    /// `x` reflected `by` samples past both ends (torch's 'reflect': the
    /// end samples themselves aren't repeated).
    static func reflect(_ x: [Float], by pad: Int) -> [Float] {
        let n = x.count
        var y = [Float](repeating: 0, count: n + 2 * pad)
        for i in 0..<pad { y[i] = x[pad - i]; y[pad + n + i] = x[n - 2 - i] }
        y.replaceSubrange(pad..<(pad + n), with: x)
        return y
    }

    /// A chunk of `source` from `start`: a short last one reflected out to
    /// a full chunk if it's more than half of one, zeros otherwise.
    private static func fill(_ part: inout [Float], from source: [Float], start: Int, count: Int) {
        let size = part.count
        for i in 0..<count { part[i] = source[start + i] }
        guard count < size else { return }
        if count > size / 2 + 1 {
            for i in count..<size { part[i] = source[start + 2 * (count - 1) - i] }
        } else {
            for i in count..<size { part[i] = 0 }
        }
    }
}

/// `torch.stft` / `torch.istft` as the vocal model uses them: n_fft 2048,
/// hop 441, periodic Hann, centred with reflection, not normalised; one
/// chunk of 352,800 samples (801 frames, 1,025 bins).
final class RoformerSTFT {
    static let chunk = 352_800
    static let nfft = 2048
    static let hop = 441
    static let bins = nfft / 2 + 1
    static let frames = chunk / hop + 1

    private let setup: FFTSetup
    private let log2n = vDSP_Length(11)
    private let window: [Float]
    /// Σ window² over the frames that cover each sample of the padded chunk.
    private let envelope: [Float]
    private var frame = [Float](repeating: 0, count: nfft)
    private var re = [Float](repeating: 0, count: nfft / 2)
    private var im = [Float](repeating: 0, count: nfft / 2)
    private var padded = [Float](repeating: 0, count: chunk + nfft)

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = (0..<Self.nfft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.nfft))) }
        var env = [Float](repeating: 0, count: Self.chunk + Self.nfft)
        for t in 0..<Self.frames {
            for i in 0..<Self.nfft { env[t * Self.hop + i] += window[i] * window[i] }
        }
        envelope = env
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// One channel's spectrum into the model input [1, 2050, 801, 2]: row
    /// bin·2 + `channel`, real and imaginary last.
    func forward(_ x: [Float], channel: Int, into spec: UnsafeMutablePointer<Float>) {
        let n = Self.nfft, half = n / 2, pad = n / 2
        // Centred: reflected half a window past both ends.
        for i in 0..<pad { padded[i] = x[pad - i]; padded[pad + Self.chunk + i] = x[Self.chunk - 2 - i] }
        padded.replaceSubrange(pad..<(pad + Self.chunk), with: x)
        for t in 0..<Self.frames {
            let at = t * Self.hop
            for i in 0..<n { frame[i] = padded[at + i] * window[i] }
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // (zrip gives twice the DFT, DC and Nyquist packed in bin 0.)
            for k in 0..<Self.bins {
                let (a, b): (Float, Float) = k == 0 ? (re[0], 0) : k == half ? (im[0], 0) : (re[k], im[k])
                let row = k * 2 + channel
                spec[(row * Self.frames + t) * 2] = a / 2
                spec[(row * Self.frames + t) * 2 + 1] = b / 2
            }
        }
    }

    /// `channel` of the spectrum in `spec` times `mask` (same layout),
    /// back to a chunk of samples.
    func inverse(spec: UnsafePointer<Float>, mask: [Float], channel: Int, into out: inout [Float]) {
        let n = Self.nfft, half = n / 2, pad = n / 2
        for i in padded.indices { padded[i] = 0 }
        for t in 0..<Self.frames {
            for k in 0..<Self.bins {
                let at = ((k * 2 + channel) * Self.frames + t) * 2
                let a = spec[at], b = spec[at + 1], c = mask[at], d = mask[at + 1]
                let y = (a * c - b * d, a * d + b * c)
                if k == 0 { re[0] = y.0 } else if k == half { im[0] = y.0 } else { re[k] = y.0; im[k] = y.1 }
            }
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBytes { raw in
                        vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                    }
                }
            }
            // (zrip's inverse of a spectrum gives n times its signal.)
            let at = t * Self.hop
            for i in 0..<n { padded[at + i] += frame[i] / Float(n) * window[i] }
        }
        for i in 0..<Self.chunk {
            let e = envelope[pad + i]
            out[i] = e > 1e-11 ? padded[pad + i] / e : 0
        }
    }
}
