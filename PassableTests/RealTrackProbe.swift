import XCTest
@testable import Passable

/// Not a unit test: analyses the files listed in the file at $PASSABLE_PROBE (one path
/// per line) and prints what it finds. Skipped unless the variable is set.
final class RealTrackProbe: XCTestCase {
    func testProbe() throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_PROBE"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_PROBE")
        }
        let processor = TrackProcessor()
        final class Box: @unchecked Sendable { var items: [(String, TrackAnalysis)] = [] }
        let box = Box()
        for path in list.split(separator: "\n").map(String.init) where !path.isEmpty {
            let done = expectation(description: path)
            let t0 = Date()
            processor.load(URL(fileURLWithPath: path), ticket: .init(), progress: { _ in }) { result in
                switch result {
                case .success(let loaded):
                    let a = loaded.analysis
                    // Grid vs. actual kicks: median offset early/late and spread.
                    let drums = loaded.stems[.drums]!.copyStereo().mono()
                    let low = TempoEstimator.onsetEnvelopes(drums, sampleRate: 44_100).low
                    let fps = 44_100.0 / Double(TempoEstimator.hop)
                    let peak = low.max() ?? 1
                    var early: [Double] = [], late: [Double] = []
                    for i in 1..<(low.count - 1) where low[i] > 0.3 * peak && low[i] >= low[i - 1] && low[i] > low[i + 1] {
                        let t = Double(i) / fps
                        let k = ((t - a.grid.firstDownbeat) / a.grid.beatSeconds).rounded()
                        let d = t - a.grid.beat(Int(k))
                        guard abs(d) < 0.08 else { continue }
                        if t < a.duration / 3 { early.append(d) } else if t > 2 * a.duration / 3 { late.append(d) }
                    }
                    func med(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.sorted()[x.count / 2] * 1000 }
                    print(String(format: "  GRID kick offset early %.1f ms, late %.1f ms (n=%d/%d)", med(early), med(late), early.count, late.count))
                    if ProcessInfo.processInfo.environment["PASSABLE_PROBE_FRESH"] != nil {
                        let fresh = TrackAnalyzer.analyze(stems: loaded.stems)
                        print(String(format: "  FRESH %6.2f BPM  first %.3f  (cached %.2f)", fresh.grid.bpm, fresh.grid.firstDownbeat, a.grid.bpm))
                    }
                    box.items.append(((path as NSString).lastPathComponent.prefix(28).description, a))
                    if let st = a.structure {
                        print("  STRUCT drums from bar \(st.firstActiveBar(.drums).map { $0 + 1 } ?? -1), vocals bars \(st.firstActiveBar(.vocals).map { $0 + 1 } ?? -1)–\(st.lastActiveBarEnd(.vocals) ?? -1) of \(a.grid.barCount(duration: a.duration))")
                    }
                    print(String(format: "PROBE %6.2f BPM  first %.3f  %@ %@  %.0fs  (%.1fs)  %@", a.grid.bpm, a.grid.firstDownbeat,
                                 a.key.camelotCode, a.key.displayName, a.duration, Date().timeIntervalSince(t0),
                                 (path as NSString).lastPathComponent))
                case .failure(let e): print("PROBE FAIL \(path): \(e)")
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 600)
        }
        let analyses = box.items
        for i in 0..<(analyses.count - 1) {
            let (na, a) = analyses[i], (nb, b) = analyses[i + 1]
            let p = AutoPlacement.place(a: a, b: b, bars: 16, preset: .stemSwap)
            print("PLACE \(na) → \(nb): B bar \(p.cueBar + 1) on A bar \(p.entryBar + 1) [\(p.reason)]")
        }
    }
}


/// Not a unit test: for pairs of the songs listed in $PASSABLE_GROOVE (one
/// path per line), compares the groove lock predicted from the songs' own
/// drum attacks with the one measured on B rendered at A's tempo, at the
/// spot the pair would be placed on. Skipped unless the variable is set.
final class GrooveProbe: XCTestCase {
    func testPrediction() async throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_GROOVE"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_GROOVE")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        let processor = TrackProcessor()
        var loaded: [TrackProcessor.Loaded] = []
        for url in urls {
            loaded.append(try await withCheckedThrowingContinuation { c in
                processor.load(url, ticket: .init(), progress: { _ in }) { c.resume(with: $0) }
            })
        }
        let t0 = Date()
        let attacks = loaded.map { $0.stems[.drums].flatMap(BeatAlign.attacks(of:)) }
        print(String(format: "GROOVE attacks of %d songs: %.2f s", loaded.count, Date().timeIntervalSince(t0)))
        let analyses = loaded.map(\.analysis)
        var t1 = Date()
        _ = SetOrdering.costMatrix(analyses)
        print(String(format: "GROOVE cost matrix, grooves unknown: %.2f s", Date().timeIntervalSince(t1)))
        t1 = Date()
        _ = SetOrdering.costMatrix(analyses, drums: attacks)
        print(String(format: "GROOVE cost matrix, grooves known: %.2f s", Date().timeIntervalSince(t1)))
        var pairs: [(Int, Int)] = []
        for i in loaded.indices {
            for d in [1, 2, 5] { pairs.append((i, (i + d) % loaded.count)); pairs.append(((i + d) % loaded.count, i)) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        final class Box: @unchecked Sendable { var lines: [String] = []; var agree = 0, total = 0, seconds = 0.0; let lock = NSLock() }
        let box = Box()
        let work = pairs, songs = loaded
        DispatchQueue.concurrentPerform(iterations: work.count) { k in
            let (i, j) = work[k]
            let a = songs[i], b = songs[j]
            let plan = PairPlan.make(a: a.analysis, b: b.analysis)
            guard plan.preset != .echoOut, let ea = attacks[i], let eb = attacks[j],
                  let drumsA = a.stems[.drums], let drumsB = b.stems[.drums] else { return }
            let ga = a.analysis.grid, gb = b.analysis.grid
            let start = ga.downbeat(plan.placement.entryBar), end = start + Double(plan.bars) * ga.barSeconds
            let offset = start - gb.scaled(by: plan.rate).downbeat(plan.placement.cueBar)
            let split = start + TransitionBuilder.switchBar(plan.preset, bars: plan.bars, lowSwap: plan.placement.lowSwap) * ga.barSeconds
            let t = Date()
            let predicted = BeatAlign.predicted(a: ea, b: eb, from: start, to: end, split: split, bOffset: offset, rate: plan.rate)
            let took = Date().timeIntervalSince(t)
            var stretched = drumsB
            if plan.rate != 1 {
                let out = TimeStretcher.process(drumsB.copyStereo(), map: .constant(plan.rate), semitones: 0, percussive: true)
                guard (try? StemAudio.save(out, directory: dir, name: "\(k)")) != nil,
                      let stem = try? StemAudio.load(directory: dir, name: "\(k)") else { return }
                stretched = stem
            }
            let actual = BeatAlign.nudge(a: drumsA, aOffset: 0, b: stretched, bOffset: offset, from: start, to: end, split: split)
            let line = String(format: "GROOVE %2d→%2d %@ %2d bars rate %.3f  predicted %@ nudge %+3.0f ms lock %3.0f%%  actual %@ nudge %+3.0f ms lock %3.0f%%%@",
                              i + 1, j + 1, plan.preset.rawValue, plan.bars, plan.rate,
                              predicted.grooves ? "yes" : "no ", predicted.nudge * 1000, predicted.lockBefore * 100,
                              actual.grooves ? "yes" : "no ", actual.nudge * 1000, actual.lockBefore * 100,
                              predicted.grooves == actual.grooves ? "" : "  DIFFER")
            box.lock.lock()
            box.lines.append(line)
            box.total += 1
            box.seconds += took
            if predicted.grooves == actual.grooves { box.agree += 1 }
            box.lock.unlock()
        }
        for line in box.lines.sorted() { print(line) }
        print(String(format: "GROOVE agree %d of %d; a prediction takes %.1f ms", box.agree, box.total, 1000 * box.seconds / Double(max(1, box.total))))
    }
}
