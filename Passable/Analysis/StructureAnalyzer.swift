import Accelerate
import CoreML

/// Functional music structure segmentation (intro, verse, chorus, bridge,
/// break, inst, solo, outro) and neural section boundaries from All-In-One
/// (`mir-aidj/all-in-one`, Kim & Nam ISMIR 2023), exported to Core ML by
/// `tools/convert-structure/convert.py`.
///
/// The model listens directly to the four stems Passable already separates
/// (`bass`, `drums`, `other`, `vocals`) as 100 FPS 81-band log-filtered
/// spectrograms (matching madmom's `LogarithmicFilteredSpectrogramProcessor`),
/// so structure analysis adds ~50 ms of GPU inference with zero extra stem
/// separation. When `Structure.mlmodelc` is absent from the bundle, `shared`
/// is `nil` and `TrackStructure` falls back transparently to its heuristic
/// novelty and repetition scores.
final class StructureAnalyzer: @unchecked Sendable {
    struct Result: Equatable {
        var sections: [TrackStructure.Section]
        var neuralBoundary: [Float]
        var chorusScore: [Float]
    }

    /// `nil` when `Structure.mlmodelc` is not bundled: analysis continues with
    /// heuristic section novelty and chroma repetition.
    static let shared: StructureAnalyzer? = try? StructureAnalyzer()

    static let sampleRate = 44_100.0
    static let fftSize = 2048
    static let hop = 441
    static let fps = 100.0
    static let fftBins = fftSize / 2
    /// 12 bands/octave between 30 Hz and 17 kHz at 44.1 kHz / 2048 FFT → 81 bands.
    static let bands = 81
    /// Stem order expected by `mir-aidj/all-in-one`.
    static let stemOrder: [StemKind] = [.bass, .drums, .other, .vocals]
    /// Harmonix functional labels in the model's exact output channel order.
    static let labels: [TrackStructure.SectionLabel] = [
        .start, .end, .intro, .outro, .break, .bridge, .inst, .solo, .verse, .chorus,
    ]

    /// Sparse triangular filterbank row mapping FFT magnitude bins → one log band.
    struct BandFilter {
        let startBin: Int
        let weights: [Float]
    }

    /// Exact madmom `LogarithmicFilterbank(num_bands=12, fmin=30, fmax=17000, norm_filters=True)`.
    static let filterbank: [BandFilter] = buildFilterbank()

    private let model: MLModel
    private let lock = NSLock()
    /// Fixed chunk length if the exported Core ML graph uses a static time axis,
    /// or `nil` for dynamic `RangeDim` models.
    private let fixedFrames: Int?

    init(model modelURL: URL? = nil, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        guard let url = modelURL ?? Bundle.main.url(forResource: "Structure", withExtension: "mlmodelc")
                ?? ModelLocation.fallback(named: "Structure") else {
            throw PassableError.message("Structure model is missing from the app bundle. Run tools/convert-structure/convert.py and rebuild.")
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: config)
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        fixedFrames = meta["fixed_frames"].flatMap { Int($0) }
    }

    /// Segments a song from its four stems and beat grid into bar-aligned
    /// functional sections, per-bar boundary probabilities, and chorus scores.
    func analyze(stems: [StemKind: StemAudio], grid: BeatGrid, barCount: Int) throws -> Result {
        guard barCount > 0 else { return Result(sections: [], neuralBoundary: [], chorusScore: []) }
        let stemArrays: [[Float]] = Self.stemOrder.map { kind in
            guard let stem = stems[kind] else { return [] }
            return Self.mono(stem)
        }
        let minSamples = stemArrays.map(\.count).min() ?? 0
        guard minSamples >= Self.fftSize else {
            return Result(sections: [], neuralBoundary: [Float](repeating: 0, count: barCount),
                          chorusScore: [Float](repeating: 0, count: barCount))
        }
        let specs = stemArrays.map { Self.logFilteredSpectrogram($0, sampleCount: minSamples) }
        let frames = specs.map { $0.count / Self.bands }.min() ?? 0
        guard frames > 0 else {
            return Result(sections: [], neuralBoundary: [Float](repeating: 0, count: barCount),
                          chorusScore: [Float](repeating: 0, count: barCount))
        }
        let (sectionProbs, functionProbs) = try predict(specs: specs, frames: frames)
        return Self.decode(sectionProbs: sectionProbs, functionProbs: functionProbs,
                           frames: frames, grid: grid, barCount: barCount)
    }

    private func predict(specs: [[Float]], frames: Int) throws -> (section: [Float], function: [Float]) {
        let targetFrames = fixedFrames ?? frames
        if frames <= targetFrames {
            return try predictWindow(specs: specs, offset: 0, runFrames: frames, targetFrames: targetFrames)
        }
        return try Self.stitchWindows(totalFrames: frames, windowFrames: targetFrames, numLabels: Self.labels.count) { offset, runFrames in
            try self.predictWindow(specs: specs, offset: offset, runFrames: runFrames, targetFrames: targetFrames)
        }
    }

    /// Runs overlapping `windowFrames` inference windows over a long track
    /// (`totalFrames > windowFrames`, e.g. >7 min extended club mixes) and
    /// crossfades their overlap zones linearly so predictions stay seamless
    /// to the end of the song.
    static func stitchWindows(totalFrames: Int, windowFrames: Int, numLabels: Int,
                              predict: (Int, Int) throws -> (section: [Float], function: [Float])) throws -> (section: [Float], function: [Float]) {
        let overlap = min(6_000, max(1, windowFrames / 4))
        let stride = max(1, windowFrames - overlap)
        var section = [Float](repeating: 0, count: totalFrames)
        var function = [Float](repeating: 0, count: numLabels * totalFrames)
        var weights = [Float](repeating: 0, count: totalFrames)

        var offsets: [Int] = []
        var off = 0
        while off + windowFrames < totalFrames {
            offsets.append(off)
            off += stride
        }
        offsets.append(max(0, totalFrames - windowFrames))

        for (idx, start) in offsets.enumerated() {
            let run = min(windowFrames, totalFrames - start)
            let (sec, fn) = try predict(start, run)
            let fadeIn = idx > 0 ? min(overlap, run / 2) : 0
            let fadeOut = idx + 1 < offsets.count ? min(overlap, run / 2) : 0
            for t in 0..<run {
                let wIn: Float = fadeIn > 0 && t < fadeIn ? Float(t + 1) / Float(fadeIn + 1) : 1
                let wOut: Float = fadeOut > 0 && t >= run - fadeOut ? Float(run - t) / Float(fadeOut + 1) : 1
                let w = min(wIn, wOut)
                let dst = start + t
                section[dst] += sec[t] * w
                weights[dst] += w
                for c in 0..<numLabels {
                    function[c * totalFrames + dst] += fn[c * run + t] * w
                }
            }
        }
        for t in 0..<totalFrames where weights[t] > 0 {
            let inv = 1.0 / weights[t]
            section[t] *= inv
            for c in 0..<numLabels { function[c * totalFrames + t] *= inv }
        }
        return (section, function)
    }

    private func predictWindow(specs: [[Float]], offset: Int, runFrames: Int, targetFrames: Int) throws -> (section: [Float], function: [Float]) {
        let numLabels = Self.labels.count
        let bands = Self.bands
        let input = try MLMultiArray(shape: [1, 4, NSNumber(value: targetFrames), NSNumber(value: bands)],
                                     dataType: .float32)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
        vDSP_vclr(ptr, 1, vDSP_Length(4 * targetFrames * bands))
        for k in 0..<4 {
            let dst = ptr + k * targetFrames * bands
            specs[k].withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress! + offset * bands, count: runFrames * bands)
            }
        }
        lock.lock()
        let out: MLFeatureProvider
        do {
            out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spec": input]))
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        guard let secArr = out.featureValue(for: "section")?.multiArrayValue,
              let fnArr = out.featureValue(for: "function")?.multiArrayValue else {
            throw PassableError.message("Structure model returned incomplete outputs.")
        }
        var section = [Float](repeating: 0, count: runFrames)
        let secStride = secArr.strides.last?.intValue ?? 1
        for t in 0..<runFrames {
            section[t] = secArr[t * secStride].floatValue
        }
        // function shape: [1, 10, T]
        var function = [Float](repeating: 0, count: numLabels * runFrames)
        let fnStrides = fnArr.strides.map(\.intValue)
        let cStride = fnStrides.count >= 2 ? fnStrides[fnStrides.count - 2] : targetFrames
        let tStride = fnStrides.last ?? 1
        for c in 0..<numLabels {
            let row = c * runFrames
            let base = c * cStride
            for t in 0..<runFrames {
                function[row + t] = fnArr[base + t * tStride].floatValue
            }
        }
        return (section, function)
    }

    // MARK: - Spectrogram Extraction (Accelerate)

    private static func mono(_ stem: StemAudio) -> [Float] {
        let n = stem.count
        var out = [Float](repeating: 0, count: n)
        var half: Float = 0.5
        vDSP_vadd(stem.left.pointer, 1, stem.right.pointer, 1, &out, 1, vDSP_Length(n))
        vDSP_vsmul(out, 1, &half, &out, 1, vDSP_Length(n))
        return out
    }

    /// 100 FPS 81-band log-filtered magnitude spectrogram (`[frames × 81]`),
    /// matching madmom's `FramedSignalProcessor(2048, fps=100)` +
    /// `ShortTimeFourierTransformProcessor` + `LogarithmicFilteredSpectrogramProcessor`
    /// + `LogarithmicSpectrogramProcessor(mul=1, add=1)`.
    static func logFilteredSpectrogram(_ mono: [Float], sampleCount: Int? = nil) -> [Float] {
        let count = min(mono.count, sampleCount ?? mono.count)
        let n = fftSize, half = n / 2
        guard count > 0 else { return [] }
        let frames = (count + hop - 1) / hop
        // Symmetric Hann window matching `np.hanning(2048)` used by madmom.
        let denom = Double(n - 1)
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / denom)) }
        let log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var mag = [Float](repeating: 0, count: half)
        var out = [Float](repeating: 0, count: frames * bands)
        let fb = filterbank

        for f in 0..<frames {
            let start = f * hop - half
            for k in 0..<n {
                let idx = start + k
                frame[k] = (idx >= 0 && idx < count) ? mono[idx] * window[k] : 0
            }
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    let dc = abs(re[0])
                    im[0] = 0
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                    mag[0] = dc
                }
            }
            // vDSP_fft_zrip scales forward DFT by 2.
            var inv2: Float = 0.5
            vDSP_vsmul(mag, 1, &inv2, &mag, 1, vDSP_Length(half))
            let rowBase = f * bands
            for b in 0..<fb.count {
                let filt = fb[b]
                var acc: Float = 0
                for j in 0..<filt.weights.count {
                    acc += mag[filt.startBin + j] * filt.weights[j]
                }
                out[rowBase + b] = log10f(acc + 1.0)
            }
        }
        return out
    }

    private static func buildFilterbank() -> [BandFilter] {
        let numBands = 12.0, fmin = 30.0, fmax = 17_000.0, a4 = 440.0
        let lo = Int(ceil(numBands * log2(fmin / a4)))
        let hi = Int(floor(numBands * log2(fmax / a4)))
        var seen = Set<Int>()
        var bins: [Int] = []
        for k in lo...hi {
            let f = a4 * pow(2.0, Double(k) / numBands)
            let bin = Int((f * Double(fftSize) / sampleRate).rounded())
            if bin >= 0 && bin < fftBins && seen.insert(bin).inserted {
                bins.append(bin)
            }
        }
        bins.sort()
        guard bins.count >= 3 else { return [] }
        var filters: [BandFilter] = []
        filters.reserveCapacity(bins.count - 2)
        for i in 0..<(bins.count - 2) {
            let left = bins[i], center = bins[i + 1], right = bins[i + 2]
            let width = right - left + 1
            var w = [Float](repeating: 0, count: width)
            if center > left {
                for b in left...center {
                    w[b - left] = Float(b - left) / Float(center - left)
                }
            }
            w[center - left] = 1.0
            if right > center {
                for b in center...right {
                    w[b - left] = Float(right - b) / Float(right - center)
                }
            }
            let sum = w.reduce(0, +)
            if sum > 0 {
                for j in w.indices { w[j] /= sum }
            }
            filters.append(BandFilter(startBin: left, weights: w))
        }
        return filters
    }

    // MARK: - Bar-Aligned Decoding

    /// Aggregates 100 FPS frame-level boundary probabilities (`sectionProbs`,
    /// length `frames`) and 10-class functional probabilities (`functionProbs`,
    /// row-major `[10 × frames]`) onto `grid`'s bars.
    static func decode(sectionProbs: [Float], functionProbs: [Float], frames: Int,
                       grid: BeatGrid, barCount: Int) -> Result {
        guard barCount > 0, frames > 0 else {
            return Result(sections: [], neuralBoundary: [Float](repeating: 0, count: max(0, barCount)),
                          chorusScore: [Float](repeating: 0, count: max(0, barCount)))
        }
        let numLabels = labels.count
        var neuralBoundary = [Float](repeating: 0, count: barCount)
        var chorusScore = [Float](repeating: 0, count: barCount)
        var barClassProbs = [[Float]](repeating: [Float](repeating: 0, count: numLabels), count: barCount)

        for b in 0..<barCount {
            let t0 = grid.downbeat(b)
            let t1 = grid.downbeat(b + 1)
            let barDur = max(0.25, t1 - t0)
            // Peak boundary probability within ±25 % of a bar around downbeat `b`.
            let bLo = max(0, Int(((t0 - 0.25 * barDur) * fps).rounded(.down)))
            let bHi = min(frames - 1, Int(((t0 + 0.25 * barDur) * fps).rounded(.up)))
            if bLo <= bHi {
                var peak: Float = 0
                for f in bLo...bHi where sectionProbs[f] > peak { peak = sectionProbs[f] }
                neuralBoundary[b] = min(1, max(0, peak))
            }
            // Mean class distribution across bar `b`.
            let f0 = max(0, Int((t0 * fps).rounded(.down)))
            let f1 = min(frames, Int((t1 * fps).rounded(.up)))
            if f1 > f0 {
                let inv = 1.0 / Float(f1 - f0)
                for c in 0..<numLabels {
                    let row = c * frames
                    var sum: Float = 0
                    for f in f0..<f1 { sum += functionProbs[row + f] }
                    barClassProbs[b][c] = sum * inv
                }
            }
            // Chorus / drop-payoff score combining chorus + instrumental drop.
            let pChorus = barClassProbs[b][9]
            let pInst = barClassProbs[b][6]
            let pSolo = barClassProbs[b][7]
            chorusScore[b] = min(1, pChorus + 0.45 * (pInst + pSolo))
        }

        // Normalize boundary salience relative to the track's own peak so
        // downstream weights stay in 0…1 even when raw sigmoid peaks are ~0.3.
        if let maxB = neuralBoundary.max(), maxB > 0.05 {
            let scale = min(1.0 / maxB, 4.0)
            for b in 0..<barCount { neuralBoundary[b] = min(1, neuralBoundary[b] * scale) }
        }

        // Find section split bars: bar 0 plus strong local peaks of `neuralBoundary`
        // at least 4 bars apart.
        var splits: [Int] = [0]
        for b in stride(from: 4, to: barCount, by: 1) {
            let v = neuralBoundary[b]
            guard v >= 0.28 else { continue }
            let lo = max(0, b - 2), hi = min(barCount - 1, b + 2)
            let isPeak = (lo...hi).allSatisfy { neuralBoundary[$0] <= v }
            if isPeak, b - (splits.last ?? 0) >= 4 {
                splits.append(b)
            }
        }
        splits.append(barCount)

        // Assign each segment its dominant functional label (ignoring `start`/`end`
        // for interior segments when musical classes carry meaningful mass).
        var rawSections: [TrackStructure.Section] = []
        for s in 0..<(splits.count - 1) {
            let lo = splits[s], hi = splits[s + 1]
            guard hi > lo else { continue }
            var sums = [Float](repeating: 0, count: numLabels)
            for b in lo..<hi {
                for c in 0..<numLabels { sums[c] += barClassProbs[b][c] }
            }
            let inv = 1.0 / Float(hi - lo)
            for c in 0..<numLabels { sums[c] *= inv }
            // Prefer musical labels (indices 2..<10) unless start/end dominates >0.85.
            let bestMusical = (2..<numLabels).max { sums[$0] < sums[$1] } ?? 8
            let bestAll = (0..<numLabels).max { sums[$0] < sums[$1] } ?? bestMusical
            let chosen = (bestAll < 2 && sums[bestAll] > 0.85) ? bestAll : bestMusical
            rawSections.append(.init(startBar: lo, endBar: hi, label: labels[chosen], confidence: sums[chosen]))
        }

        // Merge consecutive identical labels unless separated by a strong boundary.
        var sections: [TrackStructure.Section] = []
        for sec in rawSections {
            if let last = sections.last, last.label == sec.label, neuralBoundary[sec.startBar] < 0.65 {
                let lenA = Float(last.endBar - last.startBar)
                let lenB = Float(sec.endBar - sec.startBar)
                let conf = (last.confidence * lenA + sec.confidence * lenB) / max(1, lenA + lenB)
                sections[sections.count - 1] = .init(startBar: last.startBar, endBar: sec.endBar,
                                                     label: last.label, confidence: conf)
            } else {
                sections.append(sec)
            }
        }

        return Result(sections: sections, neuralBoundary: neuralBoundary, chorusScore: chorusScore)
    }
}
