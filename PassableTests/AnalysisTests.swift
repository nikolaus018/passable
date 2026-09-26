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
}
