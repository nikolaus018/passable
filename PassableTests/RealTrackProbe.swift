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
