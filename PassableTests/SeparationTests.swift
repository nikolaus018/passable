import XCTest
@testable import Passable

/// Checks the Swift half of the Demucs pipeline against PyTorch.
/// Fixtures come from tools/convert-demucs/make_fixtures.py.
final class SeparationTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/convert-demucs/fixtures")

    static func floats(_ name: String) throws -> [Float] {
        let url = fixtures.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(name); run tools/convert-demucs/make_fixtures.py")
        }
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func song() throws -> StereoBuffer {
        StereoBuffer(left: try floats("song.L.f32"), right: try floats("song.R.f32"))
    }

    func testForwardSTFTMatchesTorch() throws {
        let song = try Self.song()
        let segment = 343_980
        let stft = DemucsSTFT(segment: segment)
        let plane = DemucsSTFT.bins * stft.frames
        var spec = [Float](repeating: 0, count: 4 * plane)
        for (c, channel) in [song.left, song.right].enumerated() {
            let seg = Array(channel[0..<segment])
            spec.withUnsafeMutableBufferPointer { s in
                stft.forward(signal: seg, re: s.baseAddress! + 2 * c * plane, im: s.baseAddress! + (2 * c + 1) * plane)
            }
        }
        let reference = try Self.floats("seg.spec.f32")
        XCTAssertEqual(reference.count, spec.count)
        let peak = reference.map(abs).max()!
        let error = zip(spec, reference).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(error / peak, 1e-4, "max error \(error) vs peak \(peak)")
    }

    func testInverseSTFTRoundTrips() throws {
        let song = try Self.song()
        let segment = 343_980
        let stft = DemucsSTFT(segment: segment)
        let plane = DemucsSTFT.bins * stft.frames
        var re = [Float](repeating: 0, count: plane), im = re
        let signal = Array(song.left[0..<segment])
        stft.forward(signal: signal, re: &re, im: &im)
        var out = [Float](repeating: 0, count: segment)
        stft.inverse(re: re, im: im, binStride: stft.frames, frameStride: 1, output: &out, count: segment)
        // Like torch, the first and last ~2.5k samples lack two of their four
        // overlapping frames (HTDemucs pads those frames with zeros), so only
        // the interior reconstructs — and only up to the Nyquist bin HTDemucs
        // drops, which the fixture's noise hats put a little energy into.
        let error = (2560..<(segment - 3072)).map { abs(out[$0] - signal[$0]) }.max()!
        XCTAssertLessThan(error, 5e-3)
    }

    /// Full model through Core ML vs demucs.apply_model in PyTorch.
    func testSeparationMatchesPyTorch() throws {
        let song = try Self.song()
        let separator = try StemSeparator()
        let start = Date()
        let stems = try separator.separate(song, progress: { _ in })
        print("Separated \(Double(song.count) / 44_100) s in \(Date().timeIntervalSince(start)) s")
        for kind in StemKind.allCases {
            for (side, ours) in [("L", stems[kind]!.left), ("R", stems[kind]!.right)] {
                let ref = try Self.floats("ref.\(kind.rawValue).\(side).f32")
                XCTAssertEqual(ref.count, ours.count)
                var signal = 0.0, noise = 0.0
                for i in 0..<ref.count {
                    signal += Double(ref[i] * ref[i])
                    noise += Double((ref[i] - ours[i]) * (ref[i] - ours[i]))
                }
                let snr = 10 * log10(signal / max(noise, 1e-20))
                print("\(kind.rawValue).\(side): SNR vs PyTorch \(String(format: "%.1f", snr)) dB")
                XCTAssertGreaterThan(snr, 40, "\(kind.rawValue).\(side)")
            }
        }
    }
}
