import XCTest
@testable import PassableIos

final class PassableMixTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PassableMixTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Three songs: A 0–100, B takes over at 90, C at 190; blends of 20 s.
    private func manifest() -> PassableMix.Manifest {
        PassableMix.Manifest(
            title: "Friday",
            duration: 300,
            audio: .init(size: 0),
            songs: [
                .init(index: 0, title: "A", artist: "X", start: 0, handover: 0, solo: 0, end: 100),
                .init(index: 1, title: "B", artist: nil, start: 80, handover: 90, solo: 100, end: 200, bpm: 124, key: "8A"),
                .init(index: 2, title: "C", artist: nil, start: 180, handover: 190, solo: 200, end: 300),
            ],
            transitions: [
                .init(from: 0, to: 1, begins: 80, handover: 90, end: 100, style: "Drop Swap"),
                .init(from: 1, to: 2, begins: 180, handover: 190, end: 200, style: "Long Blend", notes: ["mashup"]),
            ])
    }

    // MARK: The file

    func testRoundTripKeepsManifestAndAudioByteForByte() throws {
        let audio = root.appendingPathComponent("in.m4a")
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })   // spans several copy blocks
        try bytes.write(to: audio)
        let file = root.appendingPathComponent("Friday.passablemix")
        let original = manifest()
        try PassableMix.write(original, audio: audio, to: file)

        let read = try PassableMix.readManifest(from: file)
        XCTAssertEqual(read.id, original.id)
        XCTAssertEqual(read.songs, original.songs)
        XCTAssertEqual(read.transitions, original.transitions)
        XCTAssertEqual(read.audio.size, bytes.count)

        let out = root.appendingPathComponent("out.m4a")
        var last = 0.0
        let extracted = try PassableMix.extract(from: file, audioTo: out) { last = $0 }
        XCTAssertEqual(extracted, read)
        XCTAssertEqual(try Data(contentsOf: out), bytes)
        XCTAssertEqual(last, 1, accuracy: 1e-9)
    }

    func testRejectsFilesThatAreNotMixes() throws {
        let junk = root.appendingPathComponent("junk.passablemix")
        try Data("this is not a mix at all".utf8).write(to: junk)
        XCTAssertThrowsError(try PassableMix.readManifest(from: junk)) {
            guard case PassableMix.FileError.notAMix? = $0 as? PassableMix.FileError else { return XCTFail("\($0)") }
        }
    }

    func testTruncatedAudioIsReportedNotAccepted() throws {
        let audio = root.appendingPathComponent("in.m4a")
        try Data(repeating: 1, count: 500_000).write(to: audio)
        let file = root.appendingPathComponent("a.passablemix")
        try PassableMix.write(manifest(), audio: audio, to: file)
        let full = try Data(contentsOf: file)
        let cut = root.appendingPathComponent("cut.passablemix")
        try full.prefix(full.count - 200_000).write(to: cut)
        XCTAssertThrowsError(try PassableMix.extract(from: cut, audioTo: root.appendingPathComponent("o.m4a")))
    }

    func testNewerFormatIsRefusedWithAClearError() throws {
        let audio = root.appendingPathComponent("in.m4a")
        try Data([1, 2, 3]).write(to: audio)
        let file = root.appendingPathComponent("a.passablemix")
        try PassableMix.write(manifest(), audio: audio, to: file)
        var data = try Data(contentsOf: file)
        data[11] = 9   // the version, right after the 11-byte magic
        try data.write(to: file)
        XCTAssertThrowsError(try PassableMix.readManifest(from: file)) {
            guard case PassableMix.FileError.newerVersion(9)? = $0 as? PassableMix.FileError else {
                return XCTFail("\($0)")
            }
        }
    }

    // MARK: The map

    func testWhichSongIsPlaying() {
        let m = manifest()
        XCTAssertEqual(m.songIndex(at: 0), 0)
        XCTAssertEqual(m.songIndex(at: 85), 0, "still song A while B blends in")
        XCTAssertEqual(m.songIndex(at: 90), 1, "B takes over on its handover")
        XCTAssertEqual(m.songIndex(at: 189), 1)
        XCTAssertEqual(m.songIndex(at: 199), 2, "C has taken over by 199")
        XCTAssertEqual(m.songIndex(at: 250), 2)
        XCTAssertEqual(m.songIndex(at: 9_999), 2)
    }

    func testBlendProgress() {
        let m = manifest()
        XCTAssertNil(m.transition(at: 50))
        XCTAssertEqual(m.transition(at: 85)?.style, "Drop Swap")
        XCTAssertEqual(m.transitionProgress(at: 90)!, 0.5, accuracy: 1e-9)
        XCTAssertNil(m.transition(at: 100), "a blend is over at its end")
    }

    func testNextLandsOnTheChosenMoment() {
        let m = manifest()
        XCTAssertEqual(m.nextTarget(from: 10, .handover), 90)
        XCTAssertEqual(m.nextTarget(from: 10, .blend), 80)
        XCTAssertEqual(m.nextTarget(from: 95, .handover), 190, "past B's takeover, next is C")
        XCTAssertNil(m.nextTarget(from: 250, .handover), "nothing after the last song")
    }

    func testNextNeverJumpsBackwards() {
        let m = manifest()
        // Inside the blend into B (it began at 80): landing "on the blend"
        // would be 80, which is behind us. Skip to C instead.
        XCTAssertEqual(m.nextTarget(from: 85, .blend), 180)
    }

    func testPreviousRestartsTheSongThenGoesBack() {
        let m = manifest()
        XCTAssertEqual(m.previousTarget(from: 150, .handover), 90, "deep into B: back to B's start")
        XCTAssertEqual(m.previousTarget(from: 91, .handover), 0, "just after B began: the song before")
        XCTAssertEqual(m.previousTarget(from: 40, .handover), 0)
        XCTAssertEqual(m.previousTarget(from: 2, .handover), 0)
        XCTAssertEqual(m.previousTarget(from: 191, .blend), 180, "11 s into C: restart C, from where it began to blend in")
        XCTAssertEqual(m.previousTarget(from: 182, .blend), 80, "C only just blending in, B still the song: back to B")
    }

    func testSongLength() {
        let m = manifest()
        XCTAssertEqual(m.length(ofSong: 0), 90)
        XCTAssertEqual(m.length(ofSong: 1), 100)
        XCTAssertEqual(m.length(ofSong: 2), 110)
    }

    // MARK: Waveform

    func testWaveformPeaksOfAKnownTone() throws {
        let url = root.appendingPathComponent("tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 {
            for i in 0..<Int(frames) {
                // Quiet for the first second, loud for the second.
                buffer.floatChannelData![c][i] = (i < 44_100 ? 0.1 : 0.8) * sinf(Float(i) * 0.05)
            }
        }
        try file.write(from: buffer)

        let peaks = try Waveform.peaks(of: url)
        XCTAssertEqual(peaks.count, 8, "four per second, two seconds")
        XCTAssertLessThan(peaks[1], 0.15)
        XCTAssertGreaterThan(peaks[6], 0.7)
    }
}

import AVFoundation
