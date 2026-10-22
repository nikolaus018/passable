import XCTest
@testable import Passable

/// Every combination the set builder can ask the TransitionBuilder for,
/// checked against the rules the transitions claim to follow. No audio:
/// the automation alone decides who plays what, when.
final class ChoreographyProbe: XCTestCase {
    func testEveryChoreographyKeepsItsRules() throws {
        guard ProcessInfo.processInfo.environment["PASSABLE_CHOREO"] != nil else { throw XCTSkip("set PASSABLE_CHOREO") }
        var failures: [String: (count: Int, example: String)] = [:]
        func fail(_ rule: String, _ example: String) {
            failures[rule, default: (0, example)].count += 1
        }
        var built = 0
        for preset in [TransitionPreset.stemSwap, .dropSwap, .longBlend, .echoOut] {
            // (A Wash Out also as its short bridge and as a one-bar cut.)
            for n in preset == .echoOut ? [1, 4, 8, 16] : [8, 16] {
                let swaps: [Int?] = preset == .stemSwap ? [nil] + Array(1...n).map { $0 } : [nil]
                for sw in swaps {
                    for clash in [false, true] {
                        for layer in [false, true] {
                            for linger in [false, true] where !linger || layer {
                                for mashup in [false, true] where !mashup || (preset == .stemSwap && !clash) {
                                  for carry in [false, true] where !carry || (preset == .stemSwap && !clash && !mashup) {
                                    for drop in [false, true] where !drop || preset != .echoOut {
                                        let vocalBars = Array(Set([n / 4, n / 2, 3 * n / 4, n]))
                                        for vocalBar in vocalBars {
                                            for vocalIn in [nil] + [Double(n) / 4 + 0.25, Double(n) / 2 + 0.5, Double(n) - 0.75]
                                                .map { Optional($0) } {
                                                // Where the set builder may put A's exit: in
                                                // a Wash Out's bridge, otherwise from bar 0
                                                // to where B's voice sounds (which can be a
                                                // little after its channel opens).
                                                let exits: [Double?] = preset == .echoOut ? [nil, -1.5]
                                                    : [nil, Double(n) / 4, Double(n) / 2 - 0.25]
                                                for vocalOut in exits {
                                                    built += 1
                                                    let made = TransitionBuilder.make(
                                                        preset, lanes: Lane.allLanes(), start: 0, barSeconds: 1, bars: n,
                                                        vocalBar: vocalBar, keysClash: clash, lowSwap: sw,
                                                        drumsLayer: layer, drumsLinger: linger, vocalIn: vocalIn,
                                                        vocalOut: vocalOut, mashup: mashup, dropMoment: drop,
                                                        rollBeat: nil, vocalOutFade: 0, vocalInFade: 0, room: 6, carry: carry)
                                                    let tag = "\(preset.rawValue) n=\(n) sw=\(sw.map(String.init) ?? "nil") clash=\(clash) layer=\(layer) linger=\(linger) mashup=\(mashup) carry=\(carry) drop=\(drop) vocalBar=\(vocalBar) vin=\(vocalIn.map { "\($0)" } ?? "nil") vout=\(vocalOut.map { "\($0)" } ?? "nil")"
                                                    check(made, preset: preset, n: n, tag: tag, fail: fail)
                                                }
                                            }
                                        }
                                    }
                                  }
                                }
                            }
                        }
                    }
                }
            }
        }
        print("CHOREO built \(built)")
        for (rule, f) in failures.sorted(by: { $0.key < $1.key }) {
            print("CHOREO \(f.count)× \(rule)\n    e.g. \(f.example)")
            XCTFail("\(f.count)× \(rule), e.g. \(f.example)")
        }
    }

    private func swapBar(_ tag: String, n: Int) -> Double {
        let sw = tag.components(separatedBy: " ").first { $0.hasPrefix("sw=") }!.dropFirst(3)
        return TransitionBuilder.switchBar(.stemSwap, bars: n, lowSwap: Int(sw))
    }

    private func check(_ made: TransitionBuilder.Made, preset: TransitionPreset, n: Int, tag: String,
                       fail: (String, String) -> Void) {
        var byID: [String: Lane] = [:]
        for l in made.lanes { byID[l.id] = l }
        func lane(_ side: DeckSide, _ stem: StemKind) -> Lane { byID["\(side.rawValue).\(stem.rawValue)"]! }
        func vol(_ side: DeckSide, _ stem: StemKind, _ t: Double) -> Double { lane(side, stem).value(.volume, at: t) }
        func lowsOn(_ side: DeckSide, _ stem: StemKind, _ t: Double) -> Bool {
            let l = lane(side, stem)
            if LaneParameter.eqDecibels(l.value(.low, at: t)) <= MixRenderer.killDB { return false }
            if case .highPass(let f) = LaneParameter.filter(l.value(.filter, at: t)), f >= 120 { return false }
            if case .lowPass(let f) = LaneParameter.filter(l.value(.filter, at: t)), f < 60 { return false }
            return true
        }
        func heard(_ side: DeckSide, _ stem: StemKind, _ t: Double) -> Bool { vol(side, stem, t) > 0.1 }
        let echo = preset == .echoOut
        let from = echo ? -Double(min(n, 8)) - 2 : -2.0
        let to = Double(n) + 6
        // Between the grid's lines: a cut takes a thousandth of a bar, and a
        // sample landing inside it would see both sides at once.
        var t = from + 1.0 / 128
        var noLowRun = 0.0, noDrumsRun = 0.0
        var reported = Set<String>()
        func once(_ rule: String) {
            guard !reported.contains(rule) else { return }
            reported.insert(rule)
            fail(rule, tag + String(format: " @bar %.3f", t))
        }
        while t < to {
            let inBlend = echo ? t > -Double(min(n, 8)) && t < 0 : t > 0 && t < Double(n)
            // Before B's entry B is silent, and A is as it was.
            if t < (echo ? -Double(min(n, 8)) : 0) {
                for stem in StemKind.allCases where heard(.b, stem, t) { once("B heard before its entry (\(stem))") }
            }
            if !echo && t < 0 {
                for stem in StemKind.allCases where vol(.a, stem, t) < 0.99 { once("A not whole before the blend (\(stem))") }
            }
            // One bass line at a time.
            if heard(.a, .bass, t) && heard(.b, .bass, t) && lowsOn(.a, .bass, t) && lowsOn(.b, .bass, t) {
                once("two bass lines at once")
            }
            // Nor a melody's low end (synth bass, 808s) under the other's.
            if heard(.a, .other, t) && heard(.b, .bass, t) && lowsOn(.a, .other, t) && lowsOn(.b, .bass, t) {
                once("A's melody lows under B's bass line")
            }
            if heard(.b, .other, t) && heard(.a, .bass, t) && lowsOn(.b, .other, t) && lowsOn(.a, .bass, t) {
                once("B's melody lows under A's bass line")
            }
            // One kick at a time.
            if heard(.a, .drums, t) && heard(.b, .drums, t) && lowsOn(.a, .drums, t) && lowsOn(.b, .drums, t) {
                once("two kicks at once")
            }
            // Kick without bass, or bass line of one song under the other's kick.
            let kickA = heard(.a, .drums, t) && lowsOn(.a, .drums, t), kickB = heard(.b, .drums, t) && lowsOn(.b, .drums, t)
            let bassA = heard(.a, .bass, t), bassB = heard(.b, .bass, t)
            if (kickA && bassB && !bassA) || (kickB && bassA && !bassB) { once("kick of one song, bass line of the other") }
            // The low end never empty for long (a drop moment's silence is half a beat).
            if !kickA && !kickB && !bassA && !bassB { noLowRun += 1.0 / 64 } else { noLowRun = 0 }
            if noLowRun > 0.5 && (!echo || t > 0) { once("no kick or bass for over half a bar") }
            let drumsA = heard(.a, .drums, t), drumsB = heard(.b, .drums, t)
            if !drumsA && !drumsB { noDrumsRun += 1.0 / 64 } else { noDrumsRun = 0 }
            if noDrumsRun > 1 && !echo { once("no drums at all for over a bar inside a blend") }
            // Two voices at once.
            // (Unless the caller kept A's past B's channel opening: it does
            // that where B's isn't singing yet.)
            let keptOn = tag.components(separatedBy: " vout=").last.flatMap(Double.init).map { out in
                (made.vocalEntry ?? .infinity) < out
            } ?? false
            if heard(.a, .vocals, t) && heard(.b, .vocals, t) && !keptOn { once("two vocals at once") }
            // A's voice gone before B's arrives or B takes the low end: a
            // hole nobody sings in (only where the caller didn't place A's
            // exit itself).
            if preset == .stemSwap, tag.hasSuffix("vout=nil"), t > 0, let entry = made.vocalEntry,
               t < min(entry, swapBar(tag, n: n)) - 0.01, !heard(.a, .vocals, t), !heard(.b, .vocals, t) {
                once("voice hole before B's voice or the swap")
            }
            // Two beats at different tempos.
            if echo && (heard(.a, .drums, t) || heard(.a, .bass, t)) && (heard(.b, .drums, t) || heard(.b, .bass, t)) {
                once("wash out: two beats at once")
            }
            if echo && heard(.a, .other, t) && heard(.b, .other, t) { once("wash out: two melodies at once") }
            // Melodies of clashing keys.
            if made.lanes.isEmpty == false, inBlend || t >= 0 {
                // (keys clash is in the tag; checked by caller through melodies)
            }
            // After the blend A is gone: B glides home from there.
            if t > Double(n) + 0.05 && !echo {
                for stem in StemKind.allCases where heard(.a, stem, t) { once("A still heard past the blend (\(stem))") }
            }
            if t > 0.5 && echo {
                for stem in StemKind.allCases where heard(.a, stem, t) { once("wash out: A heard after B's downbeat (\(stem))") }
            }
            // B whole once the blend is over.
            if t > Double(n) + 4.5 {
                let b = StemKind.allCases.filter { vol(.b, $0, t) < 0.99 || !lowsOn(.b, $0, t) }
                if !b.isEmpty { once("B not whole 4.5 bars past the blend (\(b))") }
                for stem in StemKind.allCases {
                    let l = lane(.b, stem)
                    for p in [LaneParameter.filter, .low, .mid, .high] where abs(l.value(p, at: t) - 0.5) > 0.01 {
                        once("B's \(stem) \(p.displayName) not neutral after the blend")
                    }
                }
            }
            t += 1.0 / 64
        }
        // Clashing keys: melodies never together.
        if tag.contains("clash=true") {
            var u = 1.0 / 128
            while u < to {
                if heard(.a, .other, u) && heard(.b, .other, u) {
                    fail("clashing keys: both melodies heard", tag + String(format: " @bar %.3f", u)); break
                }
                if heard(.a, .vocals, u) && heard(.b, .other, u) {
                    fail("clashing keys: A's voice over B's melody", tag + String(format: " @bar %.3f", u)); break
                }
                if heard(.b, .vocals, u) && (heard(.a, .other, u) || heard(.a, .bass, u)) {
                    fail("clashing keys: B's voice over A's melody/bass", tag + String(format: " @bar %.3f", u)); break
                }
                if heard(.b, .other, u) && heard(.a, .bass, u) {
                    fail("clashing keys: B's melody over A's bass line", tag + String(format: " @bar %.3f", u)); break
                }
                u += 1.0 / 64
            }
        }
    }
}
