import AVFoundation
import XCTest
@testable import Passable

final class PassableFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PassableFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A 16-bit WAV of noise, so lossless coding has something to lose.
    private func makeWAV(_ name: String, seconds: Double, seed: UInt64) throws -> URL {
        let url = root.appendingPathComponent("source/\(name).wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        var state = seed
        for c in 0..<2 {
            for i in 0..<n {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                buffer.floatChannelData![c][i] = Float(Int16(truncatingIfNeeded: state >> 48)) / 32768
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testRoundTripIsLosslessAndKeepsEdits() throws {
        let a = try makeWAV("Song A", seconds: 3, seed: 1)
        let b = try makeWAV("Song B", seconds: 2, seed: 2)
        let edit = TransitionEdit(entryBar: 12, cueBar: 4, preset: .longBlend, bars: 32, semitones: -1, lanes: [])
        let file = root.appendingPathComponent("Test.passable")
        try PassableFile.write(songs: [(a, nil), (b, nil)], transitions: [.init(from: 0, to: 1, edit: edit)],
                               masterVolume: 0.7, to: file) { _ in }

        let library = root.appendingPathComponent("library")
        let opened = try PassableFile.read(file, into: library) { _ in }
        XCTAssertEqual(opened.manifest.songs.map(\.title), ["Song A", "Song B"])
        XCTAssertEqual(opened.manifest.songs.map(\.audioExtension), ["caf", "caf"])
        XCTAssertEqual(opened.manifest.transitions, [.init(from: 0, to: 1, edit: edit)])
        XCTAssertEqual(opened.manifest.masterVolume, 0.7)
        XCTAssertEqual(opened.urls.map(\.lastPathComponent), ["Song A.caf", "Song B.caf"])
        for (source, unpacked) in zip([a, b], opened.urls) {
            let x = try AudioIO.loadStereo(url: source), y = try AudioIO.loadStereo(url: unpacked)
            XCTAssertEqual(x.left, y.left)
            XCTAssertEqual(x.right, y.right)
        }

        // Opening again reuses the unpacked songs instead of copying them.
        let again = try PassableFile.read(file, into: library) { _ in }
        XCTAssertEqual(again.urls, opened.urls)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).filter { !$0.hasPrefix(".") }.count, 2)

        // The original file, where it was exported from, is used as is.
        let fromSource = try PassableFile.read(file, into: a.deletingLastPathComponent()) { _ in }
        XCTAssertEqual(fromSource.urls.map(\.lastPathComponent), ["Song A.wav", "Song B.wav"])
    }

    func testRejectsForeignAndDamagedFiles() throws {
        let foreign = root.appendingPathComponent("foreign.passable")
        try Data("hello".utf8).write(to: foreign)
        XCTAssertThrowsError(try PassableFile.read(foreign, into: root) { _ in })

        let a = try makeWAV("Song A", seconds: 1, seed: 3)
        let file = root.appendingPathComponent("Cut.passable")
        try PassableFile.write(songs: [(a, nil)], transitions: [], masterVolume: 1, to: file) { _ in }
        let data = try Data(contentsOf: file)
        try data.prefix(data.count - 5000).write(to: file)
        XCTAssertThrowsError(try PassableFile.read(file, into: root.appendingPathComponent("out")) { _ in })
    }
}
