import XCTest
@testable import Passable

/// Not a unit test: separates the songs in $PASSABLE_PRECISION with the
/// bundled model and with the one at $PASSABLE_PRECISION_MODEL (a compiled
/// .mlmodelc), and says how far the stems and everything Passable works out
/// from them (grid, key, structure, lyrics) differ. Skipped unless set.
final class PrecisionLab: XCTestCase {
    func testCompare() throws {
        let env = ProcessInfo.processInfo.environment
        guard let listFile = env["PASSABLE_PRECISION"], let other = env["PASSABLE_PRECISION_MODEL"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_PRECISION and PASSABLE_PRECISION_MODEL")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        func clock() -> Double { ProcessInfo.processInfo.systemUptime }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("precision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let separators = [try StemSeparator(), try StemSeparator(model: URL(fileURLWithPath: other))]
        var worstStem = Double.infinity, worstMix = Double.infinity, differing = 0
        for (index, url) in urls.enumerated() {
            let mix = try AudioIO.loadStereo(url: url)
            var results: [(stems: [StemKind: StemAudio], analysis: TrackAnalysis, lines: Int, time: Double)] = []
            for (s, separator) in separators.enumerated() {
                let t = clock()
                let separated = try separator.separate(mix, progress: { _ in })
                let time = clock() - t
                let dir = scratch.appendingPathComponent("\(index)-\(s)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (kind, buffer) in separated { try StemAudio.save(buffer, directory: dir, name: kind.rawValue) }
                let stems = try StemCache.loadStems(from: dir)
                var analysis = TrackAnalyzer.analyze(stems: stems)
                var lines = -1
                if case .heard(let heard) = Lyrics.listen(vocals: stems[.vocals]!) {
                    lines = heard.lines.count
                    analysis.structure?.setLines(heard.lines, tried: "x", grid: analysis.grid)
                }
                results.append((stems, analysis, lines, time))
            }
            let (a, b) = (results[0], results[1])
            var mixEnergy = 0.0
            for i in 0..<mix.count { mixEnergy += Double(mix.left[i] * mix.left[i] + mix.right[i] * mix.right[i]) }
            var report: [String] = []
            for kind in StemKind.allCases {
                var signal = 0.0, noise = 0.0, finite = true
                for side in [\StemAudio.left, \StemAudio.right] {
                    let x = a.stems[kind]![keyPath: side], y = b.stems[kind]![keyPath: side]
                    for i in 0..<a.stems[kind]!.count {
                        let r = Double(x.pointer[i]), v = Double(y.pointer[i])
                        if !v.isFinite { finite = false }
                        signal += r * r; noise += (v - r) * (v - r)
                    }
                }
                let snr = 10 * log10(signal / max(noise, 1e-30)), vsMix = 10 * log10(mixEnergy / max(noise, 1e-30))
                worstStem = min(worstStem, snr); worstMix = min(worstMix, vsMix)
                report.append(String(format: "%@ %.1f dB (%.1f under the mix)%@", kind.rawValue, snr, vsMix, finite ? "" : " NON-FINITE"))
            }
            print(String(format: "PRECISION %@: separate %.2f s → %.2f s; ", url.lastPathComponent, a.time, b.time)
                  + report.joined(separator: ", "))
            let ga = a.analysis.grid, gb = b.analysis.grid
            var changes: [String] = []
            if ga.bpm != gb.bpm { changes.append(String(format: "bpm %.4f → %.4f", ga.bpm, gb.bpm)) }
            if abs(ga.firstDownbeat - gb.firstDownbeat) > 1e-9 {
                changes.append(String(format: "first downbeat %.4f → %.4f", ga.firstDownbeat, gb.firstDownbeat))
            }
            if ga.downbeats != gb.downbeats {
                let n = min(ga.downbeats?.count ?? 0, gb.downbeats?.count ?? 0)
                let shift = (0..<n).map { abs(ga.downbeats![$0] - gb.downbeats![$0]) }.max() ?? 0
                changes.append(String(format: "downbeats %d → %d (max shift %.4f s)", ga.downbeats?.count ?? 0, gb.downbeats?.count ?? 0, shift))
            }
            if ga.wanders != gb.wanders { changes.append("wanders \(String(describing: ga.wanders)) → \(String(describing: gb.wanders))") }
            if ga.doubtful != gb.doubtful { changes.append("doubtful \(ga.doubtful ?? []) → \(gb.doubtful ?? [])") }
            if a.analysis.structure?.hookStart != b.analysis.structure?.hookStart {
                changes.append("hooks \(a.analysis.structure?.hookStart ?? []) → \(b.analysis.structure?.hookStart ?? [])")
            }
            if a.analysis.key != b.analysis.key { changes.append("key \(a.analysis.key) → \(b.analysis.key)") }
            if a.lines != b.lines { changes.append("lyric lines \(a.lines) → \(b.lines)") }
            if a.analysis.structure != b.analysis.structure {
                let encoder = JSONEncoder()
                let ja = (try? JSONSerialization.jsonObject(with: encoder.encode(a.analysis.structure))) as? [String: Any] ?? [:]
                let jb = (try? JSONSerialization.jsonObject(with: encoder.encode(b.analysis.structure))) as? [String: Any] ?? [:]
                let keys = Set(ja.keys).union(jb.keys).filter {
                    !NSDictionary(dictionary: [$0: ja[$0] ?? NSNull()]).isEqual(to: [$0: jb[$0] ?? NSNull()])
                }
                changes.append("structure fields: " + keys.sorted().joined(separator: " "))
            }
            if !changes.isEmpty { differing += 1 }
            print("PRECISION   analysis: " + (changes.isEmpty ? "identical" : changes.joined(separator: "; ")))
        }
        print(String(format: "PRECISION worst stem %.1f dB, worst error %.1f dB under the mix, %d of %d songs analysed differently",
                     worstStem, worstMix, differing, urls.count))
    }

    /// The analysis of each song in $PASSABLE_BEATS (stems from the cache)
    /// with the bundled beat tracker and with $PASSABLE_BEATS_MODEL.
    func testBeatTrackerModels() throws {
        let env = ProcessInfo.processInfo.environment
        guard let listFile = env["PASSABLE_BEATS"], let other = env["PASSABLE_BEATS_MODEL"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_BEATS and PASSABLE_BEATS_MODEL")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        let trackers = [BeatTracker.shared!, try BeatTracker(model: URL(fileURLWithPath: other))]
        var same = 0, compared = 0
        for url in urls {
            let dir = try StemCache.directory(for: url)
            guard StemCache.hasStems(in: dir) else { continue }
            let stems = try StemCache.loadStems(from: dir)
            let (a, b) = (TrackAnalyzer.analyze(stems: stems, tracker: trackers[0]), TrackAnalyzer.analyze(stems: stems, tracker: trackers[1]))
            compared += 1
            var changes: [String] = []
            let ga = a.grid, gb = b.grid
            if ga.bpm != gb.bpm { changes.append(String(format: "bpm %.4f → %.4f", ga.bpm, gb.bpm)) }
            if ga.firstDownbeat != gb.firstDownbeat { changes.append(String(format: "first downbeat %.4f → %.4f", ga.firstDownbeat, gb.firstDownbeat)) }
            if ga.downbeats != gb.downbeats {
                let n = min(ga.downbeats?.count ?? 0, gb.downbeats?.count ?? 0)
                let shift = (0..<n).map { abs(ga.downbeats![$0] - gb.downbeats![$0]) }.max() ?? 0
                changes.append(String(format: "downbeats %d → %d (max shift %.4f s)", ga.downbeats?.count ?? 0, gb.downbeats?.count ?? 0, shift))
            }
            if ga.wanders != gb.wanders { changes.append("wanders \(String(describing: ga.wanders)) → \(String(describing: gb.wanders))") }
            if ga.doubtful != gb.doubtful { changes.append("doubtful \(ga.doubtful ?? []) → \(gb.doubtful ?? [])") }
            if a.key != b.key { changes.append("key") }
            if a.structure != b.structure { changes.append("structure") }
            if changes.isEmpty { same += 1 }
            print("PRECISION beats \(url.lastPathComponent): " + (changes.isEmpty ? "identical" : changes.joined(separator: "; ")))
        }
        print("PRECISION beats: \(same) of \(compared) songs analysed identically")
    }
}
