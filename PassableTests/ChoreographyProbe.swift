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
        for preset in TransitionPreset.allCases {
            // (A Wash Out also as its short bridge and as a one-bar cut; Mashup as 16 and 24.)
            let lengths = preset == .echoOut ? [1, 4, 8, 16] : preset == .mashup ? [16, 24] : [8, 16]
            for n in lengths {
                let swaps: [Int?] = preset == .stemSwap ? [nil] + Array(1...n).map { $0 }
                    : preset == .mashup ? [nil, n / 2, 3 * n / 4] : [nil]
                for sw in swaps {
                    for clash in [false, true] {
                        for layer in [false, true] {
                            for linger in [false, true] where !linger || layer {
                                for mashup in [false, true] where !mashup || (preset == .stemSwap && !clash) {
                                  for carry in [false, true] where !carry || (preset == .stemSwap && !clash && !mashup) {
                                    for drop in [false, true] where !drop || preset != .echoOut {
                                        let vocalBars = preset == .mashup ? [0] : Array(Set([n / 4, n / 2, 3 * n / 4, n]))
                                        for vocalBar in vocalBars {
                                            let ins: [Double?] = preset == .mashup ? [nil, 0.25, 2.0]
                                                : [nil] + [Double(n) / 4 + 0.25, Double(n) / 2 + 0.5, Double(n) - 0.75].map { Optional($0) }
                                            for vocalIn in ins {
                                                // Where the set builder may put A's exit: in
                                                // a Wash Out's bridge, otherwise from bar 0
                                                // to where B's voice sounds (which can be a
                                                // little after its channel opens).
                                                let exits: [Double?] = preset == .echoOut ? [nil, -1.5]
                                                    : preset == .mashup ? [nil, 0]
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
        // Club moves: every BuildStyle (fakeoutDrop, stutterGate, polyRoll,
        // acappellaBreak, loopHalve, riser, bassDrop, snareRoll), vocalTease,
        // holdMelody, and 1-bar Cut flavors (vinylBrake, spinback, acapellaBridge).
        for preset in [TransitionPreset.stemSwap, .dropSwap, .mashup] {
            for n in preset == .dropSwap ? [8, 16] : [16] {
                for style in TransitionBuilder.BuildStyle.allCases {
                    for clash in [false, true] {
                        for layer in [false, true] {
                            let sw = preset == .stemSwap ? 8 : nil
                            let vin: Double? = preset == .mashup ? 0 : 8
                            let vout: Double? = preset == .mashup ? 0 : 8
                            built += 1
                            let made = TransitionBuilder.make(
                                preset, lanes: Lane.allLanes(), start: 0, barSeconds: 1, bars: n,
                                vocalBar: preset == .mashup ? 0 : n / 2, keysClash: clash, lowSwap: sw,
                                drumsLayer: layer, drumsLinger: false, vocalIn: vin, vocalOut: vout,
                                mashup: preset == .mashup, dropMoment: true, buildStyle: style)
                            let tag = "\(preset.rawValue) n=\(n) sw=\(sw.map(String.init) ?? "nil") clash=\(clash) layer=\(layer) style=\(style.rawValue) vout=\(vout.map { "\($0)" } ?? "nil")"
                            check(made, preset: preset, n: n, buildStyle: style, tag: tag, fail: fail)
                        }
                    }
                }
            }
        }
        for (vinyl, spin, bridge) in [(true, false, false), (false, true, false), (false, false, true)] {
            built += 1
            let made = TransitionBuilder.make(
                .echoOut, lanes: Lane.allLanes(), start: 0, barSeconds: 1, bars: 1,
                vinylBrake: vinyl, spinback: spin, acapellaBridge: bridge)
            let tag = "echoOut n=1 vinyl=\(vinyl) spin=\(spin) bridge=\(bridge)"
            check(made, preset: .echoOut, n: 1, isCutFlavor: true, tag: tag, fail: fail)
            if vinyl { XCTAssertTrue(made.rolls.contains { $0.brake == true }, tag) }
            if spin { XCTAssertTrue(made.rolls.contains { $0.spinback == true }, tag) }
        }
        for preset in [TransitionPreset.stemSwap, .dropSwap] {
            for teaseAt in [2.0, 4.0] {
                built += 1
                let made = TransitionBuilder.make(
                    preset, lanes: Lane.allLanes(), start: 0, barSeconds: 1, bars: 16,
                    vocalBar: 8, keysClash: false, lowSwap: 8, vocalIn: 8, vocalOut: 2,
                    vocalTease: (at: teaseAt, from: 8, duration: 0.5))
                let tag = "\(preset.rawValue) n=16 sw=8 clash=false tease=\(teaseAt) vout=2"
                check(made, preset: preset, n: 16, hasTease: true, tag: tag, fail: fail)
                // Tease filter must reset to neutral (0.5) before real vocal entry at bar 8.
                let bVoc = made.lanes.first { $0.side == .b && $0.stem == .vocals }!
                if abs(bVoc.value(.filter, at: 7.5) - 0.5) > 0.01 {
                    fail("vocal tease filter did not reset before vocalEntry", tag)
                }
            }
        }
        for n in [8, 16] {
            for carry in [false, true] {
                built += 1
                let made = TransitionBuilder.make(
                    .stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 1, bars: n,
                    vocalBar: n / 2, keysClash: false, lowSwap: n, carry: carry, holdMelody: true)
                let tag = "stemSwap n=\(n) sw=\(n) clash=false carry=\(carry) holdMelody=true vout=nil"
                check(made, preset: .stemSwap, n: n, tag: tag, fail: fail)
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

    private func check(_ made: TransitionBuilder.Made, preset: TransitionPreset, n: Int,
                       buildStyle: TransitionBuilder.BuildStyle? = nil,
                       isCutFlavor: Bool = false, hasTease: Bool = false, tag: String,
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
        // (Parts switch on and off ahead of their beat, and low-end switches
        // crossfade over `lowRamp` (18 ms) so they never tick: see
        // `TransitionBuilder.switchBeforeTheBeat`.)
        let lead = TransitionBuilder.switchLead / 1
        let lowRamp = max(TransitionBuilder.lowRamp, TransitionBuilder.melodyRamp) / 1
        let vocalCloseLead = (TransitionBuilder.switchLead + TransitionBuilder.vocalRelease) / 1
        let from = echo ? -Double(min(n, 8)) - 2 : -2.0
        let to = Double(n) + 6
        // Sample between grid lines; skip the intentional 18 ms low-end
        // crossfade window right before a beat boundary (`t` in `[b - lead - lowRamp, b - lead]`).
        func inLowCrossfade(_ time: Double) -> Bool {
            let nextBeat = ((time + lead + lowRamp) * 4).rounded(.down) / 4
            let lo = nextBeat - lead - lowRamp - 0.002
            let hi = nextBeat - lead + 0.002
            return time >= lo && time <= hi
        }
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
            if t < (echo ? -Double(min(n, 8)) : 0) - lead - lowRamp {
                for stem in StemKind.allCases where heard(.b, stem, t) { once("B heard before its entry (\(stem))") }
            }
            if !echo && t < -lead - lowRamp {
                for stem in StemKind.allCases where vol(.a, stem, t) < 0.99 {
                    // In `.mashup`, A's vocal closes right on bar 0 over `vocalRelease` + `switchLead`.
                    if preset == .mashup && stem == .vocals && t >= -vocalCloseLead - 0.005 { continue }
                    once("A not whole before the blend (\(stem))")
                }
            }
            let _ = isCutFlavor
            // One bass line at a time (outside the 18 ms click-free low crossfade).
            if !inLowCrossfade(t) && heard(.a, .bass, t) && heard(.b, .bass, t) && lowsOn(.a, .bass, t) && lowsOn(.b, .bass, t) {
                once("two bass lines at once")
            }
            // Nor a melody's low end (synth bass, 808s) under the other's.
            if !inLowCrossfade(t) && heard(.a, .other, t) && heard(.b, .bass, t) && lowsOn(.a, .other, t) && lowsOn(.b, .bass, t) {
                once("A's melody lows under B's bass line")
            }
            if !inLowCrossfade(t) && heard(.b, .other, t) && heard(.a, .bass, t) && lowsOn(.b, .other, t) && lowsOn(.a, .bass, t) {
                once("B's melody lows under A's bass line")
            }
            // One kick at a time.
            if !inLowCrossfade(t) && heard(.a, .drums, t) && heard(.b, .drums, t) && lowsOn(.a, .drums, t) && lowsOn(.b, .drums, t) {
                once("two kicks at once")
            }
            // Kick without bass, or bass line of one song under the other's kick.
            let kickA = heard(.a, .drums, t) && lowsOn(.a, .drums, t), kickB = heard(.b, .drums, t) && lowsOn(.b, .drums, t)
            let bassA = heard(.a, .bass, t), bassB = heard(.b, .bass, t)
            if (kickA && bassB && !bassA) || (kickB && bassA && !bassB) { once("kick of one song, bass line of the other") }
            // The low end never empty for long (a drop moment's silence is half a beat;
            // explicit club drops like loopHalve/acappellaBreak/stutterGate/polyRoll pull
            // lows for 1 bar, and fakeoutDrop holds a 1.5-bar tension drop).
            let maxLowGap: Double = switch buildStyle {
            case .fakeoutDrop: 1.6
            case .acappellaBreak, .loopHalve, .stutterGate, .polyRoll, .vocalChop, .beatJuggle, .echoFreeze: 1.1
            case .filterSlam: 0.6
            default: 0.5
            }
            let maxDrumsGap: Double = switch buildStyle {
            case .fakeoutDrop: 1.25
            case .acappellaBreak: 1.1
            default: 1.0
            }
            if !kickA && !kickB && !bassA && !bassB { noLowRun += 1.0 / 64 } else { noLowRun = 0 }
            if noLowRun > maxLowGap && (!echo || t > 0) { once("no kick or bass for over \(maxLowGap) bar") }
            let drumsA = heard(.a, .drums, t), drumsB = heard(.b, .drums, t)
            if !drumsA && !drumsB { noDrumsRun += 1.0 / 64 } else { noDrumsRun = 0 }
            if noDrumsRun > maxDrumsGap && !echo { once("no drums at all for over \(maxDrumsGap) bar inside a blend") }
            // Two voices at once.
            // (Unless the caller kept A's past B's channel opening: it does
            // that where B's isn't singing yet.)
            let keptOn = tag.components(separatedBy: " vout=").last.flatMap(Double.init).map { out in
                (made.vocalEntry ?? .infinity) < out
            } ?? false
            if heard(.a, .vocals, t) && heard(.b, .vocals, t) && !keptOn && !hasTease { once("two vocals at once") }
            // A's voice gone before B's arrives or B takes the low end: a
            // hole nobody sings in (only where the caller didn't place A's
            // exit itself).
            if preset == .stemSwap, tag.hasSuffix("vout=nil"), t > 0, let entry = made.vocalEntry,
               t < min(entry, swapBar(tag, n: n)) - 0.01 - lead, !heard(.a, .vocals, t), !heard(.b, .vocals, t) {
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
        // Clashing keys: melodies never together (outside the 18 ms click-free switch ramp).
        if tag.contains("clash=true") {
            var u = 1.0 / 128
            while u < to {
                if inLowCrossfade(u) { u += 1.0 / 64; continue }
                if heard(.a, .other, u) && heard(.b, .other, u) {
                    fail("clashing keys: both melodies heard", tag + String(format: " @bar %.3f", u)); break
                }
                if heard(.a, .vocals, u) && heard(.b, .other, u) {
                    fail("clashing keys: A's voice over B's melody", tag + String(format: " @bar %.3f", u)); break
                }
                // In a drum-bed mashup (`preset == .mashup`), A strips its melody
                // over the first 2 bars and low-passes its bass to pure sub (<0.25)
                // so B's vocal rides cleanly on A's beat.
                let drumBedStrip = preset == .mashup && u <= 2.05
                let aBassSubOnly = preset == .mashup && lane(.a, .bass).value(.filter, at: u) < 0.25
                if heard(.b, .vocals, u) && ((heard(.a, .other, u) && !drumBedStrip) || (heard(.a, .bass, u) && !aBassSubOnly && !drumBedStrip)) {
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
