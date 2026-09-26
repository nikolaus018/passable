import Accelerate

struct TrackAnalysis: Codable, Equatable {
    var grid: BeatGrid
    var key: MusicalKey
    var duration: Double
    /// Optional so analyses cached before it existed still decode; the
    /// loader fills it in.
    var structure: TrackStructure?
    /// Analyses older than `currentVersion` are redone on load.
    var version: Int?

    static let currentVersion = 4
}

enum TrackAnalyzer {
    /// Analyses a track from its stems, which beats analysing the mix: the
    /// drum stem gives a clean rhythm signal for the beat grid, and bass +
    /// melody give a key estimate that vocals and hi-hats can't skew.
    static func analyze(stems: [StemKind: StemAudio]) -> TrackAnalysis {
        let sr = AudioIO.sampleRate
        let drums = stems[.drums].map { $0.copyStereo().mono() } ?? []
        let harmony = sum(of: [stems[.bass], stems[.other]].compactMap { $0 })
        let duration = Double(stems.values.map(\.count).max() ?? 0) / sr
        // A drumless track (ambient, a cappella intro) has no rhythm stem to
        // speak of; fall back to the harmonic content.
        let rhythm = rms(drums) > 1e-3 ? drums : sum(of: Array(stems.values))
        let layers = [StemKind.drums, .bass, .other].compactMap { stems[$0]?.copyStereo().mono() }
        let grid = TempoEstimator.estimate(rhythm: rhythm, harmony: harmony, layers: layers, sampleRate: sr)
        let key = KeyDetector.detect(samples: harmony, sampleRate: sr)
        return TrackAnalysis(grid: grid, key: key, duration: duration,
                             structure: TrackStructure.measure(stems: stems, grid: grid),
                             version: TrackAnalysis.currentVersion)
    }

    private static func sum(of stems: [StemAudio]) -> [Float] {
        let n = stems.map(\.count).max() ?? 0
        var out = [Float](repeating: 0, count: n)
        for stem in stems {
            let m = stem.count
            vDSP_vadd(out, 1, stem.left.pointer, 1, &out, 1, vDSP_Length(m))
            vDSP_vadd(out, 1, stem.right.pointer, 1, &out, 1, vDSP_Length(m))
        }
        var half: Float = 0.5
        vDSP_vsmul(out, 1, &half, &out, 1, vDSP_Length(n))
        return out
    }

    private static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(x, 1, &r, vDSP_Length(x.count))
        return r
    }
}
