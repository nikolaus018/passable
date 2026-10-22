import Accelerate
import XCTest
@testable import Passable

/// Not a unit test: builds a set from the songs listed in $PASSABLE_SET (one
/// path per line, any order), lets Passable order it, renders it to
/// ~/Music/Passable/Lab/Set.wav and measures every transition and the energy
/// over the whole set. Skipped unless the variable is set.
///
/// With $PASSABLE_SET_AUDIT (a folder), each transition is also written out
/// as two files, the outgoing song alone and the incoming one alone as they
/// play through it, with a list of what is where: for a beat tracker that
/// knows nothing of Passable's own grids (tools/audit/audit.py) to say
/// whether the two songs' beats and bars really coincide.
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
        // $PASSABLE_SET_FIXED: the songs play in the order listed, so two
        // runs measure the same pairs.
        let fixed = ProcessInfo.processInfo.environment["PASSABLE_SET_FIXED"] != nil
        set.add(urls, asListed: fixed)
        let deadline = Date().addingTimeInterval(3600)
        while set.mix == nil || set.buildStatus != nil {
            if Date() > deadline { XCTFail("timeout"); return }
            if let failed = set.items.first(where: { if case .failed = $0.status { return true } else { return false } }) {
                XCTFail("\(failed.title): \(failed.status)"); return
            }
            // (A build that failed says so, and nothing more comes.)
            if let alert = set.alert { XCTFail("build failed: \(alert)"); return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let mix = try XCTUnwrap(set.mix)
        // What the order was chosen on: every neighbouring pair's price,
        // and the whole set's with what it pays for as a set.
        let analyses = set.items.map { $0.analysis! }
        let costs = SetOrdering.costMatrix(analyses, drums: BeatAlign.attacks(of: set.items.compactMap(\.loaded)))
        let washOuts = SetOrdering.washOuts(analyses), energies = analyses.map(SetOrdering.energy)
        print("\n==== SET ORDER ====")
        for (i, item) in set.items.enumerated() {
            let a = item.analysis!
            print(String(format: "%2d  %6.2f BPM  %@  energy %.2f  %@", i + 1, a.grid.bpm, a.key.camelotCode,
                         SetOrdering.energy(a), item.title))
            if let s = set.summary(from: i) { print(String(format: "      ↓ (cost %.2f) %@", costs[i][i + 1], s)) }
        }
        let path = Array(analyses.indices)
        var cheaper: [String] = []
        for i in path {
            var rest = path
            rest.remove(at: i)
            for j in 0...rest.count where j != i {
                var p = rest
                p.insert(i, at: j)
                let gain = SetOrdering.total(path, costs, washOuts, energies) - SetOrdering.total(p, costs, washOuts, energies)
                if gain > 0.01 { cheaper.append(String(format: "song %d to place %d saves %.2f", i + 1, j + 1, gain)) }
            }
        }
        print("Costs, row to column:")
        for i in path { print(String(format: "  %2d ", i + 1) + path.map { i == $0 ? "   – " : String(format: "%5.1f", costs[i][$0]) }.joined()) }
        print(String(format: "Order's total cost %.2f; single moves that would be cheaper: %@",
                     SetOrdering.total(path, costs, washOuts, energies), cheaper.isEmpty ? "none" : cheaper.joined(separator: ", ")))

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
            var lp2 = Biquad()
            lp2.set(.lowPass(frequency: 150, q: 0.707), sampleRate: sr)
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
                // Twice: the kick and bass, not the body of a melody or a
                // voice just above them (a 12 dB/octave slope let 250 Hz
                // count as low end).
                if lowPass { lp.process(&l, &r, count: n); lp2.process(&l, &r, count: n) }
                if highPass { hp.process(&l, &r, count: n) }
                var e = 0.0
                for k in 0..<n { e += Double(l[k] * l[k] + r[k] * r[k]) }
                out.append(10 * log10(max(1e-12, e / Double(2 * n))))
                t += step
            }
            return out
        }

        /// Where both decks' drums play, how far apart their hits land (ms,
        /// per two-bar window): attacks above 150 Hz to the millisecond,
        /// the hats, snares and clicks a flam is heard in (a full-band
        /// measure weighs A's kick body against B's hats and reads its slow
        /// rise as a flam). Anything past ~10 ms is heard.
        func kickOffsets(_ t: SetMix.Transition, from: Double, bars: Int) -> [Double] {
            func mono(_ track: Int) -> [Float] {
                let renderer = MixRenderer(snapshot: set.makeSnapshot { i, s in i == track && s == .drums })
                renderer.setPositionImmediately(Int(from * sr))
                let n = Int(Double(bars) * t.barSeconds * sr)
                var l = [Float](repeating: 0, count: n), r = l
                renderer.render(left: &l, right: &r, count: n)
                return zip(l, r).map { ($0 + $1) / 2 }
            }
            return BeatAlign.heardLags(a: mono(t.from), b: mono(t.to), window: 2 * t.barSeconds).map { $0 * 1000 }
        }

        print("\n==== TRANSITIONS ====")
        var worst: [String] = []
        var payoffCounts: [String: Int] = [:]
        var togetherBars: [Int] = []
        var busyBars: [Int] = []
        var vocalCuts: [String: Int] = [:]
        var held: [Int] = [], alone: [Int] = []
        var resumes: [Double] = [], silences: [Double] = []
        var partEdges: [(Float, Float)] = []
        var lyricCuts: [String: Int] = [:]
        var midParts = 0
        var exitWords: [String: Int] = [:]
        for t in mix.transitions {
            let bar = t.barSeconds
            // B as the blend counts it (see `Metre`): at half or double A's
            // tempo two of its bars make one of the blend's, or one two, and
            // its levels, lines and parts are read in those bars (as the
            // builder reads them). A cut plays B at its own tempo.
            let metreB = t.edit.preset == .echoOut ? Metre()
                : Metre(a: mix.tracks[t.from].loaded.analysis.grid, b: mix.tracks[t.to].loaded.analysis.grid, cue: t.edit.cueBar)
            let structureB = mix.tracks[t.to].loaded.analysis.counted(metreB).structure
            let cueB = metreB.counted(t.edit.cueBar)
            let barB = t.edit.preset == .echoOut ? mix.tracks[t.to].loaded.analysis.grid.barSeconds : bar
            // A Wash Out happens in the bars before B's downbeat.
            let from = t.start - Double(8 + (t.edit.preset == .echoOut ? min(8, t.edit.bars) : 0)) * bar
            // "After" is B's first eight bars on its own: what the blend
            // hands over, not wherever B's own song goes next.
            let until = t.end + 8 * bar
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
            // A Wash Out stops for half a beat before B's downbeat by design.
            let dropBar = t.edit.preset == .echoOut ? Int(((t.start - from) / bar).rounded()) - 1
                : t.dropAt.map { Int((($0 - from) / bar).rounded()) - 1 }
            let middle = all[8..<(all.count - 8)]
            // Nor is a break of a bar or two a song has of its own (the gap
            // before its drop or chorus): that's the record, not the
            // transition.
            let lead = Int(((t.start - from) / bar).rounded())
            func ownBreak(_ k: Int) -> Bool {
                let sides = [(mix.tracks[t.from].loaded.analysis.structure?.loudness, t.edit.entryBar),
                             (structureB?.loudness, cueB)]
                return sides.contains { loud, first in
                    guard let loud else { return false }
                    let x = first + k - lead
                    func notch(_ from: Int, _ to: Int) -> Bool {
                        guard from > 0, to + 1 < loud.count else { return false }
                        let deepest = loud[from...to].max()!
                        return deepest <= loud[from - 1] - 3 && deepest <= loud[to + 1] - 3
                    }
                    return notch(x, x) || notch(x - 1, x) || notch(x, x + 1)
                }
            }
            let judged = (8..<(all.count - 8)).filter { $0 != dropBar && !ownBreak($0) }.map { all[$0] }
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
            // Two low ends heard as two: both close to what a full low end
            // plays at here, not a breakdown's rumble against the other's
            // leftovers.
            let fullLow = max(lowA.max() ?? -120, lowB.max() ?? -120)
            let lowx2 = (0..<all.count).filter {
                min(lowA[$0], lowB[$0]) > fullLow - 12 && abs(lowA[$0] - lowB[$0]) < 10
            }.count
            let vocx2 = (0..<all.count).filter { vocA[$0] > -40 && vocB[$0] > -40 && abs(vocA[$0] - vocB[$0]) < 12 }.count
            // Too much at once: bars where three or more of the four tonal
            // parts (each song's melody and voice) are clearly heard, and
            // bars where both melodies are.
            let melA = levels(from: from, seconds: Double(bars) * bar, step: bar, highPass: true) { i, s in
                i == t.from && s == .other
            }
            let melB = levels(from: from, seconds: Double(bars) * bar, step: bar, highPass: true) { i, s in
                i == t.to && s == .other
            }
            func heard(_ x: [Double], _ k: Int) -> Bool { x[k] > -45 && x[k] > highs[k] - 10 }
            let busy = (0..<all.count).filter { k in [melA, vocA, melB, vocB].filter { heard($0, k) }.count >= 3 }.count
            let melodyBars = (0..<all.count).filter { heard(melA, $0) && heard(melB, $0) }
            let melx2 = melodyBars.count
            // Whether the melodies that do overlap sit in one key, heard on
            // the stems (A's melody and bass line against B's melody).
            var keyClash: Float = 0
            if let k0 = melodyBars.first, let k1 = melodyBars.last {
                let ta = mix.tracks[t.from], tb = mix.tracks[t.to]
                let f = from + Double(k0) * bar, u = from + Double(k1 + 1) * bar
                if let ca = Harmony.chroma([ta.stems[.other], ta.stems[.bass]].compactMap { $0 }, offset: ta.stemOffset(at: f),
                                           from: f, to: u),
                   let cb = Harmony.chroma([tb.stems[.other]].compactMap { $0 }, offset: tb.stemOffset(at: f), from: f, to: u) {
                    keyClash = Harmony.clash(ca, cb)
                }
            }
            busyBars.append(busy)
            // A voice taken out where its song still sings, with nobody
            // singing instead (the longest run of such bars in the blend
            // and the four after it): A's cut before B's voice arrives, or
            // B's held back where A has nothing to sing.
            // (A's cut is judged inside the blend: past its end A is over,
            // whoever sings.)
            var vocalGap = 0, heldBack = 0
            if t.edit.preset != .echoOut, let sa = mix.tracks[t.from].loaded.analysis.structure,
               let sb = structureB {
                let lead = Int(((t.start - from) / bar).rounded())
                var runA = 0, runB = 0
                for rel in 0..<min(t.edit.bars + 4, all.count - lead) {
                    let k = lead + rel
                    let silent = vocA[k] <= -40 && vocB[k] <= -40
                    // (Looped, A's song isn't singing on: its part was over.)
                    runA = silent && t.loopBars == 0 && sa.isActive(.vocals, bar: t.edit.entryBar + rel) ? runA + 1 : 0
                    runB = silent && sb.isActive(.vocals, bar: cueB + rel) ? runB + 1 : 0
                    if rel < t.edit.bars { vocalGap = max(vocalGap, runA) }
                    heldBack = max(heldBack, runB)
                }
            }
            // Wash Out never layers the beats.
            let flams = t.edit.preset == .echoOut ? [] : kickOffsets(t, from: from, bars: bars)
            // Typical, not worst: in some windows the two patterns simply
            // differ and correlate anywhere.
            let flam = flams.isEmpty ? 0 : flams.map(abs).sorted()[flams.count / 2]
            // Phrasing, heard on the vocals as they play: was A's still
            // sounding right where it was taken out, B's right where it was
            // let in (a line cut in two)?
            var phrasing = ""
            if !t.isEdited {
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
                // A cut or Wash Out drops B in whole: its voice must open
                // with its beat (or on a pickup just before), and not land
                // in the middle of a line.
                // A voice cut at `master` in the middle of one of its song's
                // sentences (between two of its clauses is no cut).
                func midSentence(_ st: TrackStructure?, _ bar0: Int, _ barLength: Double, at master: Double) -> Bool {
                    let k = VocalPhrasing.slots * bar0 + Int(((master - t.start) / barLength * Double(VocalPhrasing.slots)).rounded())
                    guard let st, let inside = st.midSentence(at: k) else { return true }
                    return inside && !st.clauseEnd(at: k)
                }
                // B's voice let in in the middle of a part of it (a verse
                // it sings through): heard as cutting in mid-sentence,
                // whatever line of the recogniser's starts there.
                func midPart(at master: Double) -> Bool {
                    let k = VocalPhrasing.slots * cueB + Int(((master - t.start) / barB * Double(VocalPhrasing.slots)).rounded())
                    return structureB?.midPart(at: k) ?? false
                }
                if t.edit.preset == .echoOut {
                    let vin = t.vocalIn ?? t.start
                    if vin > t.start + 0.05 * t.barSeconds,
                       stride(from: t.start, to: vin, by: t.barSeconds / 8).contains(where: { sounding(t.to, at: $0) }) {
                        phrasing += " B-HELD"
                    }
                    if vin >= t.start - 0.01, sounding(t.to, at: t.start), midSentence(structureB, cueB, barB, at: t.start) {
                        phrasing += " B-LANDS-MIDSENTENCE"
                    }
                }
                if let vin = t.vocalIn, sounding(t.to, at: vin + 0.06), midPart(at: vin) {
                    phrasing += " B-MIDPART"
                    midParts += 1
                }
                let n = Double(t.edit.bars), p = t.plan.placement
                let gridIn = t.start + min(n, max(n / 2, Double(p.vocalHandoff))) * t.barSeconds
                let vin = t.vocalIn ?? gridIn
                let sw = TransitionBuilder.switchBar(t.edit.preset, bars: t.edit.bars, lowSwap: p.lowSwap)
                let out = t.vocalOut ?? min(vin, t.start + sw * t.barSeconds)
                // A blended out or B blended in on purpose isn't a cut; B
                // opening on a word's attack is sounding by design.
                // (Nor is a voice cut between two lines of its words,
                // sounding or not: a rapper leaves no breath there.)
                if t.edit.preset != .echoOut, t.vocalOutKind != "bar", sounding(t.from, at: out),
                   midSentence(mix.tracks[t.from].loaded.analysis.structure, t.edit.entryBar, bar, at: out) { phrasing += " A-CUT" }
                if t.edit.preset != .echoOut, t.vocalInKind == "grid", sounding(t.to, at: vin),
                   midSentence(structureB, cueB, barB, at: vin) { phrasing += " B-MIDSENTENCE" }
            }
            // A Wash Out never layers two beats: its bridge is the blend.
            if together < min(6, t.edit.bars / 2 + 2), t.edit.preset != .echoOut { phrasing += " STRUNG-TOGETHER" }
            // The builder had to move the plan's entry, or the blend runs
            // past A's music: planned for one spot, played at another.
            if t.edit.entryBar != t.plan.placement.entryBar { phrasing += " ENTRY-MOVED" }
            if t.plan.placement.overruns { phrasing += " OVERRUNS" }
            if busy > 2 { phrasing += " CROWDED" }
            if vocalGap > 2 { phrasing += " VOCAL-GAP" }
            if melx2 > 0, keyClash > Harmony.clashTolerance { phrasing += " KEY-CLASH" }
            let line = String(format: "%2d→%2d at %@  %@  together %d bars  level %.1f → %.1f dB (%+.1f)  dip %.1f  bump %.1f  lowx2 %d  vocx2 %d  flam %.0f ms [%@] nudge %+.0f ms lock %.0f%%%@",
                              t.from + 1, t.to + 1, Theme.time(t.start), t.plan.preset.name(bars: t.edit.bars), together, before, after,
                              after - before, dip, bump, lowx2, vocx2, flam,
                              flams.map { String(format: "%.0f", $0) }.joined(separator: " "), t.nudge * 1000, t.grooveLock * 100, phrasing)
            print(line)
            print(String(format: "      busy %d bars  melodies together %d bars (clash %.2f)  A cut, nobody singing %d bars; B held back, nobody singing %d bars", busy, melx2,
                         keyClash, vocalGap, heldBack))
            let pp = t.plan.placement
            print("      A leaves from its bar \(t.edit.entryBar) (free from \(t.entryRange.lowerBound), \(mix.tracks[t.from].loaded.analysis.grid.barCount(duration: mix.tracks[t.from].loaded.analysis.duration)) bars), B comes in on its bar \(t.edit.cueBar)")
            print("      placement expected together: \(pp.together.map(String.init) ?? "-"), handoff \(pp.vocalHandoff), B's vocal at "
                  + (pp.expectedVocalIn.map { String(format: "%.2f", $0) } ?? "-") + ", switch \(pp.lowSwap.map(String.init) ?? "-"), drop \(pp.dropMoment)")
            if t.edit.preset != .echoOut {
                print(String(format: "      room %.0f dB  planned for lock %@  layered %@  lags ", t.room, t.plan.drumsLock ? "yes" : "no",
                             t.drumsLayered ? (t.drumsLinger ? "yes" : "before the swap") : t.hatsLayered ? "hats only" : "no")
                      + t.grooveLags.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " "))
            }
            let shift = (t.edit.semitones != 0 ? String(format: "  B %+d st", t.edit.semitones) : "")
                + (t.loopBars > 0 ? "  A loops \(t.loopBars) bars from \(t.plan.placement.loopBack) before" : "")
                + (t.skippedBars > 0 ? "  A skipped \(t.skippedBars) bars before" : "")
            if t.skippedBars > 0 { payoffCounts["club edit", default: 0] += 1 }
            print("      payoff: " + (t.payoff.isEmpty ? "none" : t.payoff.joined(separator: " · ")) + shift
                  + "  vocals: B in on \(t.vocalInKind ?? "-"), A out on \(t.vocalOutKind ?? "-")"
                  + String(format: " (bars: A out %@, B in %@, switch %@)",
                           t.vocalOut.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-",
                           t.vocalIn.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-",
                           t.plan.placement.lowSwap.map(String.init) ?? "-"))
            // Where in its singing each voice is cut: how soon A's would
            // have sung on after it's taken out (a breath in the middle of
            // a verse, or the end of one), and how long B's had been
            // silent before it's let in (the start of a part, or a line
            // somewhere inside it). In beats.
            if t.edit.preset != .echoOut, let fa = mix.tracks[t.from].loaded.analysis.structure,
               let fb = structureB,
               let la = fa.vocalSixteenthLevel, let lb = fb.vocalSixteenthLevel, let ra = fa.vocalReference, let rb = fb.vocalReference {
                func slot(_ master: Double?, _ bar0: Int, _ barLength: Double = t.barSeconds) -> Int? {
                    master.map { 16 * bar0 + Int((($0 - t.start) / barLength * 16).rounded()) }
                }
                let pa = AutoPlacement.phrases(fa, boundary: fa.boundaryStrength()).edge
                let pb = AutoPlacement.phrases(fb, boundary: fb.boundaryStrength()).edge
                func edge(_ parts: [Float], _ bar0: Int, _ master: Double?, leaving: Bool, _ barLength: Double = t.barSeconds) -> Float {
                    guard let master else { return 1 }
                    let bar = (master - t.start) / barLength
                    let g = bar0 + (leaving ? AutoPlacement.partBar(leaving: bar) : Int(bar.rounded()))
                    return g >= 0 && g < parts.count ? parts[g] : 1
                }
                let ea = edge(pa, t.edit.entryBar, t.vocalOut, leaving: true), eb = edge(pb, cueB, t.vocalIn, leaving: false, barB)
                partEdges.append((ea, eb))
                var note = "      voices:"
                note += String(format: " part edge A %.2f, B %.2f;", ea, eb)
                // Where that is in each song, and the corners its phrases are counted from.
                func corners(_ st: TrackStructure, near g: Int) -> String {
                    let b = st.boundaryStrength()
                    return b.indices.filter { k in
                        abs(k - g) <= 20 && b[k] >= 0.35 && (max(0, k - 2)...min(b.count - 1, k + 2)).allSatisfy { b[$0] <= b[k] }
                    }.map { String(format: "%d(%.2f)", $0, b[$0]) }.joined(separator: " ")
                }
                let ga = t.edit.entryBar + AutoPlacement.partBar(leaving: ((t.vocalOut ?? t.start) - t.start) / t.barSeconds)
                let gb = cueB + Int((((t.vocalIn ?? t.start) - t.start) / barB).rounded())
                print("      A's voice leaves on its bar \(ga) (entry \(t.edit.entryBar)); corners near: \(corners(fa, near: ga)).  B's comes in on its bar \(gb) (cue \(t.edit.cueBar)); corners near: \(corners(fb, near: gb))")
                if let k = slot(t.vocalOut, t.edit.entryBar) {
                    var j = k
                    while j < la.count, j < k + 16 * 16, VocalPhrasing.quiet(la[j], ra) { j += 1 }
                    let rest = Double(j - k) / 4
                    resumes.append(rest)
                    note += String(format: " A out on %@, would sing on after %.1f beats;", t.vocalOutKind ?? "-", rest)
                }
                if let k = slot(t.vocalIn, cueB, barB) {
                    var j = k - 1
                    while j >= 0, j > k - 16 * 16, VocalPhrasing.quiet(lb[j], rb) { j -= 1 }
                    let silent = Double(k - 1 - j) / 4
                    var first = k
                    while first < lb.count, first < k + 16 * 16, VocalPhrasing.quiet(lb[first], rb) { first += 1 }
                    silences.append(silent)
                    note += String(format: " B in on %@, silent for %.1f beats before, sings %.1f beats after", t.vocalInKind ?? "-", silent,
                                   Double(first - k) / 4)
                }
                // And by the words, where they were heard: a voice taken
                // out or let in while a line is being sung.
                func words(_ st: TrackStructure, _ k: Int?) -> String {
                    guard let k, let mid = st.midSentence(at: k) else { return "?" }
                    return mid && !st.clauseEnd(at: k) ? "MID-SENTENCE" : "between sentences"
                }
                let wa = words(fa, slot(t.vocalOut, t.edit.entryBar)), wb = words(fb, slot(t.vocalIn, cueB, barB))
                note += "  words: A out \(wa), B in \(wb)"
                // And by the recogniser's own sentences (a line of the
                // above can be half of one, split at a comma or a breath),
                // from where the voice really starts singing one to where
                // it stops (the recogniser stretches a first word back over
                // the silence before it): where A's voice leaves, if it was
                // singing there.
                if let k = slot(t.vocalOut, t.edit.entryBar), k < la.count, let inside = fa.midSentence(at: k),
                   (k..<min(la.count, k + 4)).contains(where: { !VocalPhrasing.quiet(la[$0], ra) }) {
                    let kind = inside ? (fa.clauseEnd(at: k) ? "at a comma" : "MID-SENTENCE")
                        : fa.midPart(at: k) == true ? "sentence end in a part" : "part end"
                    exitWords[kind, default: 0] += 1
                    note += " (\(kind))"
                }
                lyricCuts[wa, default: 0] += 1
                lyricCuts[wb, default: 0] += 1
                print(note)
            }
            vocalCuts["B in on \(t.vocalInKind ?? "-")", default: 0] += 1
            vocalCuts["A out on \(t.vocalOutKind ?? "-")", default: 0] += 1
            held.append(heldBack)
            alone.append(Int((t.begins - (mix.transitions.last { $0.end <= t.begins }?.end ?? 0)).rounded()))
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
        print("Crowded bars (3+ of the melodies and voices at once): " + busyBars.map(String.init).joined(separator: " "))
        let shifted = mix.transitions.filter { $0.edit.semitones != 0 }.count
        // What each song is heard stretched by: the two share it (see `MixMath.shared`).
        let stretches = mix.transitions.filter { $0.edit.preset != .echoOut }.map {
            max(abs($0.plan.shared.a - 1), abs($0.plan.shared.b - 1)) * 100
        }
        print(String(format: "Songs pitch-shifted: %d of %d;  stretch over 4%%: %d, largest %.1f%%", shifted,
                     mix.transitions.count, stretches.filter { $0 > 4 }.count, stretches.max() ?? 0))
        print("Vocals: " + vocalCuts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("B's voice let in mid-part (in a verse it sings through): \(midParts) of \(mix.transitions.count)")
        print("A's voice leaves, while singing, by its words: " + exitWords.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("How much of a part's end A's voice leaves on, and of a part's start B's comes in on (0…1): "
              + partEdges.map { String(format: "%.1f/%.1f", $0.0, $0.1) }.joined(separator: " ")
              + String(format: "  mean %.2f/%.2f", partEdges.map(\.0).reduce(0, +) / Float(max(1, partEdges.count)),
                       partEdges.map(\.1).reduce(0, +) / Float(max(1, partEdges.count))))
        print("Beats until A's voice would have sung on after its cut: " + resumes.map { String(format: "%.1f", $0) }.joined(separator: " "))
        print("Beats B's voice had been silent before it came in: " + silences.map { String(format: "%.1f", $0) }.joined(separator: " "))
        print("Bars nobody sings while B's voice is held back: " + held.map(String.init).joined(separator: " "))
        print("Seconds each song plays on its own before its way out: " + alone.map(String.init).joined(separator: " "))
        print("Voices by the words (both sides): " + lyricCuts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("Hats only layered: \(mix.transitions.filter { $0.hatsLayered }.count) of \(mix.transitions.count)")
        print("Looped: \(mix.transitions.filter { $0.loopBars > 0 }.count) of \(mix.transitions.count)")
        print("Payoffs over \(mix.transitions.count) transitions: "
              + payoffCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        if let audit = ProcessInfo.processInfo.environment["PASSABLE_SET_AUDIT"] {
            let folder = URL(fileURLWithPath: audit)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var entries: [[String: Any]] = []
            for (k, t) in mix.transitions.enumerated() {
                // Enough of each song on its own for a tracker to find its
                // beat: sixteen bars before and after.
                let lead = t.edit.preset == .echoOut ? Double(min(8, t.edit.bars)) : 0
                let from = max(0, t.start - (lead + 16) * t.barSeconds), to = min(mix.length, t.end + 16 * t.barSeconds)
                let range = Int(from * sr)..<Int(to * sr)
                for (name, track) in [("a", t.from), ("b", t.to)] {
                    try Exporter.render(snapshot: set.makeSnapshot { i, _ in i == track }, range: range, tail: 0,
                                        to: folder.appendingPathComponent(String(format: "%02d-%@.wav", k + 1, name))) { _ in }
                }
                /// Where the song's own time lands in the set: every beat
                /// of its grid that plays in the stretch written out, as
                /// (its own seconds, the set's). For beats tracked in the
                /// song file itself to be placed in the set.
                func warp(_ track: Int) -> [[Double]] {
                    let tr = mix.tracks[track], grid = tr.loaded.analysis.grid
                    return (-8..<(Int(tr.loaded.analysis.duration / grid.beatSeconds) + 8)).compactMap { i in
                        let own = grid.beat(i), master = tr.master(own)
                        if let skip = tr.skip, own >= skip.from, own < skip.to { return nil }
                        return master >= from - 1 && master <= to + 1 ? [own, master] : nil
                    }
                }
                entries.append([
                    "pathA": mix.tracks[t.from].url.path, "pathB": mix.tracks[t.to].url.path,
                    "warpA": warp(t.from), "warpB": warp(t.to),
                    "index": k + 1, "a": set.items[t.from].title, "b": set.items[t.to].title,
                    "preset": t.plan.preset.displayName, "bars": t.edit.bars, "from": from, "start": t.start, "end": t.end,
                    "barSeconds": t.barSeconds, "at": Theme.time(t.start),
                    "switch": TransitionBuilder.switchBar(t.edit.preset, bars: t.edit.bars, lowSwap: t.plan.placement.lowSwap),
                    "drumsLayered": t.drumsLayered, "melodiesClash": t.melodiesClash,
                    "stretchA": (t.plan.shared.a - 1) * 100, "stretchB": (t.plan.shared.b - 1) * 100,
                    "semitones": t.edit.semitones,
                    "bpmA": mix.tracks[t.from].loaded.analysis.grid.bpm, "bpmB": mix.tracks[t.to].loaded.analysis.grid.bpm,
                    "keyA": mix.tracks[t.from].loaded.analysis.key.displayName,
                    "keyB": mix.tracks[t.to].loaded.analysis.key.displayName,
                ])
            }
            try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
                .write(to: folder.appendingPathComponent("transitions.json"))
            print("Audit files in \(folder.path)")
        }

        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Passable/Lab/Set.wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Exporter.render(snapshot: set.makeSnapshot(), range: 0..<Int(mix.length * sr), tail: 3, to: url) { _ in }
        print("Rendered \(url.path)")
    }
}
