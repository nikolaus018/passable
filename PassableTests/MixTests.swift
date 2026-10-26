import XCTest
@testable import Passable

final class MixTests: XCTestCase {
    func testEnvelopeShapes() {
        var e = Envelope()
        e.insert(AutomationPoint(time: 1, value: 0, curve: .linear))
        e.insert(AutomationPoint(time: 3, value: 1, curve: .hold))
        e.insert(AutomationPoint(time: 5, value: 0))
        XCTAssertEqual(e.value(at: 0, default: 0.5), 0)       // before first point
        XCTAssertEqual(e.value(at: 2, default: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.value(at: 4.99, default: 0.5), 1)    // hold
        XCTAssertEqual(e.value(at: 6, default: 0.5), 0)       // after last point
        XCTAssertTrue(Envelope().value(at: 1, default: 0.7) == 0.7)

        for shape in CurveShape.allCases where shape != .hold {
            XCTAssertEqual(shape.shape(0), 0, accuracy: 1e-9)
            XCTAssertEqual(shape.shape(1), 1, accuracy: 1e-9)
        }
        XCTAssertLessThan(CurveShape.exponential.shape(0.5), 0.5)
        XCTAssertGreaterThan(CurveShape.logarithmic.shape(0.5), 0.5)
    }

    /// The limiter sees peaks coming: nothing goes over its ceiling, the
    /// gain glides into a peak instead of jumping on it, quiet audio
    /// passes untouched, and the output is the input `lookahead` frames on.
    func testLimiterLooksAhead() {
        var limiter = Limiter(sampleRate: 44_100)
        let n = 8192
        var l = (0..<n).map { Float(0.5 * sin(Double($0) * 0.05)) }
        l[4000] = 3; l[4001] = -2.5
        var r = l
        let input = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            limiter.process(lp.baseAddress!, rp.baseAddress!, count: n)
        } }
        let d = Limiter.lookahead
        XCTAssertLessThanOrEqual(l.map(abs).max()!, 0.9661)
        // Untouched well before the peak.
        for i in d..<3000 { XCTAssertEqual(l[i], input[i - d], accuracy: 1e-6) }
        // No jump in gain: frame to frame it moves by a fraction of the
        // whole reduction (3 → 0.966 is a gain of 0.32), over the look-ahead.
        let gains = (d + 3000..<d + 4100).compactMap { i -> (Int, Float)? in
            abs(input[i - d]) > 0.05 ? (i, l[i] / input[i - d]) : nil
        }
        // (Per frame: frames near a zero crossing are left out.)
        let jumps = zip(gains, gains.dropFirst()).map { abs($0.1 - $1.1) / Float($1.0 - $0.0) }
        XCTAssertLessThan(jumps.max()!, 0.01)
        XCTAssertLessThan(gains.map(\.1).min()!, 0.33)
    }

    func testEnvelopeKeepsPointsSorted() {
        var e = Envelope()
        let a = AutomationPoint(time: 1, value: 0.2)
        e.insert(a)
        e.insert(AutomationPoint(time: 2, value: 0.8))
        e.update(a.id, time: 3, value: 1.4)
        XCTAssertEqual(e.points.map(\.time), [2, 3])
        XCTAssertEqual(e.points.last?.value, 1) // clamped
    }

    /// Unity fader, no EQ: the renderer must pass a stem through untouched
    /// (below the limiter's ceiling), at the right offset.
    func testRendererIsTransparentAndPlacesAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 10_000
        let tone = (0..<n).map { Float(0.5 * sin(Double($0) * 0.05)) }
        try StemAudio.save(StereoBuffer(left: tone, right: tone), directory: dir, name: "x")
        let stem = try StemAudio.load(directory: dir, name: "x")

        let offset = 1_000
        let snapshot = MixSnapshot(
            lanes: [.init(audio: stem, offset: offset, envelopes: Lane(side: .a, stem: .drums).envelopes, audible: true)],
            length: n + offset, delaySeconds: 0.3, masterGain: 1)
        let renderer = MixRenderer(snapshot: snapshot)
        var l = [Float](repeating: 0, count: n + offset), r = l
        renderer.render(left: &l, right: &r, count: n + offset)
        XCTAssertEqual(l[0..<offset].map(abs).max(), 0)
        let error = (0..<n).map { abs(l[offset + $0] - tone[$0]) }.max()!
        XCTAssertLessThan(error, 1e-5)
    }

    func testVolumeAutomationFadesAndMutes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 44_100
        let dc = [Float](repeating: 0.5, count: n)
        try StemAudio.save(StereoBuffer(left: dc, right: dc), directory: dir, name: "x")
        let stem = try StemAudio.load(directory: dir, name: "x")

        var lane = Lane(side: .b, stem: .bass)
        lane[.volume].insert(AutomationPoint(time: 0, value: 1, curve: .linear))
        lane[.volume].insert(AutomationPoint(time: 0.5, value: 0))
        let snapshot = MixSnapshot(lanes: [.init(audio: stem, offset: 0, envelopes: lane.envelopes, audible: true)],
                                   length: n, delaySeconds: 0.3, masterGain: 1)
        let renderer = MixRenderer(snapshot: snapshot)
        var l = [Float](repeating: 0, count: n), r = l
        renderer.render(left: &l, right: &r, count: n)
        XCTAssertEqual(l[11_025], 0.25, accuracy: 0.002) // halfway down the fade
        XCTAssertEqual(l[30_000], 0, accuracy: 1e-6)
    }

    func testPresetsWriteAutomationOnEveryLane() {
        for preset in TransitionPreset.allCases {
            let lanes = TransitionBuilder.build(preset, lanes: Lane.allLanes(), start: 60, barSeconds: 2, bars: preset.defaultBars)
            for lane in lanes {
                XCTAssertFalse(lane[.volume].isEmpty, "\(preset) leaves \(lane.title) volume untouched")
            }
            // B is silent before it enters (a Wash Out lets B's intro rise
            // over the four bars before); A is gone once the transition ends.
            let end = 60 + 2 * Double(max(preset.defaultBars, 1)) + 1
            let before = preset == .echoOut ? 60 - 2 * 4 - 1 : 59.0
            for lane in lanes {
                if lane.side == .b {
                    XCTAssertEqual(lane.value(.volume, at: before), 0, "\(preset) \(lane.title)")
                    XCTAssertEqual(lane.value(.volume, at: end + 30), 1, "\(preset) \(lane.title)")
                } else {
                    XCTAssertEqual(lane.value(.volume, at: end + 30), 0, "\(preset) \(lane.title)")
                }
            }
        }
    }

    /// Clicks every 0.5 s for `seconds`.
    private func clickTrack(seconds: Int) -> StereoBuffer {
        let sr = 44_100
        var input = StereoBuffer(count: sr * seconds)
        for k in 0..<(2 * seconds) {
            for i in 0..<64 {
                let v = Float(sin(Double(i) / 64 * .pi))
                input.left[k * sr / 2 + i] = v
                input.right[k * sr / 2 + i] = v
            }
        }
        return input
    }

    private func peak(in out: StereoBuffer, near expected: Double) -> Double {
        let e = Int(expected)
        let window = max(0, e - 2000)..<min(out.count, e + 2000)
        return Double(window.max { abs(out.left[$0]) < abs(out.left[$1]) }!)
    }

    /// Every click must land exactly where the map says, from the first to
    /// the last: the old AUTimePitch path drifted tens of ms over a track.
    func testTimeStretchIsSampleExact() {
        let input = clickTrack(seconds: 60)
        for (rate, percussive) in [(1.05, true), (0.92, true), (1.05, false), (0.92, false)] {
            let map = TimeMap.constant(rate)
            let out = TimeStretcher.process(input, map: map, semitones: 0, percussive: percussive)
            XCTAssertEqual(Double(out.count), Double(input.count) / rate, accuracy: 1)
            for k in [1, 40, 118] {
                let expected = map.output(Double(k * 22_050 + 32))
                // Copied hits play at their own speed from the detected onset,
                // so their peak may sit a few samples (well under 1 ms) off.
                XCTAssertEqual(peak(in: out, near: expected), expected, accuracy: percussive ? 16 : 90,
                               "rate \(rate) percussive \(percussive) click \(k)")
            }
        }
    }

    func testGlideReturnsToTheUntouchedSource() {
        let sr = 44_100.0
        let input = clickTrack(seconds: 40)
        let map = TimeMap.glide(rate: 1.06, rampStart: 10 * sr, rampLength: 8 * sr)
        XCTAssertEqual(map.source(map.output(123_456.7)), 123_456.7, accuracy: 1e-6)
        XCTAssertEqual(map.slope(at: map.rampEnd + 1), 1)
        let offset = try! XCTUnwrap(map.tailOffset)
        let out = TimeStretcher.process(input, map: map, semitones: 0, percussive: true)
        XCTAssertEqual(out.count, input.count - offset)
        let tail = Int(map.rampEnd) + 4096
        XCTAssertEqual((tail..<out.count).map { abs(out.left[$0] - input.left[$0 + offset]) }.max(), 0)
        // Clicks inside the glide still land where the map puts them.
        for k in stride(from: 20, to: 36, by: 3) {
            let expected = map.output(Double(k * 22_050 + 32))
            XCTAssertEqual(peak(in: out, near: expected), expected, accuracy: 16)
        }
    }

    /// A track that is mixed out of at a tempo between its own and the
    /// next song's: home after its way in, untouched until it sets off,
    /// then gliding to its share and holding it, every hit where the map
    /// says, with no click where the untouched stretch begins or ends.
    func testAWayOutGlidesToTheSharedTempo() {
        let sr = 44_100.0
        let input = clickTrack(seconds: 60)
        for (inRate, outRate, percussive) in [(1.04, 0.963, true), (1.0, 1.038, true), (0.97, 1.03, false)] {
            let entry = inRate == 1 ? TimeMap.constant(1) : TimeMap.glide(rate: inRate, rampStart: 8 * sr, rampLength: 6 * sr)
            let home = entry.output(30 * sr)
            let map = entry.exiting(at: home, length: 2 * 5 * sr / (1 + outRate), rate: outRate)
            XCTAssertTrue(map.hasExit)
            for x in [1_000.0, 20 * sr, 31 * sr, 34.9 * sr, 35.1 * sr, 50 * sr] {
                XCTAssertEqual(map.source(map.output(x)), x, accuracy: 1e-4, "\(inRate) \(outRate) \(x)")
            }
            // The glide plays exactly the five seconds from 30 to 35, then the rate holds.
            XCTAssertEqual(map.output(35 * sr), map.exitEnd, accuracy: 1e-3)
            XCTAssertEqual(map.slope(at: map.exitEnd + 10), outRate)
            XCTAssertEqual(map.slope(at: map.exitStart - 10), 1)
            XCTAssertEqual(map.output(50 * sr) - map.output(40 * sr), 10 * sr / outRate, accuracy: 1e-3)

            let out = TimeStretcher.process(input, map: map, semitones: 0, percussive: percussive)
            XCTAssertEqual(Double(out.count), map.output(Double(input.count)), accuracy: 1)
            // Untouched between the way in and the way out.
            let offset = try! XCTUnwrap(map.tailOffset)
            let from = (map.hasGlide ? Int(map.rampEnd) : 0) + 4096, to = Int(map.exitStart) - 4096
            XCTAssertEqual((from..<to).map { abs(out.left[$0] - input.left[$0 + offset]) }.max(), 0, "\(inRate) \(outRate)")
            // Hits before, inside and after the glide out land where the map puts them.
            for k in [44, 58, 63, 67, 72, 90, 110] {
                let expected = map.output(Double(k * 22_050 + 32))
                XCTAssertEqual(peak(in: out, near: expected), expected, accuracy: percussive ? 16 : 90,
                               "\(inRate) \(outRate) click \(k)")
            }
            // Nothing but the clicks themselves: no step where the stretches join.
            for join in [Int(map.exitStart) - 2048, Int(map.exitStart)] {
                let quiet = (join - 1500)..<(join + 1500)
                let clicks = (0..<120).map { Int(map.output(Double($0 * 22_050))) }
                guard !clicks.contains(where: { quiet.overlaps(($0 - 200)..<($0 + 2500)) }) else { continue }
                XCTAssertLessThan(quiet.map { abs(out.left[$0]) }.max()!, 0.02, "\(inRate) \(outRate) join \(join)")
            }
        }
        // No way out for the same tempo.
        XCTAssertFalse(TimeMap.constant(1).exiting(at: 100, length: 100, rate: 1 + 1e-7).hasExit)
    }

    /// A small stretch is the incoming song's alone; a bigger one the two
    /// share, meeting at a tempo between theirs.
    func testTheTwoSongsShareABigStretch() {
        XCTAssertEqual(MixMath.shared(1.02).a, 1)
        XCTAssertEqual(MixMath.shared(1.02).b, 1.02)
        XCTAssertEqual(MixMath.runUpBars(rate: 1.02), 0)
        for rate in [1.075, 0.93, 1.04] {
            let share = MixMath.shared(rate)
            XCTAssertEqual(share.b / share.a, rate, accuracy: 1e-12, "the two play at one tempo")
            XCTAssertEqual(abs(log(share.a)), abs(log(share.b)), accuracy: 1e-12, "each moves as far")
            XCTAssertLessThan(abs(share.b - 1), abs(rate - 1) * 0.52)
            XCTAssertGreaterThan(MixMath.runUpBars(rate: rate), 0)
        }
    }

    /// TiK ToK (120.00017 BPM) into DJ Got Us Fallin' In Love (120.00018):
    /// aligning the glide to whole frames made it 230 bars long, so the
    /// song never settled and the set stayed stuck on that transition.
    func testSameTempoNeverGlidesForever() {
        let sr = 44_100.0
        let rate = MixMath.rate(a: 120.00017410332042, b: 120.00018341650201)
        XCTAssertEqual(rate, 1)
        XCTAssertFalse(TimeMap.glide(rate: 1 - 7.76e-8, rampStart: 60 * sr, rampLength: 2 * sr).hasGlide)
        // Just past "the same tempo", the glide is lengthened by seconds at
        // most, never minutes.
        for r in [1 + 1.01e-5, 1 - 1.01e-5, 1 + 3e-5, 1.003] {
            for start in [0.0, 30, 95.3, 200] {
                let map = TimeMap.glide(rate: r, rampStart: start * sr, rampLength: 2 * sr)
                XCTAssertGreaterThanOrEqual(map.rampLength, 2 * sr - 1)
                XCTAssertLessThan(map.rampLength, 2 * sr + 2 / abs(r - 1) + 1, "rate \(r) start \(start)")
                XCTAssertLessThan(map.rampLength / sr, 7, "rate \(r) start \(start)")
            }
        }
    }

    func testPitchShiftKeepsTimingAndChangesPitch() {
        let sr = 44_100.0
        let n = Int(sr * 6)
        let tone = (0..<n).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / sr)) }
        let out = TimeStretcher.process(StereoBuffer(left: tone, right: tone), map: .constant(1.04),
                                        semitones: 2, percussive: false)
        XCTAssertEqual(Double(out.count), Double(n) / 1.04, accuracy: 1)
        var crossings = 0
        for i in 44_101..<176_400 where (out.left[i - 1] < 0) != (out.left[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / (Double(176_400 - 44_101) / sr)
        XCTAssertEqual(hz, 440 * pow(2, 2.0 / 12), accuracy: 1)
    }
}

@MainActor
final class SessionEditingTests: XCTestCase {
    func testUndoRedoLaneEdits() {
        let session = Session()
        let id = session.lanes[0].id
        session.updateLane(id) { $0[.volume].insert(AutomationPoint(time: 1, value: 0.5)) }
        session.updateLane(id) { $0.isMuted = true }
        XCTAssertTrue(session.canUndo)
        session.undo()
        XCTAssertFalse(session.lanes[0].isMuted)
        XCTAssertEqual(session.lanes[0][.volume].points.count, 1)
        session.undo()
        XCTAssertTrue(session.lanes[0][.volume].isEmpty)
        XCTAssertFalse(session.canUndo)
        session.redo()
        session.redo()
        XCTAssertTrue(session.lanes[0].isMuted)
        XCTAssertFalse(session.canRedo)
    }
}

/// Plugging into a club mixer changes the output device mid-set: playback
/// has to carry on, not go silent.
final class PlaybackRecoveryTests: XCTestCase {
    func testPlaybackSurvivesAnOutputChange() throws {
        let playback = PlaybackEngine()
        try playback.play()
        XCTAssertTrue(playback.engine.isRunning)
        let before = playback.renderer.currentFrame
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(playback.renderer.currentFrame, before, "audio should be flowing")

        // What macOS does on a device change: the engine stops, then posts.
        playback.engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: playback.engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(playback.isRunning)
        XCTAssertTrue(playback.engine.isRunning, "playback restarts on the new output")
        let after = playback.renderer.currentFrame
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(playback.renderer.currentFrame, after, "and the music keeps moving")
        playback.pause()
    }
}
