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

    /// Like `harmonicShift(toMatch:)`, but nil when every compatible key is
    /// further than `limit` semitones away: past ±2 the shift itself is
    /// audible, and a clean key clash is often the lesser evil. (With a
    /// limit of 0: whether the two keys mix as they are.)
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

    /// The smallest pitch shift that puts `self` in a key that mixes cleanly
    /// with `target`: the same key, its relative major/minor, or a fifth either
    /// side on the Camelot wheel. A shift of ±5 semitones and up is audible as
    /// chipmunking, so a fifth-neighbour one step away usually beats a big
    /// jump to the exact key.
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

/// Key estimation from a chroma vector (12 pitch-class energies): the
/// diatonic scale the song's notes fit best, and of its two keys (a major
/// and its relative minor) the one whose Krumhansl-Schmuckler profile the
/// notes follow more closely.
///
/// The scale is what mixing goes by (songs in relative keys share every
/// note), and it is found the way `Harmony.clash` judges two songs together,
/// so a key and a clash never disagree about the same notes. Correlating
/// all 24 key profiles instead named a key a fifth off for a third of the
/// songs checked against their published keys.
struct KeyDetector {
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    private static let majorScale = [0, 2, 4, 5, 7, 9, 11]

    static func detect(samples: [Float], sampleRate: Double) -> MusicalKey {
        key(of: computeChroma(samples: samples, sampleRate: sampleRate))
    }

    /// The key a chroma vector sits in (see above).
    static func key(of chroma: [Double]) -> MusicalKey {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else {
            return MusicalKey(tonicPitchClass: 0, isMajor: true)
        }
        func inScale(_ tonic: Int) -> Double { majorScale.reduce(0) { $0 + chroma[($1 + tonic) % 12] } }
        let tonic = (0..<12).max { inScale($0) < inScale($1) }!
        let relative = (tonic + 9) % 12
        let major = correlation(chroma, rotate(majorProfile, by: tonic))
        let minor = correlation(chroma, rotate(minorProfile, by: relative))
        return major >= minor ? MusicalKey(tonicPitchClass: tonic, isMajor: true)
            : MusicalKey(tonicPitchClass: relative, isMajor: false)
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

    /// Energy per pitch class of `samples`, scaled so the strongest is 1
    /// (or as measured: stretches then add up to what the whole would give).
    ///
    /// The notes themselves: the peaks of the spectrum from 55 Hz to 2 kHz
    /// (fundamentals and their first few overtones), each counted once, at
    /// its own strength, for the pitch it sits on. Summing every bin of the
    /// spectrum up to 5 kHz instead (as this did) counts whatever fills the
    /// spectrum between the notes and above them, and the top octaves have
    /// by far the most bins: every song then leaned towards the same few
    /// pitch classes, a fifth-off key was named for a third of them, and of
    /// stretches of two songs in clashing keys, 4 % were heard to clash
    /// (now about three in four; measured on songs with published keys).
    static func computeChroma(samples: [Float], sampleRate: Double, normalised: Bool = true) -> [Double] {
        // A quarter of the rate (each sample the mean of four) puts
        // 1.35 Hz between the bins of an 8192-point frame: a semitone at
        // 55 Hz is 3.3 Hz wide.
        let factor = 4, frameSize = 8192, hopSize = 4096
        var chroma = [Double](repeating: 0, count: 12)
        let count = samples.count / factor
        guard count >= frameSize else { return chroma }
        var slow = [Float](repeating: 0, count: count)
        let mean = [Float](repeating: 1 / Float(factor), count: factor)
        vDSP_desamp(samples, vDSP_Stride(factor), mean, &slow, vDSP_Length(count), vDSP_Length(factor))

        let fft = RealFFT(size: frameSize)
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        let binHz = sampleRate / Double(factor) / Double(frameSize)
        let first = max(1, Int((55 / binHz).rounded(.up))), last = min(frameSize / 2 - 2, Int(2000 / binHz))
        var frame = [Float](repeating: 0, count: frameSize)

        var offset = 0
        while offset + frameSize <= count {
            slow.withUnsafeBufferPointer {
                vDSP_vmul($0.baseAddress! + offset, 1, window, 1, &frame, 1, vDSP_Length(frameSize))
            }
            offset += hopSize
            let m = fft.magnitudes(of: frame)
            var strongest: Float = 0
            for k in first...last where m[k] > m[k - 1] && m[k] >= m[k + 1] { strongest = max(strongest, m[k]) }
            guard strongest > 0 else { continue }
            // Peaks within 34 dB of the strongest: below that it's noise
            // and what separation left behind.
            for k in first...last where m[k] > m[k - 1] && m[k] >= m[k + 1] && m[k] > 0.02 * strongest {
                // Where between the bins the peak really is (a parabola
                // through the log magnitudes), and how far that is from
                // the nearest note: a peak between two notes counts for
                // neither.
                let a = log(Double(m[k - 1]) + 1e-12), b = log(Double(m[k])), c = log(Double(m[k + 1]) + 1e-12)
                let curve = a - 2 * b + c
                let bin = Double(k) + (curve < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / curve)) : 0)
                let midi = 69 + 12 * log2(bin * binHz / 440)
                let note = midi.rounded()
                let weight = cos((midi - note) * Double.pi)
                chroma[((Int(note) % 12) + 12) % 12] += Double(m[k]) * weight * weight
            }
        }

        let maxVal = chroma.max() ?? 1
        if normalised, maxVal > 0 {
            for i in 0..<12 { chroma[i] /= maxVal }
        }
        return chroma
    }
}
