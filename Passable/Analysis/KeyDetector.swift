import Accelerate

struct MusicalKey: Codable, Equatable, Hashable {
    let tonicPitchClass: Int // 0 = C, 1 = C#, ... 11 = B
    let isMajor: Bool

    private static let majorCamelotNumbers = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    private static let minorCamelotNumbers = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
    private static let pitchClassNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    var camelotNumber: Int { isMajor ? Self.majorCamelotNumbers[tonicPitchClass] : Self.minorCamelotNumbers[tonicPitchClass] }
    var camelotLetter: String { isMajor ? "B" : "A" }
    var camelotCode: String { "\(camelotNumber)\(camelotLetter)" }
    var displayName: String { "\(Self.pitchClassNames[tonicPitchClass]) \(isMajor ? "maj" : "min")" }

    func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(tonicPitchClass: ((tonicPitchClass + semitones) % 12 + 12) % 12, isMajor: isMajor)
    }

    /// The smallest pitch shift that puts `self` in a key that mixes cleanly
    /// with `target`: the same key, its relative major/minor, or a fifth either
    /// side on the Camelot wheel. A shift of ±5 semitones and up is audible as
    /// chipmunking, so a fifth-neighbour one step away usually beats a big
    /// jump to the exact key.
    /// Like `harmonicShift(toMatch:)`, but nil when every compatible key is
    /// further than `limit` semitones away: past ±2 the shift itself is
    /// audible, and a clean key clash is often the lesser evil.
    func harmonicShift(toMatch target: MusicalKey, limit: Int) -> Int? {
        let shift = harmonicShift(toMatch: target)
        if abs(shift) <= limit { return shift }
        // A Camelot neighbour within the limit is still a good mix.
        for d in stride(from: 0, through: limit, by: 1).flatMap({ [$0, -$0] }) {
            let n = abs(transposed(by: d).camelotNumber - target.camelotNumber)
            let sameLetter = isMajor == target.isMajor
            if (n == 0 && !sameLetter) || (sameLetter && (n <= 1 || n == 11)) { return d }
        }
        return nil
    }

    func harmonicShift(toMatch target: MusicalKey) -> Int {
        // The tonic `self` would need, in its own mode, to share target's scale.
        let sameScale: Int
        if isMajor == target.isMajor {
            sameScale = target.tonicPitchClass
        } else if isMajor {
            sameScale = (target.tonicPitchClass + 3) % 12 // relative major
        } else {
            sameScale = (target.tonicPitchClass + 9) % 12 // relative minor
        }
        func wrapped(_ d: Int) -> Int {
            let m = ((d % 12) + 12) % 12
            return m > 6 ? m - 12 : m
        }
        let exact = wrapped(sameScale - tonicPitchClass)
        let neighbours = [wrapped(sameScale + 7 - tonicPitchClass), wrapped(sameScale - 7 - tonicPitchClass)]
        // Take a neighbour only when it saves at least two semitones of shifting.
        if let best = neighbours.min(by: { abs($0) < abs($1) }), abs(best) + 2 <= abs(exact) {
            return best
        }
        return exact
    }
}

/// Key estimation via a chroma vector (12 pitch-class energy bins) correlated
/// against the standard Krumhansl-Schmuckler major/minor key profiles.
struct KeyDetector {
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func detect(samples: [Float], sampleRate: Double) -> MusicalKey {
        let chroma = computeChroma(samples: samples, sampleRate: sampleRate)

        var bestScore = -Double.infinity
        var bestPitchClass = 0
        var bestIsMajor = true

        for pitchClass in 0..<12 {
            let majorScore = correlation(chroma, rotate(majorProfile, by: pitchClass))
            if majorScore > bestScore {
                bestScore = majorScore
                bestPitchClass = pitchClass
                bestIsMajor = true
            }
            let minorScore = correlation(chroma, rotate(minorProfile, by: pitchClass))
            if minorScore > bestScore {
                bestScore = minorScore
                bestPitchClass = pitchClass
                bestIsMajor = false
            }
        }
        return MusicalKey(tonicPitchClass: bestPitchClass, isMajor: bestIsMajor)
    }

    private static func rotate(_ profile: [Double], by amount: Int) -> [Double] {
        (0..<12).map { profile[(($0 - amount) % 12 + 12) % 12] }
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        guard n > 0 else { return 0 }
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var num = 0.0, denomA = 0.0, denomB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            num += da * db
            denomA += da * da
            denomB += db * db
        }
        let denom = (denomA * denomB).squareRoot()
        return denom > 0 ? num / denom : 0
    }

    /// Energy per pitch class of `samples`, scaled so the strongest is 1.
    static func computeChroma(samples: [Float], sampleRate: Double) -> [Double] {
        let frameSize = 4096
        let hopSize = 2048
        guard samples.count >= frameSize else { return [Double](repeating: 0, count: 12) }

        let fft = RealFFT(size: frameSize)
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        let binHz = sampleRate / Double(frameSize)

        // Below ~100Hz a 4096-point bin is wider than a semitone, so those bins
        // smear across pitch classes instead of informing them; above 5kHz
        // there is little tonal content left.
        var binsByPitchClass = [[Int]](repeating: [], count: 12)
        for k in 1..<(frameSize / 2) {
            let freq = Double(k) * binHz
            guard freq >= 100, freq <= 5000 else { continue }
            let midi = 69.0 + 12.0 * log2(freq / 440.0)
            binsByPitchClass[((Int(midi.rounded()) % 12) + 12) % 12].append(k)
        }

        var chroma = [Double](repeating: 0, count: 12)
        var frame = [Float](repeating: 0, count: frameSize)

        var offset = 0
        while offset + frameSize <= samples.count {
            samples.withUnsafeBufferPointer {
                vDSP_vmul($0.baseAddress! + offset, 1, window, 1, &frame, 1, vDSP_Length(frameSize))
            }
            let magnitudes = fft.magnitudes(of: frame)
            for pitchClass in 0..<12 {
                var sum: Float = 0
                for k in binsByPitchClass[pitchClass] { sum += magnitudes[k] }
                chroma[pitchClass] += Double(sum)
            }
            offset += hopSize
        }

        let maxVal = chroma.max() ?? 1
        if maxVal > 0 {
            for i in 0..<12 { chroma[i] /= maxVal }
        }
        return chroma
    }
}
