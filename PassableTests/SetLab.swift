import XCTest
@testable import Passable

/// Not a unit test: builds a set from the songs listed in $PASSABLE_SET (one
/// path per line, any order), lets Passable order it, renders it to
/// ~/Music/Passable/Lab/Set.wav and measures every transition and the energy
/// over the whole set. Skipped unless the variable is set.
@MainActor
final class SetLab: XCTestCase {
    func testSet() async throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_SET"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_SET")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { URL(fileURLWithPath: $0) }
        let set = SetSession(persists: false)
        set.add(urls)
        let deadline = Date().addingTimeInterval(3600)
        while set.mix == nil || set.buildStatus != nil {
            if Date() > deadline { XCTFail("timeout"); return }
            if let failed = set.items.first(where: { if case .failed = $0.status { return true } else { return false } }) {
                XCTFail("\(failed.title): \(failed.status)"); return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let mix = try XCTUnwrap(set.mix)
        print("\n==== SET ORDER ====")
        for (i, item) in set.items.enumerated() {
            let a = item.analysis!
            print(String(format: "%2d  %6.2f BPM  %@  energy %.2f  %@", i + 1, a.grid.bpm, a.key.camelotCode,
                         SetOrdering.energy(a), item.title))
            if let s = set.summary(from: i) { print("      ↓ \(s)") }
        }

        let sr = AudioIO.sampleRate
        func levels(from: Double, seconds: Double, step: Double, lowPass: Bool = false,
                    _ include: @escaping (Int, StemKind) -> Bool) -> [Double] {
            let renderer = MixRenderer(snapshot: set.makeSnapshot(including: include))
            renderer.setPositionImmediately(Int(from * sr))
            var lp = Biquad()
            lp.set(.lowPass(frequency: 150, q: 0.707), sampleRate: sr)
            var out: [Double] = []
            var t = 0.0, carry = 0.0
            while t < seconds {
                let exact = step * sr + carry
                let n = Int(exact)
                carry = exact - Double(n)
                var l = [Float](repeating: 0, count: n), r = l
                renderer.render(left: &l, right: &r, count: n)
                if lowPass { lp.process(&l, &r, count: n) }
                var e = 0.0
                for k in 0..<n { e += Double(l[k] * l[k] + r[k] * r[k]) }
                out.append(10 * log10(max(1e-12, e / Double(2 * n))))
                t += step
            }
            return out
        }

        /// Where both decks' drums play, how far apart their hits land (ms,
        /// per two-bar window; full-band onsets, since the kicks never
        /// overlap): anything past ~10 ms is heard as a flam.
        func kickOffsets(_ t: SetMix.Transition, from: Double, bars: Int) -> [Double] {
            func mono(_ track: Int) -> [Float] {
                let renderer = MixRenderer(snapshot: set.makeSnapshot { i, s in i == track && s == .drums })
                renderer.setPositionImmediately(Int(from * sr))
                let n = Int(Double(bars) * t.barSeconds * sr)
                var l = [Float](repeating: 0, count: n), r = l
                renderer.render(left: &l, right: &r, count: n)
                return zip(l, r).map { ($0 + $1) / 2 }
            }
            let a = TempoEstimator.onsetEnvelopes(mono(t.from), sampleRate: sr).all
            let b = TempoEstimator.onsetEnvelopes(mono(t.to), sampleRate: sr).all
            let fps = sr / Double(TempoEstimator.hop)
            let window = Int(2 * t.barSeconds * fps)
            var out: [Double] = []
            var w = 0
            while w + window <= min(a.count, b.count) {
                let ra = Array(a[w..<(w + window)]), rb = Array(b[w..<(w + window)])
                let ea = ra.reduce(0, +), eb = rb.reduce(0, +)
                // Both kicks really there, not one side's bleed.
                if ea > 0, eb > 0, min(ea, eb) / max(ea, eb) > 0.2 {
                    var best = (lag: 0, score: -Float.infinity)
                    for lag in -8...8 {
                        var dot: Float = 0
                        for i in 8..<(window - 8) { dot += ra[i] * rb[i + lag] }
                        if dot > best.score { best = (lag, dot) }
                    }
                    // Sub-frame peak by parabola.
                    func at(_ lag: Int) -> Float {
                        var dot: Float = 0
                        for i in 8..<(window - 8) { dot += ra[i] * rb[i + lag] }
                        return dot
                    }
                    var lag = Double(best.lag)
                    if abs(best.lag) < 8 {
                        let y0 = at(best.lag - 1), y1 = best.score, y2 = at(best.lag + 1)
                        let d = y0 - 2 * y1 + y2
                        if d < 0 { lag += Double(0.5 * (y0 - y2) / d) }
                    }
                    out.append(lag / fps * 1000)
                }
                w += window
            }
            return out
        }

        print("\n==== TRANSITIONS ====")
        var worst: [String] = []
        for t in mix.transitions {
            let bar = t.barSeconds
            let from = t.start - 8 * bar
            let glideEnd = mix.tracks[t.to].offset + mix.tracks[t.to].map.rampEnd / sr
            let until = max(t.end, glideEnd.isFinite ? glideEnd : t.end) + 8 * bar
            let bars = Int(((until - from) / bar).rounded(.up))
            let all = levels(from: from, seconds: Double(bars) * bar, step: bar) { _, _ in true }
            let lowA = levels(from: from, seconds: Double(bars) * bar, step: bar, lowPass: true) { i, _ in i == t.from }
            let lowB = levels(from: from, seconds: Double(bars) * bar, step: bar, lowPass: true) { i, _ in i == t.to }
            let vocA = levels(from: from, seconds: Double(bars) * bar, step: bar) { i, s in i == t.from && s == .vocals }
            let vocB = levels(from: from, seconds: Double(bars) * bar, step: bar) { i, s in i == t.to && s == .vocals }
            let before = all[0..<8].reduce(0, +) / 8
            let after = all[(all.count - 8)...].reduce(0, +) / 8
            let middle = all[8..<(all.count - 8)]
            let dip = middle.isEmpty ? 0 : min(before, after) - middle.min()!
            let bump = middle.isEmpty ? 0 : middle.max()! - max(before, after)
            let lowx2 = (0..<all.count).filter { lowA[$0] > -38 && lowB[$0] > -38 && abs(lowA[$0] - lowB[$0]) < 10 }.count
            let vocx2 = (0..<all.count).filter { vocA[$0] > -40 && vocB[$0] > -40 && abs(vocA[$0] - vocB[$0]) < 12 }.count
            // Echo Out has no overlap to flam in.
            let flams = t.edit.preset == .echoOut ? [] : kickOffsets(t, from: from, bars: bars)
            // Typical, not worst: in some windows the two patterns simply
            // differ and correlate anywhere.
            let flam = flams.isEmpty ? 0 : flams.map(abs).sorted()[flams.count / 2]
            let line = String(format: "%2d→%2d at %@  %@  level %.1f → %.1f dB (%+.1f)  dip %.1f  bump %.1f  lowx2 %d  vocx2 %d  flam %.0f ms [%@] nudge %+.0f ms",
                              t.from + 1, t.to + 1, Theme.time(t.start), t.plan.preset.displayName, before, after,
                              after - before, dip, bump, lowx2, vocx2, flam,
                              flams.map { String(format: "%.0f", $0) }.joined(separator: " "), t.nudge * 1000)
            print(line)
            // A lift is how a set builds; a drop is what empties a floor.
            if after - before < -3 || after - before > 6 || dip > 4 || lowx2 > 2 || vocx2 > 1 || flam > 10 {
                worst.append(line)
                let a = levels(from: from, seconds: Double(bars) * bar, step: bar) { i, _ in i == t.from }
                let b = levels(from: from, seconds: Double(bars) * bar, step: bar) { i, _ in i == t.to }
                let othA = levels(from: from, seconds: Double(bars) * bar, step: bar) { i, s in i == t.from && s == .other }
                let othB = levels(from: from, seconds: Double(bars) * bar, step: bar) { i, s in i == t.to && s == .other }
                print("   bar   mix     A     B | lowA  lowB | vocA  vocB | othA  othB")
                for k in 0..<all.count {
                    print(String(format: "   %3d %5.1f %5.1f %5.1f | %5.1f %5.1f | %5.1f %5.1f | %5.1f %5.1f", k - 8, all[k], a[k], b[k],
                                 lowA[k], lowB[k], vocA[k], vocB[k], othA[k], othB[k]))
                }
                print("   " + (set.summary(from: t.from) ?? ""))
                let pa = t.plan.placement
                let la = mix.tracks[t.from].loaded.analysis.structure!.loudness
                let lb = mix.tracks[t.to].loaded.analysis.structure!.loudness
                print("   A entry bar \(pa.entryBar) analysed loudness e-8…e+24: " + (max(0, pa.entryBar - 8)..<min(la.count, pa.entryBar + 24)).map { String(format: "%.0f", la[$0]) }.joined(separator: " "))
                print("   B cue bar \(pa.cueBar) analysed loudness c-8…c+24: " + (max(0, pa.cueBar - 8)..<min(lb.count, pa.cueBar + 24)).map { String(format: "%.0f", lb[$0]) }.joined(separator: " "))
                let ta = mix.tracks[t.from]
                print(String(format: "   A offset %.2f map rate %.4f rampStart %.1f s rampEnd %.1f s; A downbeat(e) native %.2f → master %.2f (transition start %.2f)",
                             ta.offset, ta.map.rate, ta.map.rampStart / sr, ta.map.rampEnd / sr,
                             ta.loaded.analysis.grid.downbeat(pa.entryBar), ta.master(ta.loaded.analysis.grid.downbeat(pa.entryBar)), t.start))
            }
        }

        // Energy over the whole set, in 4-second windows.
        let curve = levels(from: 0, seconds: mix.length, step: 4) { _, _ in true }
        let sorted = curve.sorted()
        var longestLow = 0, run = 0
        for v in curve { run = v < Double(MixMath.targetLoudness) - 6 ? run + 1 : 0; longestLow = max(longestLow, run) }
        print(String(format: "\n==== ENERGY ==== length %@  median %.1f dB  p10 %.1f dB  p90 %.1f  longest stretch >6 dB under target: %d s",
                     Theme.time(mix.length), sorted[sorted.count / 2], sorted[sorted.count / 10], sorted[sorted.count * 9 / 10],
                     longestLow * 4))
        print("Flagged:\n" + (worst.isEmpty ? "  none" : worst.joined(separator: "\n")))

        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Passable/Lab/Set.wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Exporter.render(snapshot: set.makeSnapshot(), range: 0..<Int(mix.length * sr), tail: 3, to: url) { _ in }
        print("Rendered \(url.path)")
    }
}
