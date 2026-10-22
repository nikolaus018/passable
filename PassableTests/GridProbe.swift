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
        // What the builder decides, on B rendered at A's tempo.
        var played = stems[1][.drums]!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if rate != 1 {
            try StemAudio.save(TimeStretcher.process(played.copyStereo(), map: .constant(rate), semitones: 0, percussive: true),
                               directory: dir, name: "b")
            played = try StemAudio.load(directory: dir, name: "b")
        }
        let result = BeatAlign.nudge(a: stems[0][.drums]!, aOffset: 0, b: played, bOffset: bOffset, from: start,
                                     to: start + 16 * ga.barSeconds, split: start + 16 * ga.barSeconds)
        print(String(format: "FLAM builder: nudge %+.0f ms, lock before %.0f%% → layered %@; lags %@", result.nudge * 1000,
                     result.lockBefore * 100, result.grooves ? "yes" : "no",
                     result.lags.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " ")))
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

/// Not a unit test: for the songs listed in $PASSABLE_PARTS, where the
/// vocal's parts end and begin (`AutoPlacement.vocalParts`), bar by bar on
/// the song's four-bar phrases. Skipped unless the variable is set.
final class PartsProbe: XCTestCase {
    func testParts() throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_PARTS"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else { throw XCTSkip("set PASSABLE_PARTS") }
        for path in list.split(separator: "\n").map(String.init) where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            guard let a = StemCache.loadAnalysis(from: try StemCache.directory(for: url)), let s = a.structure else { continue }
            let boundary = s.boundaryStrength(), parts = AutoPlacement.phrases(s, boundary: boundary).edge, phase = s.phrasePhase()
            let voice = s.stemLevel?[StemKind.vocals.rawValue] ?? [], ref = s.vocalReference ?? -30
            print("PARTS \(SongTitle.of(url))  \(String(format: "%.0f", a.grid.bpm)) BPM, phrase phase \(phase), \(parts.count) bars")
            var line = "PARTS   bar:edge(voice dB vs ref) on the phrase grid: "
            for g in stride(from: phase, to: parts.count, by: 4) {
                let v = g < voice.count ? voice[g] - ref : -99
                line += String(format: "%d:%.1f(%+.0f) ", g, parts[g], v)
            }
            print(line)
            let peaks = boundary.indices.filter { g in
                boundary[g] >= 0.35 && (max(0, g - 2)...min(boundary.count - 1, g + 2)).allSatisfy { boundary[$0] <= boundary[g] }
            }
            print("PARTS   boundary peaks (bar:strength): " + peaks.map { String(format: "%d:%.2f", $0, boundary[$0]) }.joined(separator: " "))
            print("PARTS   hooks: " + (0..<parts.count).filter { s.hook($0) >= 0.4 }.map(String.init).joined(separator: " "))
            let strong = parts.indices.filter { parts[$0] >= 0.6 }
            print("PARTS   parts end and begin at: " + strong.map { parts[$0] == 1 ? "[\($0)]" : "\($0)" }.joined(separator: " "))
        }
    }
}

/// Not a unit test: builds the two songs of $PASSABLE_FLAM (the first two
/// lines, in that order) as a set of their own and says whether B's drums
/// were layered under A's, and how far apart the two kits land in what
/// plays. Skipped unless the variable is set.
final class PairBuildProbe: XCTestCase {
    func testPair() async throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_FLAM"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else { throw XCTSkip("set PASSABLE_FLAM") }
        let urls = list.split(separator: "\n").map(String.init).prefix(2).map { URL(fileURLWithPath: $0) }
        let processor = TrackProcessor()
        var tracks: [(url: URL, loaded: TrackProcessor.Loaded)] = []
        for url in urls {
            tracks.append((url, try await withCheckedThrowingContinuation { c in
                processor.load(url, ticket: .init(), progress: { _ in }) { c.resume(with: $0) }
            }))
        }
        // (At the spot on lines three and four, A's bar and B's, if given.)
        let lines = list.split(separator: "\n").map(String.init)
        var edits: [PairKey: TransitionEdit] = [:]
        // (And the blend's length on line five: 16 if not.)
        if lines.count >= 4, let entry = Int(lines[2]), let cue = Int(lines[3]) {
            let bars = lines.count >= 5 ? Int(lines[4]) ?? 16 : 16
            edits[PairKey(from: urls[0], to: urls[1])] = TransitionEdit(entryBar: entry, cueBar: cue, preset: .stemSwap, bars: bars,
                                                                        semitones: 0, lanes: [], byHand: false)
        }
        let mix = try await SetBuilder.build(tracks, edits: edits, processor: processor) { _ in }
        let t = try XCTUnwrap(mix.transitions.first)
        let sr = AudioIO.sampleRate
        func drums(_ track: Int) -> [Float] {
            let renderer = MixRenderer(snapshot: mix.snapshot(masterGain: 1) { i, stem in i == track && stem == .drums })
            renderer.setPositionImmediately(Int(t.start * sr))
            let n = Int((t.end - t.start) * sr)
            var l = [Float](repeating: 0, count: n), r = l
            renderer.render(left: &l, right: &r, count: n)
            return zip(l, r).map { $0 + $1 }
        }
        // The notes that play together through the blend: B's melody on A's
        // melody and bass line, and on A's voice.
        let ta = mix.tracks[0], tb = mix.tracks[1]
        func notes(_ track: SetMix.Track, _ kinds: [StemKind], _ from: Double, _ to: Double) -> [Float]? {
            Harmony.chroma(kinds.compactMap { track.stems[$0] }, offset: track.stemOffset(at: from), from: from, to: to)
        }
        let q = Double(t.edit.bars) / 4 * t.barSeconds
        for (name, from, to) in [("first quarter on", t.start + q, t.end), ("whole blend", t.start, t.end)] {
            let b = notes(tb, [.other], from, to)
            func clash(_ kinds: [StemKind]) -> String {
                guard let a = notes(ta, kinds, from, to), let b else { return "  –  " }
                return String(format: "%+.3f", Harmony.clash(a, b))
            }
            print("PAIR   notes, \(name): B's melody against A's melody+bass \(clash([.other, .bass])), against A's voice \(clash([.vocals])), against all of A \(clash([.other, .bass, .vocals]))")
        }
        print("PAIR   keys \(ta.loaded.analysis.key.displayName) (\(ta.loaded.analysis.key.camelotCode)) → \(tb.loaded.analysis.key.displayName) (\(tb.loaded.analysis.key.camelotCode)); melodies swapped: \(t.melodiesClash); room \(t.room) dB; switch bar \(TransitionBuilder.switchBar(t.edit.preset, bars: t.edit.bars, lowSwap: t.plan.placement.lowSwap)); A's voice out \(t.vocalOut.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-"), B's in \(t.vocalIn.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-")")
        // How loud each part is through the blend, bar by bar (dB).
        func level(_ track: Int, _ stem: StemKind) -> [String] {
            let renderer = MixRenderer(snapshot: mix.snapshot(masterGain: 1) { i, s in i == track && s == stem })
            renderer.setPositionImmediately(Int(t.start * sr))
            return (0..<t.edit.bars).map { _ in
                let n = Int(t.barSeconds * sr)
                var l = [Float](repeating: 0, count: n), r = l
                renderer.render(left: &l, right: &r, count: n)
                var e: Float = 0
                for k in 0..<n { e += l[k] * l[k] + r[k] * r[k] }
                return String(format: "%3.0f", 10 * log10(max(1e-12, e / Float(2 * n))))
            }
        }
        print("PAIR   A drums  " + level(0, .drums).joined(separator: " "))
        print("PAIR   B drums  " + level(1, .drums).joined(separator: " "))
        print("PAIR   A bass   " + level(0, .bass).joined(separator: " "))
        print("PAIR   B bass   " + level(1, .bass).joined(separator: " "))
        print("PAIR   A voice  " + level(0, .vocals).joined(separator: " "))
        print("PAIR   A melody " + level(0, .other).joined(separator: " "))
        print("PAIR   B melody " + level(1, .other).joined(separator: " "))
        print("PAIR   B voice  " + level(1, .vocals).joined(separator: " "))
        let lags = BeatAlign.heardLags(a: drums(0), b: drums(1), window: 2 * t.barSeconds)
        print(String(format: "PAIR %@ → %@: %@ %d bars from A's bar %d, B's bar %d; B's drums layered %@; nudge %+.0f ms; heard flam %.0f ms [%@]",
                     SongTitle.of(urls[0]), SongTitle.of(urls[1]), t.plan.preset.displayName, t.edit.bars, t.edit.entryBar, t.edit.cueBar,
                     t.drumsLayered ? "yes" : "no", t.nudge * 1000, BeatAlign.flam(lags) * 1000,
                     lags.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " ")))
    }
}
