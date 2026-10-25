import XCTest
@testable import Passable

/// Checks the Swift half of the beat tracker against PyTorch, and what the
/// tempo estimator makes of the beats it hears.
/// Fixtures come from tools/convert-beats/convert.py.
final class BeatTrackerTests: XCTestCase {
    /// (Or wherever $PASSABLE_BEAT_FIXTURES says: a test host with no
    /// access to the folder the project lives in waits for it for ever.)
    private static let fixtures = ProcessInfo.processInfo.environment["PASSABLE_BEAT_FIXTURES"].map(URL.init(fileURLWithPath:))
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/convert-beats/fixtures")

    private static func floats(_ name: String) throws -> [Float] {
        let url = fixtures.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(name); run tools/convert-beats/convert.py")
        }
        return try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testSpectrogramMatchesTorch() throws {
        let signal = try Self.floats("signal22k.f32")
        let reference = try Self.floats("spect.f32")
        let spect = BeatTracker.spectrogram(signal)
        XCTAssertEqual(spect.count, reference.count)
        let peak = reference.map(abs).max()!
        let error = zip(spect, reference).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(error / peak, 1e-4, "max error \(error) vs peak \(peak)")
    }

    func testLogitsMatchTorch() throws {
        guard let tracker = BeatTracker.shared else { throw XCTSkip("BeatThis model isn't in the app bundle") }
        let logits = try tracker.logits(spectrogram: BeatTracker.spectrogram(try Self.floats("signal22k.f32")))
        // Chunked as the library chunks a song: frame for frame the same,
        // to FP16's precision (a chunk out of place is off by whole units),
        // and the same beats picked from them.
        for (name, mine) in [("beat.f32", logits.beat), ("downbeat.f32", logits.downbeat)] {
            let reference = try Self.floats(name)
            XCTAssertEqual(mine.count, reference.count)
            let error = zip(mine, reference).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(error, 0.1, "\(name): max logit error \(error)")
        }
        XCTAssertEqual(BeatTracker.beats(beat: logits.beat, downbeat: logits.downbeat),
                       BeatTracker.beats(beat: try Self.floats("beat.f32"), downbeat: try Self.floats("downbeat.f32")))
        // The fixture clicks twice a second from 0.09 s on.
        let beats = BeatTracker.beats(beat: logits.beat, downbeat: logits.downbeat).beats
        XCTAssertGreaterThan(beats.count, 50)
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }.sorted()
        XCTAssertEqual(gaps[gaps.count / 2], 0.5, accuracy: 0.011)
    }

    func testPeaksBecomeBeats() {
        var beat = [Float](repeating: -5, count: 200), downbeat = beat
        for f in stride(from: 10, to: 200, by: 25) { beat[f] = 3; beat[f + 1] = 2.5 }
        beat[61] = 4 // stronger than its neighbour: one beat, between the two frames
        downbeat[10] = 2
        downbeat[112] = 1 // two frames off a beat: snaps to it
        let found = BeatTracker.beats(beat: beat, downbeat: downbeat)
        XCTAssertEqual(found.beats.count, 8)
        XCTAssertEqual(found.beats[0], 10.0 / 50, accuracy: 1e-9)
        XCTAssertEqual(found.beats[2], 61.0 / 50, accuracy: 1e-9)
        XCTAssertEqual(found.downbeats, [found.beats[0], found.beats[4]])
    }

    /// A kick on every third sixteenth (as dancehall plays it) under a clap
    /// on two and four: onset energy alone is free to find the kicks'
    /// pulse; with the beats heard, the grid is the song's.
    private func tresillo(bpm: Double, first: Double, seconds: Double) -> [Float] {
        let sr = 44_100.0, beat = 60 / bpm
        var out = [Float](repeating: 0, count: Int(seconds * sr))
        func hit(_ t: Double, low: Bool, gain: Float) {
            let i0 = Int(t * sr)
            var seed: UInt32 = 7
            for i in 0..<Int(0.1 * sr) where i0 + i < out.count && i0 >= 0 {
                let u = Double(i) / sr
                if low {
                    out[i0 + i] += gain * Float(exp(-u / 0.04) * sin(2 * .pi * (55 + 90 * exp(-u / 0.02)) * u))
                } else {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    out[i0 + i] += gain * Float(exp(-u / 0.015)) * (Float(seed >> 8) / Float(1 << 24) - 0.5)
                }
            }
        }
        var bar = 0
        while first + Double(4 * bar + 4) * beat < seconds {
            let t0 = first + Double(4 * bar) * beat
            for step in [0, 3, 6, 8, 11, 14] { hit(t0 + Double(step) * beat / 4, low: true, gain: 1) }
            for b in [1, 3] { hit(t0 + Double(b) * beat, low: false, gain: 0.5) }
            bar += 1
        }
        return out
    }

    func testHeardBeatsSettleTheMetre() {
        let bpm = 117.0, first = 0.4, beat = 60 / bpm
        let rhythm = tresillo(bpm: bpm, first: first, seconds: 60)
        // What a tracker would hear, to its 20 ms frames.
        let count = Int((60 - first) / beat)
        let beats = (0..<count).map { ((first + Double($0) * beat) * 50).rounded() / 50 }
        let heard = BeatTracker.Beats(beats: beats, downbeats: stride(from: 0, to: count, by: 4).map { beats[$0] })
        let grid = TempoEstimator.estimate(rhythm: rhythm, harmony: nil, heard: heard, sampleRate: 44_100)
        XCTAssertEqual(grid.bpm, bpm, accuracy: 0.05)
        // On the hits themselves, not on the tracker's coarse frames.
        XCTAssertEqual(grid.firstDownbeat, first, accuracy: 0.012)
    }

    func testHeardBeatsMoveTheGridOffTheOffbeat() {
        // Half a beat late, and the one on beat three: the tracker's beats
        // and downbeats put the grid back on the song's.
        let bpm = 100.0, first = 0.3, beat = 60 / bpm
        let rhythm = tresillo(bpm: bpm, first: first, seconds: 60)
        let count = Int((60 - first) / beat)
        let beats = (0..<count).map { first + Double($0) * beat }
        let heard = BeatTracker.Beats(beats: beats, downbeats: stride(from: 0, to: count, by: 4).map { beats[$0] })
        let grid = TempoEstimator.estimate(rhythm: rhythm, harmony: nil, heard: heard, sampleRate: 44_100)
        XCTAssertEqual(grid.bpm, bpm, accuracy: 0.05)
        XCTAssertEqual(grid.firstDownbeat, first, accuracy: 0.012)
    }

    func testPulse() {
        let steady = (0..<100).map { Double($0) * 0.5 }
        XCTAssertEqual(TempoEstimator.pulse(steady) ?? 0, 0.5, accuracy: 1e-9)
        // Skipping every other beat half the time is no steady pulse.
        var wavering: [Double] = [], t = 0.0
        for i in 0..<100 { wavering.append(t); t += i % 2 == 0 ? 0.5 : 1.0 }
        XCTAssertNil(TempoEstimator.pulse(wavering))
        XCTAssertNil(TempoEstimator.pulse([0, 0.5, 1]))
    }
}
