import XCTest
@testable import Passable

final class AnalysisTests: XCTestCase {
    /// Kick on every beat, hat on the off-beat, a chord change every bar.
    private func clickTrack(bpm: Double, firstDownbeat: Double, seconds: Double) -> (rhythm: [Float], harmony: [Float]) {
        let sr = 44_100.0
        let n = Int(seconds * sr)
        var rhythm = [Float](repeating: 0, count: n)
        var harmony = [Float](repeating: 0, count: n)
        let beat = 60 / bpm
        var k = 0
        while firstDownbeat + Double(k) * beat < seconds {
            let t0 = firstDownbeat + Double(k) * beat
            let i0 = Int(t0 * sr)
            for i in 0..<Int(0.12 * sr) where i0 + i < n {
                let t = Double(i) / sr
                rhythm[i0 + i] += Float(exp(-t / 0.04) * sin(2 * .pi * (55 + 90 * exp(-t / 0.02)) * t))
            }
            let h0 = Int((t0 + beat / 2) * sr)
            var seed: UInt32 = 1
            for i in 0..<Int(0.03 * sr) where h0 + i < n {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                rhythm[h0 + i] += 0.2 * Float(exp(-Double(i) / sr / 0.01)) * (Float(seed >> 8) / Float(1 << 24) - 0.5)
            }
            k += 1
        }
        let chords: [[Double]] = [[220, 261.6, 329.6], [174.6, 220, 261.6], [261.6, 329.6, 392], [196, 246.9, 293.7]]
        let bar = 4 * beat
        for i in 0..<n {
            let t = Double(i) / sr
            guard t >= firstDownbeat else { continue }
            let b = Int((t - firstDownbeat) / bar)
            harmony[i] = Float(chords[b % 4].reduce(0) { $0 + sin(2 * .pi * $1 * t) } * 0.1)
        }
        return (rhythm, harmony)
    }

    func testTempoAndPhase() {
        for (bpm, first) in [(124.0, 0.5), (128.0, 1.2), (95.5, 0.31), (174.0, 0.8)] {
            let track = clickTrack(bpm: bpm, firstDownbeat: first, seconds: 60)
            let grid = TempoEstimator.estimate(rhythm: track.rhythm, harmony: track.harmony, sampleRate: 44_100)
            XCTAssertEqual(grid.bpm, bpm, accuracy: 0.02, "bpm for \(bpm)")
            // Every beat of the last bar must still be on time: this is what
            // tempo precision actually buys.
            let lastBeat = grid.beat(Int((60 - first) / (60 / bpm)) - 1)
            let expected = first + ((lastBeat - first) / (60 / bpm)).rounded() * (60 / bpm)
            XCTAssertEqual(lastBeat, expected, accuracy: 0.008, "drift for \(bpm)")
            XCTAssertEqual(grid.firstDownbeat, first.truncatingRemainder(dividingBy: grid.barSeconds), accuracy: 0.012,
                           "downbeat for \(bpm)")
        }
    }

    func testFixtureSongGrid() throws {
        let song = try SeparationTests.song()
        let mono = song.mono()
        let grid = TempoEstimator.estimate(rhythm: mono, harmony: mono, sampleRate: 44_100)
        XCTAssertEqual(grid.bpm, 124, accuracy: 0.1)
        XCTAssertEqual(grid.firstDownbeat, 0.5, accuracy: 0.015)
    }

    /// Chords played on notes rich in overtones, over hiss: the key is the
    /// one the notes are in, not a fifth up (where every note's third
    /// harmonic lies), and two keys' chroma clash or don't as the keys do.
    func testKeyOfNotesWithOvertones() {
        let sr = 44_100.0
        func song(tonic: Int) -> [Float] {
            // I–vi–IV–V, two seconds a chord.
            let chords = [[0, 4, 7], [9, 0, 4], [5, 9, 0], [7, 11, 2]].map { $0.map { ($0 + tonic) % 12 } }
            var out = [Float](repeating: 0, count: Int(8 * sr))
            var seed: UInt32 = 3
            for i in out.indices {
                let t = Double(i) / sr
                let chord = chords[Int(t / 2) % 4]
                var v = 0.0
                for (k, pitch) in chord.enumerated() {
                    // The root an octave down as well, like a bass line.
                    for octave in k == 0 ? [36, 60] : [60] {
                        let f = 440 * pow(2, Double(octave + pitch - 69) / 12)
                        for h in 1...4 { v += sin(2 * .pi * f * Double(h) * t) / Double(h) }
                    }
                }
                seed = seed &* 1_664_525 &+ 1_013_904_223
                out[i] = Float(0.05 * v) + 0.02 * (Float(seed >> 8) / Float(1 << 24) - 0.5)
            }
            return out
        }
        let songs = Dictionary(uniqueKeysWithValues: [0, 7, 6, 1].map { ($0, song(tonic: $0)) })
        for (tonic, samples) in songs {
            let key = KeyDetector.detect(samples: samples, sampleRate: sr)
            XCTAssertEqual(key.camelotNumber, MusicalKey(tonicPitchClass: tonic, isMajor: true).camelotNumber, "tonic \(tonic)")
        }
        func chroma(_ tonic: Int) -> [Float] {
            KeyDetector.computeChroma(samples: songs[tonic]!, sampleRate: sr, normalised: false).map(Float.init)
        }
        let c = chroma(0)
        XCTAssertLessThanOrEqual(Harmony.clash(c, chroma(7)), Harmony.clashTolerance, "a fifth apart blends")
        XCTAssertGreaterThan(Harmony.clash(c, chroma(1)), Harmony.clashTolerance, "a semitone apart doesn't")
        XCTAssertGreaterThan(Harmony.clash(c, chroma(6)), Harmony.clashTolerance, "nor a tritone")
        // Too short to tell a note from its neighbour: nothing, not noise.
        XCTAssertEqual(KeyDetector.computeChroma(samples: [Float](repeating: 0.1, count: 20_000), sampleRate: sr).reduce(0, +), 0)
    }

    func testHarmonicShift() {
        let aMinor = MusicalKey(tonicPitchClass: 9, isMajor: false)
        let cMajor = MusicalKey(tonicPitchClass: 0, isMajor: true)
        XCTAssertEqual(cMajor.harmonicShift(toMatch: aMinor), 0) // relative keys
        let bMinor = MusicalKey(tonicPitchClass: 11, isMajor: false)
        XCTAssertEqual(bMinor.harmonicShift(toMatch: aMinor), -2)
        // E minor is a fifth from A minor (9A vs 8A): no shift beats +5/-7.
        let eMinor = MusicalKey(tonicPitchClass: 4, isMajor: false)
        XCTAssertEqual(eMinor.harmonicShift(toMatch: aMinor), 0)
        // F♯ minor → A minor: exact is +3, a fifth-neighbour −2; one semitone
        // saved isn't worth moving off the exact key.
        let fsMinor = MusicalKey(tonicPitchClass: 6, isMajor: false)
        XCTAssertEqual(fsMinor.harmonicShift(toMatch: aMinor), 3)
        // G♯ minor → A minor: exact is +1.
        XCTAssertEqual(MusicalKey(tonicPitchClass: 8, isMajor: false).harmonicShift(toMatch: aMinor), 1)
        for tonic in 0..<12 {
            for major in [true, false] {
                let k = MusicalKey(tonicPitchClass: tonic, isMajor: major)
                let shifted = k.transposed(by: k.harmonicShift(toMatch: aMinor))
                let d = abs(shifted.camelotNumber - aMinor.camelotNumber)
                XCTAssertTrue(d == 0 || d == 1 || d == 11, "\(k.camelotCode) → \(shifted.camelotCode)")
            }
        }
    }
}

final class KeyLimitTests: XCTestCase {
    func testShiftLimit() {
        let aSharpMinor = MusicalKey(tonicPitchClass: 10, isMajor: false) // 3A
        // G minor (6A): exact match is +3, but −2 lands on F minor (4A), a
        // Camelot neighbour — the smaller, cleaner shift.
        let gMinor = MusicalKey(tonicPitchClass: 7, isMajor: false)
        XCTAssertEqual(gMinor.harmonicShift(toMatch: aSharpMinor, limit: 2), -2)
        // E major (12B) vs A♯ minor (3A): its relative-major match (C♯) is 3 away.
        XCTAssertNil(MusicalKey(tonicPitchClass: 4, isMajor: true).harmonicShift(toMatch: aSharpMinor, limit: 2))
        let aMinor = MusicalKey(tonicPitchClass: 9, isMajor: false)       // 8A, +1 away
        XCTAssertEqual(aMinor.harmonicShift(toMatch: aSharpMinor, limit: 2), 1)
        // F minor (4A) is already a neighbour of 3A: no shift needed.
        XCTAssertEqual(MusicalKey(tonicPitchClass: 5, isMajor: false).harmonicShift(toMatch: aSharpMinor, limit: 2), 0)
    }

    /// A drummer's song gets its bars one by one; a sequenced one, and one
    /// the tracker merely loses for a few bars, keeps its constant grid.
    func testASongThatWandersGetsItsOwnBars() {
        let grid = BeatGrid(bpm: 120, firstDownbeat: 0.1)
        // Beats that breathe: up to 150 ms off the grid, slowly.
        let wandering: [Double] = (0..<400).map { i in
            let drift: Double = 0.15 * sin(Double(i) / 25)
            return 0.1 + 0.5 * Double(i) + drift
        }
        let heard = BeatTracker.Beats(beats: wandering, downbeats: stride(from: 0, to: 400, by: 4).map { wandering[$0] })
        let bars = try! XCTUnwrap(Steadiness.downbeats(grid: grid, heard: heard, duration: 200.5, attacks: nil))
        XCTAssertEqual(bars[0], wandering[0], accuracy: 1e-9)
        XCTAssertEqual(bars[40], wandering[160], accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(bars.last!, 200.5)
        var own = grid
        own.downbeats = bars
        XCTAssertFalse(own.isSteady)
        XCTAssertEqual(own.downbeat(40), wandering[160], accuracy: 1e-9)
        let halfway: Double = wandering[160] + (wandering[164] - wandering[160]) / 2
        XCTAssertEqual(own.beat(162), halfway, accuracy: 1e-9)
        XCTAssertEqual(own.bars(at: own.time(bars: 17.25)), 17.25, accuracy: 1e-9)
        XCTAssertEqual(own.barCount(duration: 200.5), Int(own.bars(at: 200.5)))
        // On the grid give or take the tracker's frames: steady.
        let steady: [Double] = (0..<400).map { i in
            let jitter: Double = i % 3 == 0 ? 0.015 : -0.01
            return 0.1 + 0.5 * Double(i) + jitter
        }
        XCTAssertNil(Steadiness.downbeats(grid: grid, heard: .init(beats: steady, downbeats: []), duration: 200.5, attacks: nil))
        // Half a beat off for sixteen bars (another pulse heard in a break): still steady.
        let lost: [Double] = (0..<400).map { i in
            let off: Double = (100..<164).contains(i) ? 0.25 : 0
            return 0.1 + 0.5 * Double(i) + off
        }
        XCTAssertNil(Steadiness.downbeats(grid: grid, heard: .init(beats: lost, downbeats: []), duration: 200.5, attacks: nil))
        // Counted in double time, on the grid's eighths: steady.
        let double: [Double] = (0..<800).map { 0.1 + 0.25 * Double($0) }
        XCTAssertNil(Steadiness.downbeats(grid: grid, heard: .init(beats: double, downbeats: []), duration: 200.5, attacks: nil))
        // A tempo that jumps by a sixth is no drummer's: not beat-matched,
        // but its bars stay the grid's.
        let jumping: [Double] = (0..<400).reduce(into: [0.1]) { beats, i in beats.append(beats[i] + ((i / 64) % 2 == 0 ? 0.5 : 0.42)) }
        let kept = try! XCTUnwrap(Steadiness.downbeats(grid: grid, heard: .init(beats: jumping, downbeats: []), duration: 200.5,
                                                       attacks: nil))
        XCTAssertEqual(kept[10], grid.downbeat(10), accuracy: 1e-9)
        XCTAssertTrue(grid.isSteady)
        // Such a song is never beat-matched.
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let a = TrackAnalysis(grid: grid, key: c, duration: 200, structure: nil, version: TrackAnalysis.currentVersion)
        let b = TrackAnalysis(grid: own, key: c, duration: 200, structure: nil, version: TrackAnalysis.currentVersion)
        XCTAssertEqual(MixMath.preset(a, a), .stemSwap)
        XCTAssertEqual(MixMath.preset(a, b), .echoOut)
        XCTAssertEqual(MixMath.preset(b, a), .echoOut)
    }

    /// A steady song with a bar of two beats in it counts its bars from
    /// there as the song does, if the harmony bears the tracker out.
    func testAnOddBarMovesTheOnes() throws {
        let grid = BeatGrid(bpm: 120, firstDownbeat: 0)
        // Ones every four beats for twenty bars, then two beats on.
        let ones: [Int] = (0..<20).map { 4 * $0 } + (0..<20).map { 82 + 4 * $0 }
        let heard = BeatTracker.Beats(beats: (0..<170).map { 0.5 * Double($0) }, downbeats: ones.map { 0.5 * Double($0) })
        func turns(_ i: Int) -> Float? { ones.contains(i) ? 1 : 0.2 }
        let bars = try XCTUnwrap(Steadiness.oddBars(grid: grid, heard: heard, duration: 85, turns: turns))
        XCTAssertTrue(bars.contains(38) && bars.contains(40) && bars.contains(41) && bars.contains(43))
        XCTAssertFalse(bars.contains(42), "the old count runs on")
        var own = grid
        (own.downbeats, own.wanders) = (bars, false)
        XCTAssertTrue(own.isSteady, "its beats are still the grid's")
        XCTAssertEqual(own.beat(83), 41.5)
        XCTAssertEqual(own.downbeat(21), 41)
        XCTAssertTrue(own.isRegular(0..<20))
        XCTAssertFalse(own.isRegular(18..<22))
        // The harmony doesn't say so: the tracker's slip, not the song's.
        XCTAssertNil(Steadiness.oddBars(grid: grid, heard: heard, duration: 85, turns: { _ in 0.5 }))
        // Nor do a few bars counted otherwise.
        let blip: [Int] = (0..<40).map { 4 * $0 + ((10..<14).contains($0) ? 2 : 0) }
        XCTAssertNil(Steadiness.oddBars(grid: grid, heard: .init(beats: heard.beats, downbeats: blip.map { 0.5 * Double($0) }),
                                        duration: 85, turns: { _ in 1 }))
        // Played faster it's still the same song: steady, its odd bar where
        // it was, and what's in doubt in doubt.
        own.doubtful = [10...20]
        let faster = own.scaled(by: 1.04)
        XCTAssertTrue(faster.isSteady)
        XCTAssertEqual(faster.downbeat(21), 41 / 1.04, accuracy: 1e-9)
        XCTAssertEqual(faster.doubtful?.first?.lowerBound ?? 0, 10 / 1.04, accuracy: 1e-9)
    }

    /// A grid whose first downbeat lies before the file (nudged there by
    /// hand): its first bar has nothing to measure, and nothing is read
    /// from before the stems.
    func testABarBeforeTheFileIsMeasuredAsSilence() {
        let sr = AudioIO.sampleRate
        let tone = (0..<Int(20 * sr)).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / sr)) }
        let stem = StemAudio(left: MappedChannel(samples: tone), right: MappedChannel(samples: tone))
        let stems = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, stem) })
        var grid = BeatGrid(bpm: 120, firstDownbeat: 0)
        grid.downbeats = (0..<11).map { -0.5 + 2 * Double($0) }
        let s = TrackStructure.measure(stems: stems, grid: grid)
        XCTAssertEqual(s.loudness.first, -90)
        XCTAssertEqual(s.stemLevel?["vocals"]?.first, -90)
        XCTAssertGreaterThan(s.loudness[1], -20)
        XCTAssertEqual(s.vocalSixteenthLevel?.first, -90)
    }

    /// What ordering remembers a pair's price by is the same for the same
    /// analysis, however its dictionaries happen to be laid out (they're
    /// written in another order every launch).
    func testAPairPriceIsRememberedByTheSameFingerprint() throws {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let s = TrackStructure(activity: ["drums": [1, 0.5], "bass": [0.2, 1], "other": [0.3, 0.4], "vocals": [0, 1]],
                               loudness: [-12, -10])
        let analysis = TrackAnalysis(grid: BeatGrid(bpm: 124, firstDownbeat: 0.3), key: c, duration: 200, structure: s,
                                     version: TrackAnalysis.currentVersion)
        let copy = try JSONDecoder().decode(TrackAnalysis.self, from: JSONEncoder().encode(analysis))
        XCTAssertEqual(PairCosts.fingerprint(analysis), PairCosts.fingerprint(copy))
    }
}
