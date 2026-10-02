import Accelerate

/// A constant-tempo grid: beat `i` falls at `firstDownbeat + i · beatSeconds`,
/// and every fourth beat from there is a downbeat. Negative indices are the
/// pickup beats before the first downbeat.
///
/// A song played by a drummer has no constant tempo: its beats wander a
/// tenth of a second and more around any such grid. It carries its bars'
/// downbeats one by one instead (`downbeats`, see `Steadiness`), and beats
/// and bars are read off those; `bpm` is then its tempo on the whole. Such
/// a song is never beat-matched (see `MixMath.preset`): it's mixed in and
/// out on its downbeats, where they really are.
struct BeatGrid: Codable, Equatable {
    var bpm: Double
    /// Seconds from the start of the file to the first downbeat (< one bar).
    var firstDownbeat: Double
    /// Each bar's downbeat (seconds), for a song whose bars aren't all
    /// four beats of one tempo; nil for one whose are.
    var downbeats: [Double]? = nil
    /// With `downbeats`: false if the tempo is steady all the same and
    /// only the count of the bars isn't (a song with a bar of two beats
    /// in it: from there on its ones fall where a constant grid has its
    /// threes; see `Steadiness.oddBars`). Its beats are still the grid's.
    var wanders: Bool? = nil

    var beatSeconds: Double { 60 / bpm }
    var barSeconds: Double { 4 * beatSeconds }
    var isSteady: Bool { (downbeats?.count ?? 0) < 2 || wanders == false }

    func beat(_ index: Int) -> Double {
        isSteady ? firstDownbeat + Double(index) * beatSeconds : time(bars: Double(index) / 4)
    }

    /// Whether `bars` are all ordinary ones: four beats long, give or
    /// take what a drummer does.
    func isRegular(_ bars: Range<Int>) -> Bool {
        guard let d = downbeats, d.count >= 2 else { return true }
        return bars.clamped(to: 0..<(d.count - 1)).allSatisfy { abs(d[$0 + 1] - d[$0] - barSeconds) < 0.2 * barSeconds }
    }
    func downbeat(_ bar: Int) -> Double { time(bars: Double(bar)) }

    /// Seconds at which the song is `bars` bars past its first downbeat.
    func time(bars: Double) -> Double {
        guard let d = downbeats, d.count >= 2 else { return firstDownbeat + bars * barSeconds }
        // Between two downbeats, evenly; outside them, at the tempo of the
        // first or last bar.
        let k = min(d.count - 2, max(0, Int(bars.rounded(.down))))
        return d[k] + (bars - Double(k)) * (d[k + 1] - d[k])
    }

    /// Bars past its first downbeat the song is at `seconds`.
    func bars(at seconds: Double) -> Double {
        guard let d = downbeats, d.count >= 2 else { return (seconds - firstDownbeat) / barSeconds }
        var k = d.lastIndex { $0 <= seconds } ?? 0
        k = min(d.count - 2, k)
        return Double(k) + (seconds - d[k]) / (d[k + 1] - d[k])
    }

    /// Whole bars that start inside a file of this length.
    func barCount(duration: Double) -> Int {
        max(1, Int(bars(at: duration).rounded(.down)))
    }

    /// The grid as it would be heard played `rate` times faster.
    func scaled(by rate: Double) -> BeatGrid {
        BeatGrid(bpm: bpm * rate, firstDownbeat: firstDownbeat / rate, downbeats: downbeats.map { $0.map { $0 / rate } })
    }
}

/// Whether a song keeps the tempo of its grid, and its bars one by one if
/// it doesn't.
enum Steadiness {
    /// The downbeat of every bar of a steady song that doesn't count in
    /// fours throughout: one with a bar of two beats (or six) somewhere,
    /// after which a grid of four-beat bars has its ones on the song's
    /// threes, and every phrase placed there starts in the middle of a
    /// bar. nil for a song whose bars are all the grid's.
    ///
    /// The tracker's downbeats say where: a stretch of eight bars or more
    /// in which they fall on another beat of the grid's bar than before.
    /// A tracker can be half a bar out on its own account, though (a beat
    /// that's the same on the one and the three), so each such stretch
    /// has to be borne out by the song's harmony: chords change on the
    /// one more than on the three.
    /// - Parameter turns: how much the harmony changes on beat `i` of the
    ///   grid (from the beat before; nil where there are no notes).
    static func oddBars(grid: BeatGrid, heard: BeatTracker.Beats, duration: Double, turns: (Int) -> Float?) -> [Double]? {
        let beat = grid.beatSeconds
        // Each tracked downbeat as a beat of the grid (those on one).
        let ones = heard.downbeats.compactMap { t -> Int? in
            let i = ((t - grid.firstDownbeat) / beat).rounded()
            return abs(t - (grid.firstDownbeat + i * beat)) < 0.25 * beat ? Int(i) : nil
        }
        guard ones.count >= 16 else { return nil }
        func phase(_ i: Int) -> Int { ((i % 4) + 4) % 4 }
        // Runs of downbeats on the same beat of the bar; shorter than
        // eight bars is the tracker's slip, not the song's.
        var runs: [(first: Int, phase: Int, count: Int)] = []
        for i in ones {
            if let last = runs.last, last.phase == phase(i) { runs[runs.count - 1].count += 1 } else { runs.append((i, phase(i), 1)) }
        }
        runs = runs.filter { $0.count >= 8 }
        guard runs.contains(where: { $0.phase != 0 }) else { return nil }
        /// How much more the harmony turns on the run's ones than half a
        /// bar (or whatever the difference is) away, over its first 32 bars.
        func borneOut(_ run: (first: Int, phase: Int, count: Int), against other: Int) -> Bool {
            var here: Float = 0, there: Float = 0, n: Float = 0
            for bar in 0..<min(run.count, 32) {
                let i = run.first + 4 * bar
                guard let a = turns(i), let b = turns(i + ((other - run.phase) % 4 + 4) % 4) else { continue }
                here += a
                there += b
                n += 1
            }
            return n >= 6 && here > 1.15 * there
        }
        // The grid's own count holds until a run on another beat is borne
        // out; from there that run's, until the next that is.
        var changes: [(from: Int, phase: Int)] = []
        var current = 0
        for run in runs where run.phase != current {
            if borneOut(run, against: current) {
                changes.append((run.first, run.phase))
                current = run.phase
            }
        }
        guard !changes.isEmpty else { return nil }
        var bars: [Double] = []
        var i = 0, next = 0
        let last = Int((duration - grid.firstDownbeat) / beat) + 4
        while i <= last {
            bars.append(grid.firstDownbeat + Double(i) * beat)
            if next < changes.count, changes[next].from - i <= 5 {
                // The odd bar: two beats (or three, or five) up to the
                // first one of the new count.
                i = max(i + 1, changes[next].from)
                next += 1
            } else {
                i += 4
            }
        }
        return bars
    }

    /// The downbeat of every bar of a song whose beats, as a trained
    /// tracker hears them, don't stay on its constant grid (a drummer's
    /// tempo breathes; a sequencer's doesn't); nil for a song that does.
    ///
    /// Not steady means both that the tracked beats lie well off the grid
    /// much of the time and that the tempo they keep really changes
    /// through the song, a little at a time (measured sixteen beats at a
    /// time: a drummer's moves a few percent). A tracker that hears
    /// another pulse for some bars gives the first without the second (its
    /// beats are off the grid there, at the same tempo), and one that
    /// counts in double time is no further off the grid's eighths. Where
    /// the tracked tempo jumps about by more than a drummer's would, the
    /// tracker is the one that's lost, and its beats aren't bars to go by.
    /// - Parameter attacks: the drums' hits (`BeatAlign.attacks`), which
    ///   each tracked beat is moved onto (the tracker answers in 20 ms
    ///   frames).
    static func downbeats(grid: BeatGrid, heard: BeatTracker.Beats, duration: Double, attacks: [Float]?) -> [Double]? {
        let beat = grid.beatSeconds
        guard heard.beats.count >= 64 else { return nil }
        func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
        let gaps = zip(heard.beats.dropFirst(), heard.beats).map { $0 - $1 }
        let pulse = median(gaps)
        // (Against the grid's eighths where the tracker counts those.)
        let step = beat / max(1, (beat / pulse).rounded())
        let off = heard.beats.map { t in t - (grid.firstDownbeat + ((t - grid.firstDownbeat) / step).rounded() * step) }
        let middle = median(off)
        let spread = off.map { abs($0 - middle) }.sorted()[off.count * 9 / 10]
        guard spread > 0.06 else { return nil }
        // The tempo over every sixteen beats tracked without a gap.
        var tempos: [Double] = []
        for i in stride(from: 0, to: gaps.count - 15, by: 8) where gaps[i..<(i + 16)].allSatisfy({ abs($0 - pulse) < 0.3 * pulse }) {
            tempos.append(gaps[i..<(i + 16)].reduce(0, +) / 16)
        }
        guard tempos.count >= 4 else { return nil }
        tempos.sort()
        let range = (tempos[tempos.count - 1 - tempos.count / 20] - tempos[tempos.count / 20]) / pulse
        // (And only a song tracked on the beat: one counted in double time
        // has no bars to read off the tracked beats.)
        guard range > 0.015, abs(pulse - beat) < 0.1 * beat else { return nil }
        // A tempo that moves by more than a drummer's: the song changes
        // tempo, or the tracker loses it. Either way the grid isn't to be
        // beat-matched on (Ski Aggu's Geld drifted 50 ms against its
        // partner over eight bars), but nor are the tracker's beats bars
        // to go by: the grid's bars, bridged in and out.
        if range >= 0.08 {
            let count = Int((duration - grid.firstDownbeat) / grid.barSeconds) + 2
            return (0..<count).map { grid.firstDownbeat + Double($0) * grid.barSeconds }
        }

        // Every beat of the song: the tracked ones, each on the drum hit
        // nearest it, and where the tracker heard none (a break), as many
        // as fit at the tempo around.
        let perSecond = AudioIO.sampleRate / Double(BeatAlign.onsetHop)
        func onHit(_ t: Double) -> Double {
            guard let attacks else { return t }
            let centre = Int(t * perSecond), reach = Int(0.03 * perSecond)
            guard centre - reach >= 0, centre + reach < attacks.count else { return t }
            let k = ((centre - reach)...(centre + reach)).max { attacks[$0] < attacks[$1] }!
            return attacks[k] > 0 ? Double(k) / perSecond : t
        }
        var beats: [Double] = []
        for t in heard.beats.map(onHit) {
            if let last = beats.last {
                let missing = Int(((t - last) / beat).rounded()) - 1
                if missing > 0 { for k in 1...missing { beats.append(last + (t - last) * Double(k) / Double(missing + 1)) } }
                guard t - last > 0.5 * beat else { continue }
            }
            beats.append(t)
        }
        // Which of them are the ones: where most of the tracker's downbeats fall.
        var votes = [Int](repeating: 0, count: 4)
        for d in heard.downbeats {
            if let i = beats.indices.min(by: { abs(beats[$0] - d) < abs(beats[$1] - d) }), abs(beats[i] - d) < 0.5 * beat {
                votes[i % 4] += 1
            }
        }
        let phase = votes.indices.max { votes[$0] < votes[$1] } ?? 0
        var bars = stride(from: phase, to: beats.count, by: 4).map { beats[$0] }
        guard bars.count >= 8 else { return nil }
        // To both ends of the file, at the tempo of the first and last bars.
        let first = bars[1] - bars[0], last = bars[bars.count - 1] - bars[bars.count - 2]
        while bars[0] - first >= 0 { bars.insert(bars[0] - first, at: 0) }
        while bars[bars.count - 1] + last <= duration + last { bars.append(bars[bars.count - 1] + last) }
        return bars
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
///
/// Onset energy says where the hits are, to the millisecond, but not always
/// which pulse through them is the beat. Where a trained beat tracker
/// (`BeatTracker`) hears one steady pulse, that settles the metre: which
/// tempo, on or off the kicks, which beat is the one. The grid is still
/// fitted to the hits here.
enum TempoEstimator {
    static let hop = 441                  // 10 ms at 44.1 kHz
    static let frameSize = 1024
    private static let minBPM = 70.0
    private static let maxBPM = 180.0

    /// - Parameter layers: mono stems (drums, bass, melody) whose entries and
    ///   exits mark bar starts; see `downbeatPhase`.
    /// - Parameter heard: the beats and downbeats a trained tracker hears
    ///   in the whole mix, if there is one; see `pulse`.
    static func estimate(rhythm: [Float], harmony: [Float]?, layers: [[Float]] = [], heard: BeatTracker.Beats? = nil,
                         sampleRate: Double) -> BeatGrid {
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
        //
        // Off-beat hats can hide the difference, though: a four-on-the-floor
        // track read at 2:3 (Missing's 123 BPM as 82) puts every other beat
        // on a hat and scores almost as well. Its kicks give it away — on
        // the true grid every beat has one — so a clearly better kick fit
        // settles a close call.
        let lowOnset = detrended(lowFlux, window: Int(fps / 2))
        func kickScore(_ p: Double) -> Double {
            let (lp, lph) = combSearch(lowOnset, periods: stride(from: p - 0.004, through: p + 0.004, by: 0.002),
                                       phaseStep: 0.1, phaseRange: nil)
            return combScore(lowOnset, period: lp, phase: lph)
        }
        let score = combScore(onset, period: period, phase: phase)
        let kicks = kickScore(period)
        var bestAlternative: (period: Double, phase: Double, score: Double)?
        for ratio in [4.0 / 3, 3.0 / 4, 3.0 / 2, 2.0 / 3] {
            let candidate = period * ratio
            let bpm = 60 * fps / candidate
            guard bpm >= minBPM / 2, bpm <= maxBPM else { continue }
            let (p, ph) = refine(onset, around: candidate)
            let sc = combScore(onset, period: p, phase: ph)
            let better = sc > 1.25 * score || (sc > score && kickScore(p) > 1.4 * kicks)
            if better, sc > (bestAlternative?.score ?? 0) { bestAlternative = (p, ph, sc) }
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

        // Which of the pulses that fit the hits is the beat, onsets can't
        // always say: a dancehall kick pattern repeats every three
        // sixteenths, and the comb then finds 4:5 or 4:3 of the tempo
        // (117 BPM read as 93.6) on a grid no other song's beat can sit
        // on. Where the tracker hears one steady pulse, the tempo is that
        // one (an octave up or down where it lies outside the range), fitted
        // to the hits as before.
        let pulse = heard.flatMap { Self.pulse($0.beats) }
        if let pulse {
            var target = pulse * fps
            while 60 * fps / target < minBPM { target /= 2 }
            while 60 * fps / target > maxBPM { target *= 2 }
            if abs(log2(period / target)) > log2(1.03) {
                (period, phase) = refine(onset, around: target)
            }
        }
        // And where in the beat: the tracker's beats all sit at one offset
        // from a grid of their own tempo (also where it skips every other
        // beat here and there, which is no steady pulse but still says
        // where the beats are). Off the grid by more than a fifth of a
        // beat, the grid is on the wrong hits (the claps between the kicks,
        // a syncopated 808): it moves to the hits nearest the tracker's
        // beats, unless there is next to nothing there to sit on (then the
        // tracker is the one that's off).
        var beatsHeard = false
        if let heard, heard.beats.count >= 32 {
            // (A tracker hearing twice the grid's tempo has every other
            // beat between the grid's: compared half a beat at a time.)
            let unit = pulse.map { $0 * fps < 0.75 * period } ?? false ? period / 2 : period
            var x = 0.0, y = 0.0
            for t in heard.beats {
                let angle = 2 * Double.pi * (t * fps - phase) / unit
                x += cos(angle)
                y += sin(angle)
            }
            let agreement = (x * x + y * y).squareRoot() / Double(heard.beats.count)
            if agreement > 0.7 {
                beatsHeard = true
                let offset = atan2(y, x) / (2 * .pi) * unit
                if abs(offset) > 0.2 * unit {
                    var centre = (phase + offset).truncatingRemainder(dividingBy: period)
                    if centre < 0.12 * period { centre += period }
                    let (_, moved) = combSearch(onset, periods: stride(from: period, through: period, by: 1), phaseStep: 0.02,
                                                phaseRange: (centre - 0.12 * period)...(centre + 0.12 * period))
                    if combScore(onset, period: period, phase: moved) >= 0.5 * combScore(onset, period: period, phase: phase) {
                        phase = moved
                    } else {
                        beatsHeard = false
                    }
                }
            }
        }

        // Off-beat hats and shakers are broadband, so in overall flux they
        // can out-score the kick and pull the grid half a beat late. Beats
        // are where the low end hits. (Not where the tracker has said
        // which hits the beat is on: a syncopated bass drum hits hardest
        // off it.)
        if !beatsHeard,
           combScore(lowOnset, period: period, phase: phase + period / 2) > combScore(lowOnset, period: period, phase: phase) {
            phase += period / 2
        }

        let beatPhase = downbeatPhase(period: period, phase: phase, lowFlux: lowOnset,
                                      harmony: harmony, layers: layers, heard: beatsHeard ? heard?.downbeats : nil,
                                      sampleRate: sampleRate)
        var first = (phase + Double(beatPhase) * period) / fps
        // Put the grid where the kicks actually peak. Every track is then
        // placed by the same yardstick, so two layered tracks line up kick
        // on kick instead of being off by whatever each one's broadband
        // onsets happened to bias its grid.
        first += kickOffset(lowFlux, bpm: 60 * fps / period, first: first, fps: fps)
        let bar = 4 * period / fps
        while first >= bar { first -= bar }
        while first < 0 { first += bar }
        return BeatGrid(bpm: 60 * fps / period, firstDownbeat: first)
    }

    /// Seconds per beat as a tracker hears it, if what it hears is one
    /// steady pulse: three quarters of its beats follow the last at the
    /// same distance (to its 20 ms frames). nil where it loses the beat or
    /// changes its mind along the way; onsets then decide alone.
    static func pulse(_ beats: [Double]) -> Double? {
        guard beats.count >= 32 else { return nil }
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }
        let median = gaps.sorted()[gaps.count / 2]
        let steady = gaps.filter { abs($0 - median) <= max(0.021, 0.08 * median) }
        guard 4 * steady.count >= 3 * gaps.count else { return nil }
        return steady.reduce(0, +) / Double(steady.count)
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

    /// Median distance from the grid's beats to the low-band onset peaks
    /// near them (sub-frame, by parabolic interpolation).
    private static func kickOffset(_ low: [Float], bpm: Double, first: Double, fps: Double) -> Double {
        guard low.count > 2, let peak = low.max(), peak > 0 else { return 0 }
        let beat = 60 / bpm
        var offsets: [Double] = []
        for i in 1..<(low.count - 1) where low[i] > 0.3 * peak && low[i] >= low[i - 1] && low[i] > low[i + 1] {
            let a = low[i - 1], b = low[i], c = low[i + 1]
            let denom = a - 2 * b + c
            let shift = denom != 0 ? Double(0.5 * (a - c) / denom) : 0
            let t = (Double(i) + max(-0.5, min(0.5, shift))) / fps
            let d = t - (first + ((t - first) / beat).rounded() * beat)
            if abs(d) < 0.04 { offsets.append(d) }
        }
        guard offsets.count >= 16 else { return 0 }
        return offsets.sorted()[offsets.count / 2]
    }

    // MARK: - Downbeat

    /// Which beat (of four, from the first) is the downbeat.
    ///
    /// Three cues vote: where harmony changes, where the low end hits
    /// hardest, and — strongest by far in produced music — where parts come
    /// and go. Drums dropping out, the bass arriving, a new synth: arrangement
    /// changes land on the one. Chord changes alone are ambiguous in music
    /// that changes chord every two bars or rides one chord, and in rap the
    /// kick hits beats 1 and 3 equally.
    ///
    /// A trained tracker's downbeats, where there is one, outweigh all
    /// three: it has learnt what the one sounds like from annotated music.
    /// It decides half a minute at a time and can flip between the one and
    /// the three from one stretch to the next, so the song's grid takes the
    /// beat most of its downbeats fall on, and the cues above break a tie.
    private static func downbeatPhase(period: Double, phase: Double, lowFlux: [Float], harmony: [Float]?,
                                      layers: [[Float]], heard: [Double]? = nil, sampleRate: Double) -> Int {
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
        var votes = (0..<4).map { Double(scores[$0] / max(1, counts[$0])) }
        let total = votes.reduce(0, +)
        if total > 0 { votes = votes.map { $0 / total } }

        let entries = entryVotes(layers, beatSeconds: beatFrames.map { $0 / fps }, sampleRate: sampleRate)
        if let entries { for p in 0..<4 { votes[p] += 2 * entries[p] } }
        if let heard {
            var counts = [Double](repeating: 0, count: 4)
            for t in heard {
                let k = ((t * fps - phase) / period).rounded()
                guard abs(t * fps - (phase + k * period)) < 0.2 * period else { continue }
                counts[((Int(k) % 4) + 4) % 4] += 1
            }
            let total = counts.reduce(0, +)
            if total >= 8 { for p in 0..<4 { votes[p] += 3 * counts[p] / total } }
        }
        return votes.indices.max(by: { votes[$0] < votes[$1] }) ?? 0
    }

    /// Share of arrangement changes on each beat phase, or nil when a track
    /// has too few to go on. A change is a stem's level jumping by more than
    /// 6 dB from one beat to the next and staying there for the next bar.
    private static func entryVotes(_ layers: [[Float]], beatSeconds: [Double], sampleRate: Double) -> [Double]? {
        guard !layers.isEmpty, beatSeconds.count > 16 else { return nil }
        let levels = layers.map { x in
            beatSeconds.indices.map { i -> Float in
                let a = Int(beatSeconds[i] * sampleRate)
                let b = i + 1 < beatSeconds.count ? Int(beatSeconds[i + 1] * sampleRate) : a + Int(sampleRate / 2)
                let lo = max(0, a), hi = min(x.count, b)
                guard hi > lo else { return -90 }
                var ms: Float = 0
                vDSP_measqv(x.withUnsafeBufferPointer { $0.baseAddress! + lo }, 1, &ms, vDSP_Length(hi - lo))
                return 10 * log10(ms + 1e-9)
            }
        }
        var votes = [Double](repeating: 0, count: 4)
        let n = beatSeconds.count
        for i in 4..<(n - 4) {
            for level in levels {
                let step = level[i] - level[i - 1]
                let after = level[i..<(i + 4)].reduce(0, +) / 4, before = level[(i - 4)..<i].reduce(0, +) / 4
                let persist = after - before
                if abs(step) > 6 && abs(persist) > 6 && (step > 0) == (persist > 0) {
                    votes[i % 4] += Double(min(abs(step), abs(persist)))
                }
            }
        }
        let total = votes.reduce(0, +)
        // A handful of changes is enough; fewer than ~6 strong ones is noise.
        guard total > 60 else { return nil }
        return votes.map { $0 / total }
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
