import AVFoundation
import XCTest
@testable import Passable

/// The `.passablemix` Passable writes for the iPhone app.
@MainActor
final class PhoneMixTests: XCTestCase {
    func testArtistAndTitleAreSplitFromADownloadName() {
        XCTAssertEqual(PhoneMix.split("Daft Punk - One More Time").artist, "Daft Punk")
        XCTAssertEqual(PhoneMix.split("Daft Punk - One More Time").title, "One More Time")
        XCTAssertEqual(PhoneMix.split("Artist – Song – Remix").title, "Song – Remix")
        XCTAssertNil(PhoneMix.split("Just A Title").artist)
        XCTAssertEqual(PhoneMix.split("Just A Title").title, "Just A Title")
        XCTAssertNil(PhoneMix.split(" - Odd").artist, "an empty side isn't an artist")
    }

    func testFileNameIsSafe() {
        XCTAssertEqual(PhoneMix.suggestedFileName("Set: 5/10"), "Set- 5-10.passablemix")
    }

    /// A real planned set, rendered and packed: the map must fit the audio.
    func testExportedSetHasAMapThatFitsItsAudio() async throws {
        let a = SeparationTests.fixtures.appendingPathComponent("songA.wav")
        let b = SeparationTests.fixtures.appendingPathComponent("songB.wav")
        guard FileManager.default.fileExists(atPath: a.path), FileManager.default.fileExists(atPath: b.path) else {
            throw XCTSkip("Run tools/convert-demucs/make_fixtures.py")
        }
        let set = SetSession(persists: false)
        set.add([a, b])
        try await wait("the mix") { set.mix != nil && set.buildStatus == nil }
        let mix = try XCTUnwrap(set.mix)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("phonemix-test-\(UUID().uuidString).passablemix")
        defer { try? FileManager.default.removeItem(at: out) }
        set.exportPhoneMix(title: "Test Set", to: .file(out))
        try await wait("the export") { set.exportProgress == nil && FileManager.default.fileExists(atPath: out.path) }

        let manifest = try PassableMix.readManifest(from: out)
        XCTAssertEqual(manifest.title, "Test Set")
        XCTAssertEqual(manifest.songs.count, 2)
        XCTAssertEqual(manifest.transitions.count, 1)
        XCTAssertEqual(manifest.duration, mix.length, accuracy: 1e-6)

        // Times are in order and inside the set.
        let s0 = manifest.songs[0], s1 = manifest.songs[1]
        XCTAssertEqual(s0.start, 0)
        XCTAssertEqual(s0.handover, 0)
        XCTAssertLessThanOrEqual(s1.start, s1.handover)
        XCTAssertLessThanOrEqual(s1.handover, s1.solo)
        XCTAssertLessThanOrEqual(s1.solo, s1.end)
        XCTAssertLessThanOrEqual(s1.end, manifest.duration + 1e-6)
        // And they are the plan's: B takes over where the transition starts.
        let t = mix.transitions[0]
        XCTAssertEqual(s1.handover, t.start, accuracy: 1e-6)
        XCTAssertEqual(s1.start, t.begins, accuracy: 1e-6)
        XCTAssertEqual(manifest.transitions[0].style, t.edit.preset.displayName)
        XCTAssertNotNil(s0.bpm)
        XCTAssertNotNil(s1.key)

        // The audio in the file is the rendered set: its length is the
        // set's plus the three seconds of tail.
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("phonemix-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        _ = try PassableMix.extract(from: out, audioTo: audio)
        let file = try AVAudioFile(forReading: audio)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, manifest.duration + 3, accuracy: 0.3)
        XCTAssertEqual(manifest.audio.size, try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int)

        // What the phone does with the map: the song playing at the end is B.
        XCTAssertEqual(manifest.songIndex(at: manifest.duration - 1), 1)
        XCTAssertEqual(manifest.songIndex(at: 1), 0)
    }

    private func wait(_ what: String, timeout: TimeInterval = 300, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
