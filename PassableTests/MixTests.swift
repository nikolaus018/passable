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
            // B is silent before it enters; A is gone once the transition ends.
            let end = 60 + 2 * Double(max(preset.defaultBars, 1)) + 1
            for lane in lanes {
                if lane.side == .b {
                    XCTAssertEqual(lane.value(.volume, at: 59), 0, "\(preset) \(lane.title)")
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
