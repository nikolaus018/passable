import Accelerate

/// A constant-tempo grid: beat `i` falls at `firstDownbeat + i · beatSeconds`,
/// and every fourth beat from there is a downbeat. Negative indices are the
/// pickup beats before the first downbeat.
struct BeatGrid: Codable, Equatable {
    var bpm: Double
    /// Seconds from the start of the file to the first downbeat (< one bar).
    var firstDownbeat: Double

    var beatSeconds: Double { 60 / bpm }
    var barSeconds: Double { 4 * beatSeconds }

    func beat(_ index: Int) -> Double { firstDownbeat + Double(index) * beatSeconds }
    func downbeat(_ bar: Int) -> Double { firstDownbeat + Double(bar) * barSeconds }

    /// Whole bars that start inside a file of this length.
    func barCount(duration: Double) -> Int {
        max(1, Int(((duration - firstDownbeat) / barSeconds).rounded(.down)))
    }

    /// The grid as it would be heard played `rate` times faster.
    func scaled(by rate: Double) -> BeatGrid {
        BeatGrid(bpm: bpm * rate, firstDownbeat: firstDownbeat / rate)
    }
}

/// Estimates a constant-tempo beat grid.
///
/// Tempo and beat phase come from a spectral-flux onset envelope (ideally of
/// the separated drum stem, where nothing but rhythm is left to confuse it):
/// autocorrelation picks the period, then a comb search over the whole track
/// refines period and phase to a small fraction of a frame — at 128 BPM a
/// 0.01 % period error drifts a 1/20th of a beat over a four-minute song,
/// which is the difference between a locked blend and flamming kicks.
///
/// The downbeat is the beat phase (of four) where harmony tends to change and
/// the low end hits hardest.
enum TempoEstimator {
    static let hop = 441                  // 10 ms at 44.1 kHz
    static let frameSize = 1024
    private static let minBPM = 70.0
    private static let maxBPM = 180.0

    static func estimate(rhythm: [Float], harmony: [Float]?, sampleRate: Double) -> BeatGrid {
        let fps = sampleRate / Double(hop)
        let (flux, lowFlux) = onsetEnvelopes(rhythm, sampleRate: sampleRate)
        guard flux.count > Int(fps * 4) else { return BeatGrid(bpm: 120, firstDownbeat: 0) }
        let onset = detrended(flux, window: Int(fps / 2))

        let coarse = coarsePeriod(onset, fps: fps)
        var (period, phase) = refine(onset, around: coarse)

        // The tempo prior can pull autocorrelation onto a 3:4 or 2:3 relative
        // of the real beat (Umbrella's 87 BPM read as 116). The true grid
        // lands on kicks and snares every time; a wrong-metre grid only
        // coincides with them every third or fourth beat, so its onsets
        // average clearly lower.
        let score = combScore(onset, period: period, phase: phase)
        var bestAlternative: (period: Double, phase: Double, score: Double)?
        for ratio in [4.0 / 3, 3.0 / 4, 3.0 / 2, 2.0 / 3] {
            let candidate = period * ratio
            let bpm = 60 * fps / candidate
            guard bpm >= minBPM / 2, bpm <= maxBPM else { continue }
            let (p, ph) = refine(onset, around: candidate)
            let sc = combScore(onset, period: p, phase: ph)
            if sc > 1.25 * score, sc > (bestAlternative?.score ?? 0) { bestAlternative = (p, ph, sc) }
        }
        if let alt = bestAlternative { (period, phase) = (alt.period, alt.phase) }
        // Keep the result in range; slow candidates get doubled below.
        while 60 * fps / period < minBPM {
            (period, phase) = refine(onset, around: period / 2)
        }

        // Autocorrelation leans towards the slower octave. If every beat of
        // the double-time grid carries (nearly) as much onset energy as the
        // current one, the music really is that fast — 174 BPM drum & bass,
        // not 87.
        if 60 * fps / (period / 2) <= maxBPM {
            let full = combScore(onset, period: period, phase: phase)
            let (halfPeriod, halfPhase) = combSearch(onset, periods: stride(from: period / 2 - 0.004, through: period / 2 + 0.004, by: 0.0005),
                                                     phaseStep: 0.02, phaseRange: max(0, phase - 0.3)...(phase + 0.3))
            if combScore(onset, period: halfPeriod, phase: halfPhase) >= 0.85 * full {
                (period, phase) = (halfPeriod, halfPhase)
            }
        }

        // Off-beat hats and shakers are broadband, so in overall flux they
        // can out-score the kick and pull the grid half a beat late. Beats
        // are where the low end hits.
        let low = detrended(lowFlux, window: Int(fps / 2))
        if combScore(low, period: period, phase: phase + period / 2) > combScore(low, period: period, phase: phase) {
            phase += period / 2
        }

        let beatPhase = downbeatPhase(period: period, phase: phase, lowFlux: low,
                                      harmony: harmony, sampleRate: sampleRate)
        var first = (phase + Double(beatPhase) * period) / fps
        let bar = 4 * period / fps
        while first >= bar { first -= bar }
        while first < 0 { first += bar }
        return BeatGrid(bpm: 60 * fps / period, firstDownbeat: first)
    }

    // MARK: - Onset envelope

    /// Log-magnitude spectral flux, overall and below 150 Hz, one value per
    /// hop, frames centred on `k · hop`.
    static func onsetEnvelopes(_ samples: [Float], sampleRate: Double) -> (all: [Float], low: [Float]) {
        let n = frameSize
        let count = samples.count / hop
        guard count > 2 else { return ([], []) }
        let fft = RealFFT(size: n)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let lowBins = max(2, Int(150 / (sampleRate / Double(n))))

        var previous = [Float](repeating: 0, count: n / 2)
        var frame = [Float](repeating: 0, count: n)
        var all = [Float](repeating: 0, count: count)
        var low = [Float](repeating: 0, count: count)
        for f in 0..<count {
            let start = f * hop - n / 2
            for k in 0..<n {
                let i = start + k
                frame[k] = (i >= 0 && i < samples.count) ? samples[i] * window[k] : 0
            }
            var mags = fft.magnitudes(of: frame)
            // log(1 + 100·|X|): compresses dynamics so quiet hats count too.
            var gain: Float = 100, one: Float = 1
            vDSP_vsmsa(mags, 1, &gain, &one, &mags, 1, vDSP_Length(mags.count))
            var c = Int32(mags.count)
            vvlogf(&mags, mags, &c)
            var sum: Float = 0, lowSum: Float = 0
            for k in 1..<mags.count {
                let d = mags[k] - previous[k]
                if d > 0 {
                    sum += d
                    if k < lowBins { lowSum += d }
                }
            }
            all[f] = f == 0 ? 0 : sum
            low[f] = f == 0 ? 0 : lowSum
            previous = mags
        }
        return (all, low)
    }

    /// Subtracts a moving average and half-wave rectifies, leaving onsets
    /// that stand out from their surroundings.
    private static func detrended(_ x: [Float], window: Int) -> [Float] {
        let w = max(1, window)
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + Double(x[i]) }
        return (0..<x.count).map { i in
            let lo = max(0, i - w), hi = min(x.count, i + w + 1)
            let mean = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            return max(0, x[i] - Float(mean))
        }
    }

    // MARK: - Tempo

    /// Coarse-to-fine comb search around a period estimate (frames).
    private static func refine(_ onset: [Float], around coarse: Double) -> (period: Double, phase: Double) {
        var (period, phase) = combSearch(onset, periods: stride(from: coarse * 0.98, through: coarse * 1.02, by: 0.005),
                                         phaseStep: 0.1, phaseRange: nil)
        (period, phase) = combSearch(onset, periods: stride(from: period - 0.006, through: period + 0.006, by: 0.0005),
                                     phaseStep: 0.02, phaseRange: max(0, phase - 0.3)...(phase + 0.3))
        return (period, phase)
    }

    private static func coarsePeriod(_ onset: [Float], fps: Double) -> Double {
        let minLag = Int(60 * fps / maxBPM), maxLag = Int(60 * fps / minBPM) + 1
        var ac = [Float](repeating: 0, count: 2 * maxLag + 2)
        let n = onset.count
        for lag in 1..<min(ac.count, n / 2) {
            var dot: Float = 0
            onset.withUnsafeBufferPointer { p in
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))
            }
            ac[lag] = dot / Float(n - lag)
        }
        var bestLag = minLag
        var bestScore = -Float.infinity
        for lag in minLag...maxLag where 2 * lag < ac.count {
            // Reinforce with the bar-level lag and favour tempos near 120 BPM,
            // the usual cure for half/double-time confusion.
            let bpm = 60 * fps / Double(lag)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            let score = (ac[lag] + 0.5 * ac[2 * lag]) * prior
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // Parabolic interpolation around the peak.
        let a = ac[bestLag - 1], b = ac[bestLag], c = ac[bestLag + 1]
        let denom = a - 2 * b + c
        let shift = denom != 0 ? 0.5 * (a - c) / denom : 0
        return Double(bestLag) + Double(max(-0.5, min(0.5, shift)))
    }

    /// Finds the period (in frames) and phase whose beats sit on the most
    /// onset energy across the whole track.
    private static func combSearch(_ onset: [Float], periods: StrideThrough<Double>, phaseStep: Double,
                                   phaseRange: ClosedRange<Double>?) -> (period: Double, phase: Double) {
        var best = (period: 0.0, phase: 0.0, score: -Double.infinity)
        for period in periods where period > 1 {
            let range = phaseRange ?? 0...(period - phaseStep)
            for phase in stride(from: range.lowerBound, through: range.upperBound, by: phaseStep) where phase >= 0 {
                let score = combScore(onset, period: period, phase: phase)
                if score > best.score { best = (period, phase, score) }
            }
        }
        return (best.period, best.phase)
    }

    /// Mean onset strength on the beats of a grid (linear interpolation
    /// between frames, so phase and period resolve below one frame).
    private static func combScore(_ onset: [Float], period: Double, phase: Double) -> Double {
        let n = onset.count
        return onset.withUnsafeBufferPointer { o in
            var sum = 0.0
            var count = 0
            var t = phase
            while t < Double(n - 1) {
                let i = Int(t)
                let frac = Float(t - Double(i))
                sum += Double(o[i] + (o[i + 1] - o[i]) * frac)
                count += 1
                t += period
            }
            return count > 0 ? sum / Double(count) : 0
        }
    }

    // MARK: - Downbeat

    private static func downbeatPhase(period: Double, phase: Double, lowFlux: [Float], harmony: [Float]?,
                                      sampleRate: Double) -> Int {
        let fps = sampleRate / Double(hop)
        var beatFrames: [Double] = []
        var t = phase
        while t < Double(lowFlux.count - 1) { beatFrames.append(t); t += period }
        guard beatFrames.count >= 16 else { return 0 }

        let kick = beatFrames.map { f -> Float in
            let i = Int(f.rounded())
            return (max(0, i - 2)...min(lowFlux.count - 1, i + 2)).map { lowFlux[$0] }.max() ?? 0
        }
        var change = [Float](repeating: 0, count: beatFrames.count)
        if let harmony {
            let chroma = beatChroma(harmony, beatSeconds: beatFrames.map { $0 / fps }, sampleRate: sampleRate)
            for i in 1..<chroma.count { change[i] = 1 - cosine(chroma[i - 1], chroma[i]) }
        }
        let kickNorm = normalised(kick), changeNorm = normalised(change)

        var scores = [Float](repeating: 0, count: 4)
        var counts = [Float](repeating: 0, count: 4)
        for i in 0..<beatFrames.count {
            scores[i % 4] += changeNorm[i] + 0.5 * kickNorm[i]
            counts[i % 4] += 1
        }
        let averages = (0..<4).map { scores[$0] / max(1, counts[$0]) }
        return averages.indices.max(by: { averages[$0] < averages[$1] }) ?? 0
    }

    private static func beatChroma(_ samples: [Float], beatSeconds: [Double], sampleRate: Double) -> [[Float]] {
        let n = 4096
        let fft = RealFFT(size: n)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sampleRate / Double(n)
        var pitchClass = [Int](repeating: -1, count: n / 2)
        for k in 1..<(n / 2) {
            let f = Double(k) * binHz
            guard f >= 60, f <= 4000 else { continue }
            pitchClass[k] = ((Int((69 + 12 * log2(f / 440)).rounded()) % 12) + 12) % 12
        }
        var frame = [Float](repeating: 0, count: n)
        return beatSeconds.map { t in
            // One frame centred just after each beat, where a chord change
            // would have landed.
            let start = Int((t + 0.05) * sampleRate) - n / 2
            for k in 0..<n {
                let i = start + k
                frame[k] = (i >= 0 && i < samples.count) ? samples[i] * window[k] : 0
            }
            let mags = fft.magnitudes(of: frame)
            var chroma = [Float](repeating: 0, count: 12)
            for k in 1..<(n / 2) where pitchClass[k] >= 0 { chroma[pitchClass[k]] += mags[k] }
            return chroma
        }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let d = (na * nb).squareRoot()
        return d > 0 ? dot / d : 1
    }

    private static func normalised(_ x: [Float]) -> [Float] {
        let peak = x.max() ?? 0
        return peak > 0 ? x.map { $0 / peak } : x
    }
}
