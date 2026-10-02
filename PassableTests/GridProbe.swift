import XCTest
@testable import Passable

/// Not a unit test: for the songs listed in $PASSABLE_GRIDS (one path per
/// line, already separated), the beat grid as cached, as estimated now, and
/// the beats the tracker hears, written to $PASSABLE_GRIDS_OUT (a folder)
/// for comparison with other trackers. Analyses on disk are left alone.
/// Skipped unless the variable is set.
final class GridProbe: XCTestCase {
    func testGrids() throws {
        let env = ProcessInfo.processInfo.environment
        guard let listFile = env["PASSABLE_GRIDS"], let list = try? String(contentsOfFile: listFile, encoding: .utf8),
              let out = env["PASSABLE_GRIDS_OUT"] else {
            throw XCTSkip("set PASSABLE_GRIDS and PASSABLE_GRIDS_OUT")
        }
        let folder = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        let tracker = try XCTUnwrap(BeatTracker.shared, "BeatThis model isn't in the bundle")
        struct Row: Codable {
            var path: String, cachedBPM: Double, cachedFirst: Double, bpm: Double, first: Double
            var alone: Double, aloneFirst: Double, pulse: Double?, beats: [Double], downbeats: [Double]
            var cachedKey: String, key: String
        }
        final class Box: @unchecked Sendable { var rows: [Row?]; let lock = NSLock(); init(_ n: Int) { rows = .init(repeating: nil, count: n) } }
        let box = Box(urls.count)
        // The model's part first, one song at a time (it's the GPU's), kept
        // between runs: only the estimator changes from one to the next.
        var heard: [BeatTracker.Beats] = []
        var stems: [[StemKind: StemAudio]] = []
        for url in urls {
            let directory = try StemCache.directory(for: url)
            guard StemCache.hasStems(in: directory) else { throw XCTSkip("\(url.lastPathComponent) isn't separated yet") }
            let s = try StemCache.loadStems(from: directory)
            stems.append(s)
            let kept = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".beats.json")
            if let data = try? Data(contentsOf: kept), let b = try? JSONDecoder().decode([[Double]].self, from: data), b.count == 2 {
                heard.append(.init(beats: b[0], downbeats: b[1]))
                continue
            }
            let t0 = Date()
            var mix = [Float](repeating: 0, count: s.values.map(\.count).max() ?? 0)
            for stem in s.values {
                let m = stem.copyStereo().mono()
                for i in m.indices { mix[i] += m[i] }
            }
            let b = try tracker.track(mix)
            heard.append(b)
            try JSONEncoder().encode([b.beats, b.downbeats]).write(to: kept)
            print(String(format: "TRACKED %.1f s  %d beats  %@", Date().timeIntervalSince(t0), b.beats.count, url.lastPathComponent))
        }
        let sr = AudioIO.sampleRate
        let work = urls, allStems = stems, allHeard = heard
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            let s = allStems[i]
            guard let directory = try? StemCache.directory(for: work[i]) else { return }
            let cached = StemCache.loadAnalysis(from: directory)
            let drums = s[.drums].map { $0.copyStereo().mono() } ?? []
            var harmony = [Float](repeating: 0, count: drums.count)
            for kind in [StemKind.bass, .other] {
                guard let m = s[kind]?.copyStereo().mono() else { continue }
                for k in 0..<min(m.count, harmony.count) { harmony[k] += m[k] }
            }
            let layers = [StemKind.drums, .bass, .other].compactMap { s[$0]?.copyStereo().mono() }
            let alone = TempoEstimator.estimate(rhythm: drums, harmony: harmony, layers: layers, sampleRate: sr)
            let grid = TempoEstimator.estimate(rhythm: drums, harmony: harmony, layers: layers, heard: allHeard[i], sampleRate: sr)
            let row = Row(path: work[i].path, cachedBPM: cached?.grid.bpm ?? 0, cachedFirst: cached?.grid.firstDownbeat ?? 0,
                          bpm: grid.bpm, first: grid.firstDownbeat, alone: alone.bpm, aloneFirst: alone.firstDownbeat,
                          pulse: TempoEstimator.pulse(allHeard[i].beats).map { 60 / $0 },
                          beats: allHeard[i].beats, downbeats: allHeard[i].downbeats,
                          cachedKey: cached?.key.camelotCode ?? "-",
                          key: KeyDetector.detect(samples: harmony.map { $0 / 2 }, sampleRate: sr).camelotCode)
            box.lock.lock()
            box.rows[i] = row
            box.lock.unlock()
        }
        for row in box.rows.compactMap({ $0 }) {
            print(String(format: "GRID cached %7.2f @%.3f  alone %7.2f @%.3f  now %7.2f @%.3f  heard %@  key %@ (cached %@)  %@", row.cachedBPM, row.cachedFirst,
                         row.alone, row.aloneFirst, row.bpm, row.first, row.pulse.map { String(format: "%6.2f", $0) } ?? "  –   ",
                         row.key, row.cachedKey, (row.path as NSString).lastPathComponent))
        }
        try JSONEncoder().encode(box.rows.compactMap { $0 }).write(to: folder.appendingPathComponent("grids.json"))
    }
}

/// Not a unit test: for two songs ($PASSABLE_FLAM: two paths, then A's
/// entry bar and B's cue bar, one per line), how well the drum hits of the
/// two land together at every lag, two bars at a time over sixteen: what
/// `BeatAlign` has to go by at that spot. Skipped unless the variable is set.
final class FlamProbe: XCTestCase {
    func testLags() throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_FLAM"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else { throw XCTSkip("set PASSABLE_FLAM") }
        let lines = list.split(separator: "\n").map(String.init)
        let urls = lines.prefix(2).map { URL(fileURLWithPath: $0) }
        let entry = Int(lines[2])!, cue = Int(lines[3])!
        let stems = try urls.map { try StemCache.loadStems(from: StemCache.directory(for: $0)) }
        let analyses = try urls.map { try XCTUnwrap(StemCache.loadAnalysis(from: StemCache.directory(for: $0))) }
        let ea = try XCTUnwrap(BeatAlign.attacks(of: stems[0][.drums]!)), eb = try XCTUnwrap(BeatAlign.attacks(of: stems[1][.drums]!))
        let ga = analyses[0].grid, gb = analyses[1].grid
        let rate = MixMath.rate(a: ga.bpm, b: gb.bpm)
        let start = ga.downbeat(entry), bOffset = start - gb.scaled(by: rate).downbeat(cue)
        let perSecond = AudioIO.sampleRate / Double(BeatAlign.onsetHop)
        print(String(format: "FLAM %@ bar %d (%.2f BPM) ← %@ bar %d (%.2f BPM), rate %.4f", SongTitle.of(urls[0]), entry, ga.bpm,
                     SongTitle.of(urls[1]), cue, gb.bpm, rate))
        for w in 0..<8 {
            let from = start + Double(2 * w) * ga.barSeconds, to = from + 2 * ga.barSeconds
            var scores: [Double] = []
            for lag in -40...40 {
                var sum = 0.0
                for i in Int(from * perSecond)..<Int(to * perSecond) where i >= 0 && i < ea.count && ea[i] > 0 {
                    let j = (Double(i) / perSecond - Double(lag) / 1000 - bOffset) * rate * perSecond
                    let k = Int(j)
                    guard j >= 0, k + 1 < eb.count else { continue }
                    let f = j - Double(k)
                    sum += Double(ea[i]) * (Double(eb[k]) * (1 - f) + Double(eb[k + 1]) * f)
                }
                scores.append(sum)
            }
            let best = scores.max() ?? 0, mean = scores.reduce(0, +) / Double(scores.count)
            let peaks = scores.indices.filter { k in
                k > 0 && k < scores.count - 1 && scores[k] >= scores[k - 1] && scores[k] > scores[k + 1] && scores[k] >= 0.5 * best
            }.map { String(format: "%+d ms %.0f%%", $0 - 40, 100 * scores[$0] / max(best, 1e-12)) }
            print(String(format: "FLAM bars %2d–%2d  best/mean %.2f  peaks: %@  ends: %.0f%% %.0f%%", 2 * w, 2 * w + 2, best / max(mean, 1e-12),
                         peaks.joined(separator: ", "), 100 * scores[0] / max(best, 1e-12), 100 * scores[80] / max(best, 1e-12)))
        }
    }
}
