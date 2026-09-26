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

    func testTimeStretchKeepsLengthAndAlignment() throws {
        let sr = 44_100
        var input = StereoBuffer(count: sr * 4)
        // Clicks every 0.5 s.
        for k in 0..<8 {
            for i in 0..<64 {
                let v = Float(sin(Double(i) / 64 * .pi))
                input.left[k * sr / 2 + i] = v
                input.right[k * sr / 2 + i] = v
            }
        }
        let rate = 1.05
        let out = try TimeStretcher.process(input, rate: rate, semitones: 0)
        XCTAssertEqual(Double(out.count), Double(input.count) / rate, accuracy: 2)
        // The 4th click should land at 1.5 s / rate.
        let expected = Int(1.5 * Double(sr) / rate + 32 / rate)
        let window = (expected - 2000)..<(expected + 2000)
        let peak = window.max { abs(out.left[$0]) < abs(out.left[$1]) }!
        XCTAssertEqual(Double(peak - expected) / Double(sr), 0, accuracy: 0.004)
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
