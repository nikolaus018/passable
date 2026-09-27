import AVFoundation
import XCTest
@testable import Passable

/// The whole app pipeline, headless: two WAVs in, a rendered transition out.
@MainActor
final class EndToEndTests: XCTestCase {
    private func wait(_ what: String, timeout: TimeInterval = 180, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testTwoSongsToRenderedTransition() async throws {
        let a = SeparationTests.fixtures.appendingPathComponent("songA.wav")
        let b = SeparationTests.fixtures.appendingPathComponent("songB.wav")
        guard FileManager.default.fileExists(atPath: a.path), FileManager.default.fileExists(atPath: b.path) else {
            throw XCTSkip("Run tools/convert-demucs/make_fixtures.py")
        }
        // Start cold so separation really runs.
        for url in [a, b] { try? FileManager.default.removeItem(at: try StemCache.directory(for: url)) }

        let session = Session()
        let start = Date()
        session.load(a, into: .a)
        session.load(b, into: .b)
        try await wait("both decks") {
            session.deckA.status == .ready && session.deckB.status == .ready
        }
        print("Loaded both decks in \(Date().timeIntervalSince(start)) s")
        try await wait("tempo/key matching") { session.matched != nil }
        print("Matched after \(Date().timeIntervalSince(start)) s")

        let gridA = try XCTUnwrap(session.deckA.analysis?.grid)
        let gridB = try XCTUnwrap(session.deckB.analysis?.grid)
        print("A: \(gridA.bpm) BPM first downbeat \(gridA.firstDownbeat) key \(session.deckA.analysis!.key.camelotCode)")
        print("B: \(gridB.bpm) BPM first downbeat \(gridB.firstDownbeat) key \(session.deckB.analysis!.key.camelotCode)")
        print("rate \(session.rate), shift \(session.semitones) st, entry bar \(session.entryBar), offsetB \(session.offsetB)")
        XCTAssertEqual(gridA.bpm, 124, accuracy: 0.1)
        XCTAssertEqual(gridB.bpm, 118, accuracy: 0.1)
        XCTAssertEqual(gridA.firstDownbeat, 0.5, accuracy: 0.02)
        XCTAssertEqual(gridB.firstDownbeat, 0.3, accuracy: 0.02)
        XCTAssertEqual(session.rate, 124.0 / 118.0, accuracy: 0.002)
        // B was written two semitones above A: it keeps its own key, and
        // the panel offers the shift that would let the melodies layer.
        XCTAssertEqual(session.semitones, 0, "a song keeps its own key")
        XCTAssertTrue(session.keyClash?.contains("-2 st") ?? false, session.keyClash ?? "no clash noted")

        // Matched B is as long as its time map says: A's tempo through the
        // blend, then its own.
        let map = session.matched!.plan.map
        let sourceFrames = session.deckB.loaded!.stems[.drums]!.count
        XCTAssertEqual(session.matched!.stems[.drums]!.count, Int(map.output(Double(sourceFrames))), accuracy: 1)
        XCTAssertEqual(map.rate, session.rate, accuracy: 1e-9)
        XCTAssertEqual(map.rampStart / 44_100, session.transitionEnd - session.offsetB, accuracy: 0.001)

        // A preset was applied automatically.
        XCTAssertTrue(session.lanes.contains { !$0[.volume].isEmpty })

        // B's cue bar lands on A's entry bar.
        let bDownbeatOnMaster = session.offsetB + session.matchedGridB!.downbeat(session.cueBar)
        XCTAssertEqual(bDownbeatOnMaster, gridA.downbeat(session.entryBar), accuracy: 1e-6)

        // Render the transition and check it is real, unclipped audio.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("passable-e2e.wav")
        session.export(.full, to: out)
        try await wait("render") { session.exportProgress == nil && FileManager.default.fileExists(atPath: out.path) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let l = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n)
        let peak = l.map(abs).max()!
        XCTAssertGreaterThan(peak, 0.1)
        XCTAssertLessThanOrEqual(peak, 0.97)
        XCTAssertEqual(Double(n) / 44_100, session.lengthSeconds + 3, accuracy: 0.05)
        print("Rendered \(Double(n) / 44_100) s, peak \(peak), total \(Date().timeIntervalSince(start)) s → \(out.path)")
    }
}
