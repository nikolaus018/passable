import Accelerate
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

        // Pacing: how long each song holds the floor, and how long anything
        // plays on its own between two transitions.
        var heard: [Double] = []
        for i in mix.tracks.indices {
            let from = i == 0 ? 0 : mix.transitions[i - 1].start
            let to = i == mix.tracks.count - 1 ? mix.length : mix.transitions[i].end
            heard.append(to - from)
        }
        let solos = zip(mix.transitions, mix.transitions.dropFirst()).map { $1.start - $0.end }
        func median(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.sorted()[x.count / 2] }
        print("\n==== PACING ====")
        print("plays: " + heard.enumerated().map { "\($0.offset + 1) \(Theme.time($0.element))" }.joined(separator: "  "))
        print(String(format: "per song: median %@, longest %@;  alone between transitions: median %@, longest %@;  set %@",
                     Theme.time(median(heard)), Theme.time(heard.max() ?? 0), Theme.time(median(solos)),
                     Theme.time(solos.max() ?? 0), Theme.time(mix.length)))

        let sr = AudioIO.sampleRate
        func levels(from: Double, seconds: Double, step: Double, lowPass: Bool = false, highPass: Bool = false,
                    _ include: @escaping (Int, StemKind) -> Bool) -> [Double] {
            let renderer = MixRenderer(snapshot: set.makeSnapshot(including: include))
            renderer.setPositionImmediately(Int(from * sr))
            var lp = Biquad()
            lp.set(.lowPass(frequency: 150, q: 0.707), sampleRate: sr)
            var hp = Biquad()
            hp.set(.highPass(frequency: 150, q: 0.707), sampleRate: sr)
            var out: [Double] = []
            var t = 0.0, carry = 0.0
            while t < seconds {
                let exact = step * sr + carry
                let n = Int(exact)
                carry = exact - Double(n)
                var l = [Float](repeating: 0, count: n), r = l
                renderer.render(left: &l, right: &r, count: n)
                if lowPass { lp.process(&l, &r, count: n) }
                if highPass { hp.process(&l, &r, count: n) }
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
                // Both kicks really there, not one side's bleed, and at the
                // same time: a window with A's drums in one half and B's in
                // the other (a hard swap) has nothing that could flam.
                let together = zip(ra, rb).reduce(Float(0)) { $0 + min($1.0, $1.1) }
                if ea > 0, eb > 0, min(ea, eb) / max(ea, eb) > 0.2, together / min(ea, eb) > 0.3 {
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
        var payoffCounts: [String: Int] = [:]
        var togetherBars: [Int] = []
        for t in mix.transitions {
            let bar = t.barSeconds
            // A Wash Out happens in the bars before B's downbeat.
            let from = t.start - Double(8 + (t.edit.preset == .echoOut ? min(8, t.edit.bars) : 0)) * bar
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
            // The bar before a drop goes quiet on purpose (roll, bass out,
            // half a beat of silence): not a hole.
            let dropBar = t.dropAt.map { Int((($0 - from) / bar).rounded()) - 1 }
            let middle = all[8..<(all.count - 8)]
            let judged = (8..<(all.count - 8)).filter { $0 != dropBar }.map { all[$0] }
            let dip = judged.isEmpty ? 0 : min(before, after) - judged.min()!
            let bump = middle.isEmpty ? 0 : middle.max()! - max(before, after)
            // A transition, not two songs in a row: bars where both are
            // clearly heard, each within 8 dB of the whole mix above 150 Hz
            // (the kick and bass have one owner by design; what the ear
            // follows is drums, melody and voice).
            let highs = levels(from: from, seconds: Double(bars) * bar, step: bar, highPass: true) { _, _ in true }
            let onlyA = levels(from: from, seconds: Double(bars) * bar, step: bar, highPass: true) { i, _ in i == t.from }
            let onlyB = levels(from: from, seconds: Double(bars) * bar, step: bar, highPass: true) { i, _ in i == t.to }
            let together = (0..<all.count).filter { onlyA[$0] > highs[$0] - 8 && onlyB[$0] > highs[$0] - 8 }.count
            togetherBars.append(together)
            let lowx2 = (0..<all.count).filter { lowA[$0] > -38 && lowB[$0] > -38 && abs(lowA[$0] - lowB[$0]) < 10 }.count
            let vocx2 = (0..<all.count).filter { vocA[$0] > -40 && vocB[$0] > -40 && abs(vocA[$0] - vocB[$0]) < 12 }.count
            // Wash Out never layers the beats.
            let flams = t.edit.preset == .echoOut ? [] : kickOffsets(t, from: from, bars: bars)
            // Typical, not worst: in some windows the two patterns simply
            // differ and correlate anywhere.
            let flam = flams.isEmpty ? 0 : flams.map(abs).sorted()[flams.count / 2]
            // Phrasing, heard on the vocals as they play: was A's still
            // sounding right where it was taken out, B's right where it was
            // let in (a line cut in two)?
            var phrasing = ""
            if t.edit.preset != .echoOut, !t.isEdited {
                func sounding(_ track: Int, at master: Double) -> Bool {
                    let tr = mix.tracks[track]
                    guard let stem = tr.stems[.vocals], let ref = VocalPhrasing.reference(tr.loaded.analysis.structure)
                    else { return false }
                    let i = Int((master - tr.stemOffset(at: master)) * sr), n = Int(0.12 * sr)
                    guard i - n >= 0, i + n <= stem.count else { return false }
                    func db(_ from: Int) -> Float {
                        var l: Float = 0, r: Float = 0
                        vDSP_measqv(stem.left.pointer + from, 1, &l, vDSP_Length(n))
                        vDSP_measqv(stem.right.pointer + from, 1, &r, vDSP_Length(n))
                        return 10 * log10(max((l + r) / 2, 1e-9))
                    }
                    return db(i - n) > ref - 12 && db(i) > ref - 12
                }
                let n = Double(t.edit.bars), p = t.plan.placement
                let gridIn = t.start + min(n, max(n / 2, Double(p.vocalHandoff))) * t.barSeconds
                let vin = t.vocalIn ?? gridIn
                let out = t.vocalOut ?? t.start + min(n, max(n / 2, Double(min(p.vocalHandoff, p.lowSwap ?? t.edit.bars)))) * t.barSeconds
                // A blended out or B blended in on purpose isn't a cut; B
                // opening on a word's attack is sounding by design.
                if !t.vocalOutBlend, sounding(t.from, at: out) { phrasing += " A-CUT" }
                if t.vocalInKind == "grid", sounding(t.to, at: vin) { phrasing += " B-MIDLINE" }
            }
            if together < 6 { phrasing += " STRUNG-TOGETHER" }
            let line = String(format: "%2d→%2d at %@  %@  together %d bars  level %.1f → %.1f dB (%+.1f)  dip %.1f  bump %.1f  lowx2 %d  vocx2 %d  flam %.0f ms [%@] nudge %+.0f ms lock %.0f%%%@",
                              t.from + 1, t.to + 1, Theme.time(t.start), t.plan.preset.displayName, together, before, after,
                              after - before, dip, bump, lowx2, vocx2, flam,
                              flams.map { String(format: "%.0f", $0) }.joined(separator: " "), t.nudge * 1000, t.grooveLock * 100, phrasing)
            print(line)
            let shift = (t.edit.semitones != 0 ? String(format: "  B %+d st", t.edit.semitones) : "")
                + (t.skippedBars > 0 ? "  A skipped \(t.skippedBars) bars before" : "")
            if t.skippedBars > 0 { payoffCounts["club edit", default: 0] += 1 }
            print("      payoff: " + (t.payoff.isEmpty ? "none" : t.payoff.joined(separator: " · ")) + shift
                  + "  vocals: B in on \(t.vocalInKind ?? "-"), A " + (t.vocalOutBlend ? "blends out" : "cut")
                  + String(format: " (bars: A out %@, B in %@, switch %@)",
                           t.vocalOut.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-",
                           t.vocalIn.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-",
                           t.plan.placement.lowSwap.map(String.init) ?? "-"))
            for tag in t.payoff { payoffCounts[tag.components(separatedBy: ":")[0], default: 0] += 1 }
            if t.payoff.isEmpty { payoffCounts["none", default: 0] += 1 }
            // A lift is how a set builds; a drop is what empties a floor.
            if after - before < -3 || after - before > 6 || dip > 4 || lowx2 > 2 || vocx2 > 1 || flam > 10 || !phrasing.isEmpty {
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
        let sagging = Double(curve.filter { $0 < Double(MixMath.targetLoudness) - 4 }.count) / Double(max(1, curve.count))
        print(String(format: "Time more than 4 dB under full power: %.0f%%", sagging * 100))
        // Where: stretches of 12 s or more, and whose they are.
        func playing(_ t: Double) -> String {
            let i = mix.transitions.firstIndex { t < $0.start } ?? mix.tracks.count - 1
            if i > 0, t < mix.transitions[i - 1].end { return "\(i)→\(i + 1) blend" }
            return "song \(i + 1)"
        }
        var runStart: Int?
        for (i, v) in (curve + [0]).enumerated() {
            if v < Double(MixMath.targetLoudness) - 4 {
                if runStart == nil { runStart = i }
            } else if let r = runStart {
                if i - r >= 3 {
                    print(String(format: "  under full power %@–%@ (%d s) in %@, %.1f dB", Theme.time(Double(r) * 4),
                                 Theme.time(Double(i) * 4), (i - r) * 4, playing(Double(r) * 4),
                                 curve[r..<i].reduce(0, +) / Double(i - r)))
                }
                runStart = nil
            }
        }
        print(String(format: "\n==== ENERGY ==== length %@  median %.1f dB  p10 %.1f dB  p90 %.1f  longest stretch >6 dB under target: %d s",
                     Theme.time(mix.length), sorted[sorted.count / 2], sorted[sorted.count / 10], sorted[sorted.count * 9 / 10],
                     longestLow * 4))
        print("Flagged:\n" + (worst.isEmpty ? "  none" : worst.joined(separator: "\n")))
        print("Bars both songs are heard: " + togetherBars.map(String.init).joined(separator: " ")
              + "  (under 6: \(togetherBars.filter { $0 < 6 }.count))")
        print("Payoffs over \(mix.transitions.count) transitions: "
              + payoffCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Passable/Lab/Set.wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Exporter.render(snapshot: set.makeSnapshot(), range: 0..<Int(mix.length * sr), tail: 3, to: url) { _ in }
        print("Rendered \(url.path)")
    }
}
