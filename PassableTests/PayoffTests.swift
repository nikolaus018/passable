import XCTest
@testable import Passable

/// What makes a transition more than a crossfade: rolls, drop moments,
/// mashups, hooks.
final class PayoffTests: XCTestCase {
    /// Inside a roll the stem repeats its loop; after it, it carries on
    /// where it would have been; every jump is faded, so nothing clicks.
    func testRollLoopsThenSlipsBackWithoutClicks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 60_000
        let ramp = (0..<n).map { Float($0) / 1_000_000 }
        try StemAudio.save(StereoBuffer(left: ramp, right: ramp), directory: dir, name: "x")
        let stem = try StemAudio.load(directory: dir, name: "x")

        let sr = AudioIO.sampleRate
        let roll = Roll(side: .a, stem: .drums, start: 10_000 / sr, end: 30_000 / sr, anchor: 12_000 / sr,
                        length: 2_000 / sr)
        let frames = try XCTUnwrap(MixSnapshot.FrameRoll(roll, sampleRate: sr))
        let snapshot = MixSnapshot(lanes: [.init(audio: stem, offset: 0, envelopes: Lane(side: .a, stem: .drums).envelopes,
                                                  audible: true, rolls: [frames])],
                                   length: n, delaySeconds: 0.3, masterGain: 1)
        let renderer = MixRenderer(snapshot: snapshot)
        var l = [Float](repeating: 0, count: n), r = l
        renderer.render(left: &l, right: &r, count: n)

        XCTAssertEqual(l[9_000], ramp[9_000], accuracy: 1e-6)
        XCTAssertEqual(l[10_000 + 3 * 2_000 + 500], ramp[12_500], accuracy: 1e-6)
        XCTAssertEqual(l[10_000 + 7 * 2_000 + 1_000], ramp[13_000], accuracy: 1e-6)
        XCTAssertEqual(l[30_500], ramp[30_500], accuracy: 1e-6)
        let steps = (1..<n).map { abs(l[$0] - l[$0 - 1]) }
        XCTAssertLessThan(steps.max()!, 5e-4, "a roll's jump clicks")
    }

    private func value(_ lanes: [Lane], _ side: DeckSide, _ stem: StemKind, bar: Double, barSeconds: Double = 2,
                       start: Double = 0) -> Double {
        lanes.first { $0.side == side && $0.stem == stem }!.value(.volume, at: start + bar * barSeconds)
    }

    func testDropMomentRollsIntoHalfABeatOfSilence() {
        let made = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16,
                                          lowSwap: 8, dropMoment: true)
        XCTAssertEqual(made.rolls.count, 3)
        XCTAssertTrue(made.rolls.allSatisfy { $0.side == .a && $0.stem == .drums && $0.end <= 16 - 0.25 + 1e-9 })
        XCTAssertEqual(made.rolls.map(\.length), [0.25, 0.125, 0.0625])
        let lanes = made.lanes
        // The roll plays alone: B's tops step aside, A's bass is out for
        // the last two beats.
        XCTAssertEqual(value(lanes, .a, .drums, bar: 7.5), 1)
        XCTAssertEqual(value(lanes, .b, .drums, bar: 7.5), 0)
        XCTAssertEqual(value(lanes, .a, .bass, bar: 7.4), 1)
        XCTAssertEqual(value(lanes, .a, .bass, bar: 7.75), 0)
        // Silence, then B in full and A gone.
        for side in DeckSide.allCases {
            for stem in [StemKind.drums, .bass, .other] {
                XCTAssertEqual(value(lanes, side, stem, bar: 7.95), 0, "\(side) \(stem)")
            }
        }
        for stem in [StemKind.drums, .bass, .other] {
            XCTAssertEqual(value(lanes, .b, stem, bar: 8.05), 1, "B \(stem)")
        }
        // A's beat is gone on the drop; its melody dissolves under B.
        XCTAssertEqual(value(lanes, .a, .drums, bar: 8.05), 0)
        XCTAssertEqual(value(lanes, .a, .bass, bar: 8.05), 0)
        XCTAssertGreaterThan(value(lanes, .a, .other, bar: 8.05), 0.5)
        XCTAssertEqual(value(lanes, .a, .other, bar: 10.1), 0)

        let plain = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16, lowSwap: 8)
        XCTAssertTrue(plain.rolls.isEmpty)
        XCTAssertEqual(value(plain.lanes, .a, .bass, bar: 7.95), 1)
    }

    /// A Wash Out keeps going into B's drop (A's melody carries the bridge
    /// right up to it: no stop that sounds like the song ended), and B's
    /// melody never plays over A's at another tempo.
    func testWashOutRunsStraightIntoTheDrop() {
        let lanes = TransitionBuilder.build(.echoOut, lanes: Lane.allLanes(), start: 60, barSeconds: 2, bars: 8)
        XCTAssertEqual(value(lanes, .a, .other, bar: -0.25, start: 60), 1)
        XCTAssertEqual(value(lanes, .b, .other, bar: -0.25, start: 60), 0)
        XCTAssertEqual(value(lanes, .b, .other, bar: -2, start: 60), 0)
        XCTAssertEqual(value(lanes, .b, .drums, bar: 0.05, start: 60), 1)
        XCTAssertEqual(value(lanes, .b, .other, bar: 0.05, start: 60), 1)
    }

    func testMashupLetsBSingOverAsBeat() {
        let mash = TransitionBuilder.build(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16,
                                           vocalBar: 4, mashup: true)
        XCTAssertEqual(value(mash, .b, .vocals, bar: 5.5), 1)
        XCTAssertEqual(value(mash, .a, .vocals, bar: 5.5), 0)
        XCTAssertEqual(value(mash, .a, .drums, bar: 5.5), 1, "A's beat carries B's vocal")
        let plain = TransitionBuilder.build(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16, vocalBar: 4)
        XCTAssertEqual(value(plain, .b, .vocals, bar: 5.5), 0)
    }

    /// A song whose chorus comes back louder than its verses: the hook
    /// starts where the chorus does, not on a verse.
    func testHookIsFoundAtTheChorus() {
        let bars = 64
        func section(_ b: Int) -> String {
            switch b {
            case 0..<8, 56..<64: return "intro"
            case 24..<32, 48..<56: return "chorus"
            default: return "verse"
            }
        }
        func pitch(_ p: Int, _ q: Int) -> [Float] {
            (0..<12).map { $0 == p ? 1 : $0 == q ? 0.6 : 0.1 }
        }
        let chroma: [[Float]] = (0..<bars).map { b in
            switch section(b) {
            case "intro": return pitch(0, 7)
            case "chorus": return pitch([5, 0, 7, 9][b % 4], [9, 4, 11, 1][b % 4])
            default: return pitch([9, 5, 0, 7][b % 4], [0, 9, 4, 11][b % 4])
            }
        }
        func per(_ intro: Float, _ verse: Float, _ chorus: Float) -> [Float] {
            (0..<bars).map { section($0) == "intro" ? intro : section($0) == "chorus" ? chorus : verse }
        }
        let structure = TrackStructure(activity: ["drums": per(0.2, 0.8, 1), "bass": per(0.1, 0.8, 1),
                                                  "other": per(0.6, 0.8, 1), "vocals": per(0, 0.7, 1)],
                                       loudness: per(-20, -16, -10))
        let hooks = TrackStructure.hookStarts(chroma: chroma, structure: structure)
        XCTAssertEqual(hooks.count, bars)
        let best = hooks.indices.max { hooks[$0] < hooks[$1] }!
        XCTAssertTrue([24, 48].contains(best), "hook at \(best)")
        XCTAssertGreaterThan(hooks[24], 0.5)
        XCTAssertGreaterThan(hooks[24], hooks[8] + 0.3)
        XCTAssertGreaterThan(hooks[24], hooks[28] + 0.3, "mid-chorus is no hook start")
    }

    /// Edits saved before rolls existed still open.
    func testOldEditsDecodeWithoutRolls() throws {
        let edit = TransitionEdit(entryBar: 12, cueBar: 4, preset: .stemSwap, bars: 16, semitones: 1,
                                  lanes: Lane.allLanes())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String: Any])
        json["rolls"] = nil
        let decoded = try JSONDecoder().decode(TransitionEdit.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, edit)

        var rolled = edit
        rolled.rolls = [Roll(side: .a, stem: .drums, start: 1, end: 2, anchor: 1.5, length: 0.25)]
        XCTAssertEqual(try JSONDecoder().decode(TransitionEdit.self, from: JSONEncoder().encode(rolled)), rolled)
    }

    /// B's parts drop in on a downbeat with a filter; A's vocal leaves with
    /// a cut into the echo. Nothing fades like a crossfade.
    func testPartsEnterWithTheFilterNotTheFader() {
        let lanes = TransitionBuilder.build(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16, lowSwap: 8)
        XCTAssertEqual(value(lanes, .b, .drums, bar: 0.01), 1)
        let drums = lanes.first { $0.side == .b && $0.stem == .drums }!
        XCTAssertGreaterThan(drums.value(.filter, at: 0.02), 0.6, "B's drums start with a light high-pass")
        XCTAssertEqual(drums.value(.filter, at: 16.1), 0.5, accuracy: 1e-9)
        // One part of B at a time: its melody a quarter in, thin under a
        // high-pass that has opened two bars on; its bass line only on
        // the swap; A's melody gone two bars after it.
        XCTAssertEqual(value(lanes, .b, .other, bar: 3.9), 0)
        XCTAssertEqual(value(lanes, .b, .other, bar: 4.01), 1)
        let other = lanes.first { $0.side == .b && $0.stem == .other }!
        XCTAssertGreaterThan(other.value(.filter, at: 2 * 4.02), 0.6)
        XCTAssertEqual(other.value(.filter, at: 2 * 6.01), 0.5, accuracy: 1e-9)
        XCTAssertEqual(value(lanes, .b, .bass, bar: 7.9), 0)
        XCTAssertEqual(value(lanes, .b, .bass, bar: 8.01), 1)
        XCTAssertEqual(value(lanes, .a, .other, bar: 10.01), 0, accuracy: 1e-6)
        XCTAssertEqual(value(lanes, .a, .vocals, bar: 7.9), 1, "A's vocal isn't faded under the echo")
        XCTAssertEqual(value(lanes, .a, .vocals, bar: 8.01), 0)
        let vocals = lanes.first { $0.side == .a && $0.stem == .vocals }!
        XCTAssertGreaterThan(vocals.value(.delay, at: 2 * 7.8), 0.5)
    }

    /// A melody stem carries low end too (synth bass, 808s): wherever the
    /// bass lines change hands, A's melody gives up its lows with them, so
    /// it never rumbles under B's bass line while it dissolves.
    func testMelodyLowsChangeHandsWithTheBass() {
        func low(_ lanes: [Lane], _ side: DeckSide, bar: Double) -> Double {
            LaneParameter.eqDecibels(lanes.first { $0.side == side && $0.stem == .other }!.value(.low, at: bar * 2))
        }
        for preset in [TransitionPreset.stemSwap, .dropSwap, .longBlend] {
            let lanes = TransitionBuilder.build(preset, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16, lowSwap: 8)
            XCTAssertEqual(TransitionBuilder.switchBar(preset, bars: 16, lowSwap: 8), 8)
            XCTAssertEqual(value(lanes, .b, .bass, bar: 8.01), 1, "\(preset)")
            XCTAssertGreaterThan(value(lanes, .a, .other, bar: 8.01), 0.1, "\(preset): A's melody still dissolving")
            XCTAssertEqual(low(lanes, .a, bar: 7.9), 0, accuracy: 0.01, "\(preset)")
            XCTAssertLessThanOrEqual(low(lanes, .a, bar: 8.01), MixRenderer.killDB, "\(preset)")
        }
    }

    /// Where the caller heard B's voice really start singing after its
    /// channel opens, a Drop Swap keeps A's on until then, as a Stem Swap
    /// does; clashing keys still take it out on the drop.
    func testDropSwapKeepsAsVoiceUntilBsSings() {
        let made = TransitionBuilder.make(.dropSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 8,
                                          vocalIn: 4.5, vocalOut: 5)
        XCTAssertEqual(made.vocalExit, 5)
        XCTAssertEqual(made.vocalEntry, 4.5)
        let clash = TransitionBuilder.make(.dropSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 8,
                                           keysClash: true, vocalIn: 4.5, vocalOut: 5)
        XCTAssertEqual(clash.vocalExit, 4)
        let plain = TransitionBuilder.make(.dropSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 8)
        XCTAssertEqual(plain.vocalExit, 4)
    }

    /// Once B's melody is in, A's drums and melody turn their mids and
    /// highs down (EQ, not the fader) so both songs are heard; where the
    /// keys clash only A's drums do, and without room nothing changes.
    func testAMakesRoomForB() {
        let lanes = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16,
                                           lowSwap: 8, room: 4).lanes
        func eq(_ lanes: [Lane], _ stem: StemKind, _ band: LaneParameter, bar: Double) -> Double {
            LaneParameter.eqDecibels(lanes.first { $0.side == .a && $0.stem == stem }!.value(band, at: bar * 2))
        }
        XCTAssertEqual(eq(lanes, .other, .high, bar: 3.5), 0, accuracy: 0.01)
        XCTAssertEqual(eq(lanes, .other, .high, bar: 4.1), -4, accuracy: 0.01)
        XCTAssertEqual(eq(lanes, .drums, .mid, bar: 6), -4, accuracy: 0.01)
        XCTAssertEqual(eq(lanes, .vocals, .mid, bar: 6), 0, accuracy: 0.01, "A's voice keeps its presence")
        let clash = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16,
                                           keysClash: true, lowSwap: 8, room: 4).lanes
        XCTAssertEqual(eq(clash, .other, .high, bar: 6), 0, accuracy: 0.01)
        XCTAssertEqual(eq(clash, .drums, .high, bar: 6), -4, accuracy: 0.01)
        let none = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16,
                                          lowSwap: 8).lanes
        XCTAssertEqual(eq(none, .other, .high, bar: 6), 0, accuracy: 0.01)
    }

    /// Room is what B needs to be heard within about 5 dB of A, as the
    /// blend lets it through, and no more.
    func testRoomComesFromTheLevels() {
        func song(_ db: Float) -> [StemKind: [TransitionShape.Gains]] {
            let p = pow(10, db / 10)
            return Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, Array(repeating: (p, p), count: 32)) })
        }
        let shape = TransitionShape(.stemSwap, bars: 16, vocalBar: 16, keysClash: false, lowSwap: 8)
        func room(_ b: Float) -> Double { AutoPlacement.room(shape, a: song(-10), e: 0, b: song(b), c: 0, from: 5, to: 8) }
        XCTAssertEqual(room(-10), 0, "as loud: nothing to do")
        // B's drums and melody are heard (its bass line waits for the
        // swap); only A's drums and melody give way (its bass and voice
        // stay), about 0.55 dB per dB of EQ.
        XCTAssertEqual(room(-11), 0, "two parts of B are already within reach")
        XCTAssertEqual(room(-13), 7)
        XCTAssertEqual(room(-20), 12, "at most 12 dB of EQ")
        XCTAssertEqual(room(-100), 0, "nothing to make room for")
    }

    /// A steady offset between two drum parts that's less than one onset
    /// frame (10 ms) is still found to the millisecond, nudged away, and
    /// the grooves are called locked.
    func testBeatAlignFindsASubFrameOffset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sr = 44_100, seconds = 20
        func hits(delay: Double) -> StereoBuffer {
            var buffer = StereoBuffer(count: sr * seconds)
            var rng = SystemRandomNumberGenerator()
            // Eighths at 120 BPM with an accent pattern, bright clicks.
            for k in 0..<(4 * seconds) {
                let at = Int((Double(k) * 0.25 + delay) * Double(sr))
                let level: Float = [1, 0.4, 0.7, 0.4][k % 4]
                for i in 0..<200 where at + i < buffer.count {
                    let v = level * Float.random(in: -1...1, using: &rng) * Float(exp(-Double(i) / 40))
                    buffer.left[at + i] = v
                    buffer.right[at + i] = v
                }
            }
            return buffer
        }
        try StemAudio.save(hits(delay: 0.1), directory: dir, name: "a")
        try StemAudio.save(hits(delay: 0.107), directory: dir, name: "b")
        let a = try StemAudio.load(directory: dir, name: "a"), b = try StemAudio.load(directory: dir, name: "b")
        let result = BeatAlign.nudge(a: a, aOffset: 0, b: b, bOffset: 0, from: 2, to: 18)
        XCTAssertEqual(result.nudge, -0.007, accuracy: 0.002)
        XCTAssertTrue(result.grooves)

        // The same is found from the songs' own hits, before B is rendered
        // at A's tempo: here B is 5 % slow, so the hit it plays at t is at
        // 1.05 t in its own file.
        func slow(_ buffer: StereoBuffer) -> StereoBuffer {
            var out = StereoBuffer(count: buffer.count)
            for k in 0..<(4 * seconds) {
                let from = Int((Double(k) * 0.25 + 0.107) * Double(sr)), to = Int((Double(k) * 0.25 + 0.107) * 1.05 * Double(sr))
                for i in 0..<200 where to + i < out.count && from + i < buffer.count {
                    out.left[to + i] = buffer.left[from + i]
                    out.right[to + i] = buffer.right[from + i]
                }
            }
            return out
        }
        try StemAudio.save(slow(b.copyStereo()), directory: dir, name: "slow")
        let ea = try XCTUnwrap(BeatAlign.attacks(of: a))
        let own = try XCTUnwrap(BeatAlign.attacks(of: try StemAudio.load(directory: dir, name: "slow")))
        let predicted = BeatAlign.predicted(a: ea, b: own, from: 2, to: 18, split: nil, bOffset: 0, rate: 1.05)
        XCTAssertEqual(predicted.nudge, -0.007, accuracy: 0.002)
        XCTAssertTrue(predicted.clearlyGrooves)
        // Hits that fall between A's are no groove.
        let off = BeatAlign.predicted(a: ea, b: own, from: 2, to: 18, split: nil, bOffset: 0, rate: 1.0)
        XCTAssertFalse(off.clearlyGrooves)
    }

    /// The placement simulation hears the EQ cut, as much as it takes off
    /// real songs: about 0.55 dB per dB.
    func testShapeHearsTheRoom() {
        let flat = TransitionShape(.stemSwap, bars: 16, vocalBar: 16, keysClash: false, lowSwap: 8)
        let cut = TransitionShape(.stemSwap, bars: 16, vocalBar: 16, keysClash: false, lowSwap: 8, room: 5)
        let a = flat.gains[.a]![.other]![5].high, b = cut.gains[.a]![.other]![5].high
        XCTAssertEqual(10 * log10(b / a), -2.75, accuracy: 0.3)
    }

    /// Notes heard together: a fifth sits, a tritone doesn't, and a clash
    /// can't hide in a scale that suits one side.
    func testHarmonyClashGrowsWithDistance() {
        let major = [0, 2, 4, 5, 7, 9, 11]
        func scale(_ root: Int) -> [Float] { (0..<12).map { major.contains(($0 - root + 12) % 12) ? 1 : 0.05 } }
        XCTAssertEqual(Harmony.clash(scale(0), scale(0)), 0, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(Harmony.clash(scale(0), scale(7)), Harmony.clashTolerance, "neighbours on the key wheel")
        XCTAssertFalse(Harmony.fits(scale(0), scale(6)))
        XCTAssertGreaterThan(Harmony.clash(scale(0), scale(2)), Harmony.clash(scale(0), scale(7)))
        XCTAssertGreaterThan(Harmony.clash(scale(0), scale(6)), 0.2)
        XCTAssertGreaterThan(Harmony.clash(scale(0), scale(1)), 0.2)
    }

    func testHarmonyHearsWhetherNotesSitTogether() {
        func notes(_ pcs: [Int]) -> [Float] { (0..<12).map { pcs.contains($0) ? 1 : 0.05 } }
        let cMajorChord = notes([0, 4, 7])
        XCTAssertTrue(Harmony.fits(cMajorChord, notes([0, 2, 4, 7, 9])), "a C melody over C")
        XCTAssertTrue(Harmony.fits(cMajorChord, notes([7, 11, 2])), "G, a fifth away")
        XCTAssertFalse(Harmony.fits(cMajorChord, notes([6, 10, 1])), "F♯ against C")
    }

    /// The roll repeats the beat that carries the snare, wherever it is.
    func testSnareBeatIsFound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sr = AudioIO.sampleRate, beat = 0.5
        var x = [Float](repeating: 0, count: Int(8 * sr))
        var seed: UInt64 = 7
        for k in 0..<16 {
            let i = Int(Double(k) * beat * sr)
            for j in 0..<4_000 {
                let decay = Float(exp(-Double(j) / 800))
                if k % 4 == 3 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    x[i + j] += 0.5 * decay * (Float(Int16(truncatingIfNeeded: seed >> 48)) / 32768)
                } else {
                    x[i + j] += 0.8 * decay * Float(sin(2 * Double.pi * 55 * Double(j) / sr))
                }
            }
        }
        try StemAudio.save(StereoBuffer(left: x, right: x), directory: dir, name: "drums")
        let drums = try StemAudio.load(directory: dir, name: "drums")
        XCTAssertEqual(BeatAlign.snareBeat(drums, offset: 0, barStart: 2, beat: beat), 3)
    }

    /// A verse or breakdown played on its own costs more than the same
    /// time at full power; a song hogging the floor costs too.
    func testPacingPrefersLeavingBeforeTheSag() {
        // 16 bars of chorus, then 16 of quieter, bass-less verse.
        let loud = [Float](repeating: -10, count: 16) + [Float](repeating: -16, count: 16)
        let on = [Float](repeating: 1, count: 16) + [Float](repeating: 0.2, count: 16)
        let s = TrackStructure(activity: ["drums": [Float](repeating: 1, count: 32), "bass": on], loudness: loud)
        let afterChorus = AutoPlacement.pacing(s, from: 0, to: 16, barSeconds: 2)
        let throughVerse = AutoPlacement.pacing(s, from: 0, to: 32, barSeconds: 2)
        XCTAssertGreaterThan(throughVerse, afterChorus + 0.8)
        XCTAssertGreaterThan(AutoPlacement.pacing(s, from: 0, to: 4, barSeconds: 2), afterChorus, "too short")
    }

    /// Where A is still singing at its exit, it blends out instead of
    /// being cut mid-word.
    func testVocalBlendsOutWhenAsked() {
        let cut = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16, lowSwap: 8)
        let blend = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16, lowSwap: 8,
                                           vocalOutFade: 1)
        XCTAssertEqual(cut.vocalExit, 8)
        XCTAssertEqual(value(cut.lanes, .a, .vocals, bar: 7.5), 1)
        let mid = value(blend.lanes, .a, .vocals, bar: 7.5)
        XCTAssertGreaterThan(mid, 0.1)
        XCTAssertLessThan(mid, 0.95)
        XCTAssertEqual(value(blend.lanes, .a, .vocals, bar: 8.01), 0)
    }

    /// Intro, verse, chorus, verse, chorus, outro; the second verse is
    /// what a club edit leaves out.
    private func popSong() -> TrackStructure {
        func section(_ b: Int) -> String {
            switch b {
            case 0..<8, 56..<64: return "intro"
            case 24..<32, 48..<56: return "chorus"
            default: return "verse"
            }
        }
        func per(_ intro: Float, _ verse: Float, _ chorus: Float) -> [Float] {
            (0..<64).map { section($0) == "intro" ? intro : section($0) == "chorus" ? chorus : verse }
        }
        func pitch(_ p: Int, _ q: Int) -> [Float] { (0..<12).map { $0 == p ? 1 : $0 == q ? 0.6 : 0.1 } }
        var s = TrackStructure(activity: ["drums": per(0.2, 0.9, 1), "bass": per(0.1, 0.2, 1),
                                          "other": per(0.6, 0.8, 1), "vocals": per(0, 0.7, 1)],
                               loudness: per(-20, -16, -10))
        s.barChroma = (0..<64).map { b in
            switch section(b) {
            case "intro": return pitch(0, 7)
            case "chorus": return pitch([5, 0, 7, 9][b % 4], [9, 4, 11, 1][b % 4])
            default: return pitch([9, 5, 0, 7][b % 4], [0, 9, 4, 11][b % 4])
            }
        }
        return s
    }

    /// A song that plays one major scale throughout, whatever its key was
    /// estimated as.
    private func song(scale tonic: Int, key: MusicalKey, bpm: Double = 120, bars: Int = 64) -> TrackAnalysis {
        let notes: [Float] = (0..<12).map { [0, 2, 4, 5, 7, 9, 11].contains(($0 - tonic + 12) % 12) ? 40 : 1 }
        var s = TrackStructure(activity: Dictionary(uniqueKeysWithValues: StemKind.allCases.map {
            ($0.rawValue, [Float](repeating: 1, count: bars))
        }), loudness: [Float](repeating: -10, count: bars))
        s.harmonyChroma = [[Float]](repeating: notes, count: bars)
        return TrackAnalysis(grid: BeatGrid(bpm: bpm, firstDownbeat: 0), key: key, duration: Double(bars) * 240 / bpm,
                             structure: s, version: TrackAnalysis.currentVersion)
    }

    /// Songs read at half and double time of each other don't share a bar
    /// grid, so they play as a Wash Out, and are priced as one: not as the
    /// perfect tempo match they are on paper.
    func testHalfTimePairIsPricedAsTheWashOutItPlaysAs() {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let a = song(scale: 0, key: c, bpm: 87), same = song(scale: 0, key: c, bpm: 87)
        let double = song(scale: 0, key: c, bpm: 174)
        let blend = PairPlan.make(a: a, b: same), wash = PairPlan.make(a: a, b: double)
        XCTAssertEqual(wash.preset, .echoOut)
        XCTAssertNotEqual(blend.preset, .echoOut)
        XCTAssertGreaterThan(wash.cost(a: a, b: double), blend.cost(a: a, b: same) + 1)
    }

    /// The set's last song fades out without undoing its way in: a part
    /// still held back where the fade begins stays out until its moment.
    func testEndFadeKeepsALateEntryHeldBack() {
        // B's vocal is let in at 20 s; the song's last eight bars begin at 16.
        var vocal = Envelope()
        vocal.insert(AutomationPoint(time: 20, value: 0, curve: .hold))
        vocal.insert(AutomationPoint(time: 20.001, value: 1))
        SetBuilder.fadeOut(&vocal, from: 16, to: 40)
        XCTAssertEqual(vocal.value(at: 5, default: 1), 0, "audible before its entry, over the song before")
        XCTAssertEqual(vocal.value(at: 18, default: 1), 0)
        XCTAssertEqual(vocal.value(at: 20.01, default: 1), 1, accuracy: 0.01)
        XCTAssertEqual(vocal.value(at: 40, default: 1), 0)
        // A part already playing fades from the start of those bars.
        var drums = Envelope()
        drums.insert(AutomationPoint(time: 2, value: 0, curve: .hold))
        drums.insert(AutomationPoint(time: 2.001, value: 1))
        SetBuilder.fadeOut(&drums, from: 16, to: 40)
        XCTAssertEqual(drums.value(at: 1, default: 1), 0)
        XCTAssertEqual(drums.value(at: 15, default: 1), 1)
        XCTAssertLessThan(drums.value(at: 30, default: 1), 1)
        XCTAssertEqual(drums.value(at: 40, default: 1), 0)
        // No automation at all: full level until the fade.
        var plain = Envelope()
        SetBuilder.fadeOut(&plain, from: 16, to: 40)
        XCTAssertEqual(plain.value(at: 0, default: 1), 1)
        XCTAssertEqual(plain.value(at: 40, default: 1), 0)
    }

    func testTwoSongsAreOrderedToo() {
        XCTAssertEqual(SetOrdering.order([[0, 5], [1, 0]]), [1, 0])
        XCTAssertEqual(SetOrdering.order([[0, 1], [5, 0]]), [0, 1])
    }

    /// Whether melodies swap, and whether B is pitched, is decided once,
    /// from the notes that overlap where the transition is placed: the
    /// plan, its price and what plays agree.
    func testNotesAtTheSpotDecideSwapAndShift() throws {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true), cSharp = MusicalKey(tonicPitchClass: 1, isMajor: true)
        let a = song(scale: 0, key: c)
        // A key estimate that's a little off (two fifths): the notes share
        // A's scale, so the melodies layer and B keeps its key.
        let misread = PairPlan.make(a: a, b: song(scale: 0, key: MusicalKey(tonicPitchClass: 2, isMajor: true)))
        XCTAssertFalse(misread.keysClash)
        XCTAssertEqual(misread.semitones, 0)
        // Keys far apart are believed over a stretch that happens to fit.
        XCTAssertEqual(Harmony.tolerance(c, cSharp), -.infinity)
        XCTAssertEqual(Harmony.tolerance(c, MusicalKey(tonicPitchClass: 9, isMajor: false)), Harmony.clashTolerance)
        XCTAssertEqual(Harmony.tolerance(c, MusicalKey(tonicPitchClass: 7, isMajor: true)), Harmony.clashTolerance)
        // The other way round: the estimates agree, the notes don't.
        let hidden = PairPlan.make(a: a, b: song(scale: 1, key: c))
        XCTAssertTrue(hidden.keysClash)
        XCTAssertEqual(hidden.semitones, 0, "no shift the key estimates didn't propose")

        // Really a semitone up: heard as a clash, fixed by B a semitone
        // down, or by A playing a semitone up itself.
        let off = song(scale: 1, key: cSharp)
        let sa = try XCTUnwrap(a.structure), sb = try XCTUnwrap(off.structure)
        func clash(aShift: Int = 0, bShift: Int = 0) throws -> Float {
            try XCTUnwrap(AutoPlacement.overlapClash(a: sa, aShift: aShift, entry: 16, b: sb, bShift: bShift, cue: 0,
                                                     preset: .stemSwap, bars: 16, lowSwap: 8))
        }
        XCTAssertGreaterThan(try clash(), 0.2)
        XCTAssertLessThan(try clash(bShift: -1), 0.01)
        XCTAssertLessThan(try clash(aShift: 1), 0.01)
        // Pitched or not, the plan says what will play.
        let plan = PairPlan.make(a: a, b: off)
        XCTAssertTrue(plan.semitones == 0 || plan.semitones == -1)
        XCTAssertEqual(plan.keysClash, plan.semitones == 0)
        XCTAssertFalse(PairPlan.make(a: a, b: off, aShift: 1).keysClash, "B is fitted to the key A is heard in")
    }

    /// Placement judges a blend's notes from the per-bar measurement, the
    /// builder from the audio: over the same bars the two hear the same
    /// (loud bars counting for more than quiet ones, the bass line in).
    func testPlacementHearsTheNotesTheBuilderDoes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sr = AudioIO.sampleRate, bars = 24, bar = 2.0
        let chords: [[Double]] = [[220, 261.6, 329.6], [174.6, 220, 261.6], [261.6, 329.6, 392], [196, 246.9, 293.7]]
        var melody = StereoBuffer(count: Int(Double(bars) * bar * sr)), bass = melody
        for i in 0..<melody.count {
            let t = Double(i) / sr, b = Int(t / bar)
            // Every third bar is a quiet one, in another chord.
            let level = b % 3 == 2 ? 0.02 : 0.2
            let chord = chords[b % 3 == 2 ? 3 : b % 3]
            melody.left[i] = Float(level * chord.reduce(0) { $0 + sin(2 * .pi * $1 * t) })
            melody.right[i] = melody.left[i]
            bass.left[i] = Float(0.3 * sin(2 * .pi * chord[0] / 2 * t))
            bass.right[i] = bass.left[i]
        }
        try StemAudio.save(melody, directory: dir, name: "other")
        try StemAudio.save(bass, directory: dir, name: "bass")
        let stems = [StemKind.other: try StemAudio.load(directory: dir, name: "other"),
                     .bass: try StemAudio.load(directory: dir, name: "bass")]
        let s = TrackStructure.measure(stems: stems, grid: BeatGrid(bpm: 120, firstDownbeat: 0))
        let planned = try XCTUnwrap(AutoPlacement.notes(s, bars: 4..<12))
        let heard = try XCTUnwrap(Harmony.chroma([stems[.other]!, stems[.bass]!], offset: 0, from: 4 * bar, to: 12 * bar))
        let sp = planned.reduce(0, +), sh = heard.reduce(0, +)
        for p in 0..<12 {
            XCTAssertEqual(planned[p] / sp, heard[p] / sh, accuracy: 0.01, "pitch class \(p)")
        }
        XCTAssertLessThan(Harmony.clash(planned, heard), 0.005)
        // The melody on its own, too.
        let alone = try XCTUnwrap(AutoPlacement.notes(s, bars: 4..<12, melodyOnly: true))
        let aloneHeard = try XCTUnwrap(Harmony.chroma([stems[.other]!], offset: 0, from: 4 * bar, to: 12 * bar))
        XCTAssertLessThan(Harmony.clash(alone, aloneHeard), 0.005)
        XCTAssertNotEqual(alone, planned)
    }

    /// Before the switch B's bass line is out: a bass line in A's key
    /// doesn't make B's melody, a semitone off, fit A's.
    func testASilentBassLineDoesNotVouchForItsMelody() throws {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let a = song(scale: 0, key: c)
        var b = song(scale: 0, key: c)
        let off = try XCTUnwrap(song(scale: 1, key: c).structure?.harmonyChroma)
        // B's melody plays C sharp major, quietly; its bass line C major, loudly.
        b.structure?.melodyChroma = off.map { $0.map { $0 / 10 } }
        let bassLine = try XCTUnwrap(b.structure?.harmonyChroma)
        b.structure?.harmonyChroma = zip(bassLine, off).map { loud, quiet in zip(loud, quiet).map { $0 + $1 / 10 } }
        let sa = try XCTUnwrap(a.structure), sb = try XCTUnwrap(b.structure)
        let whole = Harmony.clash(try XCTUnwrap(AutoPlacement.notes(sa, bars: 20..<28)),
                                  try XCTUnwrap(AutoPlacement.notes(sb, bars: 4..<12)))
        XCTAssertLessThan(whole, 0.04, "melody and bass line together look like A's key")
        let heard = try XCTUnwrap(AutoPlacement.overlapClash(a: sa, entry: 16, b: sb, cue: 0, preset: .stemSwap, bars: 16,
                                                             lowSwap: 12))
        XCTAssertGreaterThan(heard, 0.2)
        XCTAssertTrue(PairPlan.make(a: a, b: b).keysClash)
    }

    /// A short song isn't cued so far in that it's over as soon as it has
    /// the floor.
    func testAShortSongKeepsTimeOnItsOwn() {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let a = song(scale: 0, key: c)
        let plan = PairPlan.make(a: a, b: song(scale: 0, key: c, bars: 40))
        XCTAssertNotEqual(plan.preset, .echoOut)
        XCTAssertLessThanOrEqual(plan.placement.cueBar + plan.bars + SetBuilder.minimumSoloBars + 16, 40)
        // A song of ordinary length may still come in on a later phrase.
        XCTAssertLessThanOrEqual(PairPlan.make(a: a, b: song(scale: 0, key: c, bars: 96)).placement.cueBar, 43)
    }

    func testClubEditJumpsFromChorusToChorus() {
        let s = popSong()
        XCTAssertEqual(s.skip(from: 26, landingBy: 60), 28..<52, "mid-chorus to the same point of the next")
        // Nothing to leave out once the verse is behind.
        XCTAssertNil(s.skip(from: 50, landingBy: 60))
        // Leaving the verse out is what pacing wants.
        let through = AutoPlacement.pacing(s, from: 24, to: 56, barSeconds: 2)
        let edited = AutoPlacement.pacing(s, from: 24, to: 56, barSeconds: 2, skipping: 28..<52)
        XCTAssertGreaterThan(through, edited + 0.5)
    }

    /// A jump in the renderer: the stem carries on from the new place,
    /// with the seam faded so it doesn't click.
    func testJumpPlaysOnFromTheNewPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 60_000
        let ramp = (0..<n).map { Float($0) / 1_000_000 }
        try StemAudio.save(StereoBuffer(left: ramp, right: ramp), directory: dir, name: "x")
        let stem = try StemAudio.load(directory: dir, name: "x")
        let sr = AudioIO.sampleRate
        let jump = Roll(side: .a, stem: .other, start: 10_000 / sr, end: 60_000 / sr, anchor: 30_000 / sr,
                        length: 50_000 / sr)
        let snapshot = MixSnapshot(lanes: [.init(audio: stem, offset: 0, envelopes: Lane(side: .a, stem: .other).envelopes,
                                                  audible: true, rolls: [MixSnapshot.FrameRoll(jump, sampleRate: sr)!])],
                                   length: n, delaySeconds: 0.3, masterGain: 1)
        let renderer = MixRenderer(snapshot: snapshot)
        var l = [Float](repeating: 0, count: n), r = l
        renderer.render(left: &l, right: &r, count: n)
        XCTAssertEqual(l[9_000], ramp[9_000], accuracy: 1e-6)
        XCTAssertEqual(l[10_500], ramp[30_500], accuracy: 1e-6)
        XCTAssertEqual(l[25_000], ramp[45_000], accuracy: 1e-6)
        XCTAssertEqual(l[35_000], ramp[55_000], accuracy: 1e-6)
        XCTAssertEqual(l[45_000], 0, "past the end of the stem")
        let steps = (1..<30_000).map { abs(l[$0] - l[$0 - 1]) }
        XCTAssertLessThan(steps.max()!, 5e-4, "the seam clicks")
    }

    /// A short song between two blends: the way out starts once it's back
    /// at its own tempo, on one of its phrases, with a blend that fits what
    /// is left of it. (It used to be planned before that and then pushed a
    /// bar or more off its phrases, past the end of its music.)
    func testAShortSongLeavesOnAPhraseOnceItIsHome() {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let a = song(scale: 0, key: c, bars: 40), b = song(scale: 0, key: c)
        // Home at bar 23, so no room for eight bars alone and sixteen of blend.
        let plan = PairPlan.make(a: a, b: b, entryRange: 31...Int.max, soloFrom: 23)
        XCTAssertGreaterThanOrEqual(plan.placement.entryBar, 23)
        XCTAssertEqual(plan.placement.entryBar % 4, 0)
        XCTAssertLessThanOrEqual(plan.placement.entryBar + plan.bars, 40)
        XCTAssertFalse(plan.placement.overruns)
        // Nothing fits a song that is over as it comes home: said, and on a phrase.
        let late = PairPlan.make(a: a, b: b, entryRange: 46...Int.max, soloFrom: 38)
        XCTAssertTrue(late.placement.overruns)
        XCTAssertGreaterThanOrEqual(late.placement.entryBar, 38)
        XCTAssertEqual(late.placement.entryBar % 4, 0)
    }

    /// The set builder rolls into a drop only from a blend of sixteen bars:
    /// placement doesn't plan (and simulate) one for a shorter Stem Swap.
    func testNoDropIsPlannedForAShortStemSwap() {
        let s = popSong()
        let song = TrackAnalysis(grid: BeatGrid(bpm: 120, firstDownbeat: 0), key: MusicalKey(tonicPitchClass: 0, isMajor: true),
                                 duration: 128, structure: s, version: TrackAnalysis.currentVersion)
        for cue in [16, 20] {
            let long = AutoPlacement.place(a: song, b: song, bars: 16, preset: .stemSwap, at: (32, cue))
            let short = AutoPlacement.place(a: song, b: song, bars: 8, preset: .stemSwap, at: (32, cue))
            XCTAssertFalse(short.dropMoment)
            XCTAssertFalse(short.payoff.contains("roll into the drop"))
            XCTAssertEqual(long.entryBar, 32)
            XCTAssertEqual(long.cueBar, cue)
        }
    }

    /// What's left of a melody in a drums-only intro is separation bleed:
    /// no notes to clash with, for placement as for the builder.
    func testBleedIsNotANote() throws {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        var b = try XCTUnwrap(song(scale: 1, key: c).structure)
        XCTAssertNotNil(AutoPlacement.notes(b, bars: 0..<8))
        b.stemLevel = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0.rawValue, [Float](repeating: -65, count: 64)) })
        XCTAssertNil(AutoPlacement.notes(b, bars: 0..<8))
        b.stemLevel?[StemKind.other.rawValue] = [Float](repeating: -25, count: 64)
        XCTAssertNotNil(AutoPlacement.notes(b, bars: 0..<8))
    }

    /// A Wash Out never plays the two songs' notes together: no clash to
    /// swap melodies for, or to price.
    func testAWashOutHasNoNotesToClash() {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let a = song(scale: 0, key: c, bpm: 100), far = song(scale: 1, key: MusicalKey(tonicPitchClass: 1, isMajor: true), bpm: 125)
        let wash = PairPlan.make(a: a, b: far)
        XCTAssertEqual(wash.preset, .echoOut)
        XCTAssertFalse(wash.keysClash)
        XCTAssertEqual(wash.placement.notesClash, false)
    }

    /// A lock predicted from nothing isn't one.
    func testGrooveLockNeedsWindowsThatVote() {
        XCTAssertFalse(BeatAlign.Result(nudge: 0, lock: 1).clearlyGrooves)
        XCTAssertTrue(BeatAlign.Result(nudge: 0, lock: 1).grooves, "the builder still layers what it can't judge")
        XCTAssertTrue(BeatAlign.Result(nudge: 0, lock: 1, lockBefore: 0.9, votesBefore: 4).clearlyGrooves)
        // B's tops too sparse to say before the swap, both kits as one after it.
        XCTAssertTrue(BeatAlign.Result(nudge: 0, lock: 1, lockAfter: 1, votesBefore: 1, votesAfter: 3).clearlyGrooves)
        XCTAssertFalse(BeatAlign.Result(nudge: 0, lock: 1, lockAfter: 0.5, votesBefore: 0, votesAfter: 4).clearlyGrooves)
    }

    /// A spot, preset and length chosen by hand are planned where they were
    /// put: only what happens inside is worked out.
    func testAChosenSpotIsPlannedWhereItWasPut() {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let a = song(scale: 0, key: c), b = song(scale: 0, key: c)
        for (preset, bars) in [(TransitionPreset.dropSwap, 8), (.longBlend, 32), (.stemSwap, 4), (.echoOut, 8), (.stemSwap, 1)] {
            let chosen = TransitionEdit(entryBar: 37, cueBar: 3, preset: preset, bars: bars, semitones: 1, lanes: [],
                                        byHand: false)
            let plan = PairPlan.make(a: a, b: b, entryRange: 20...Int.max, soloFrom: 12, fixed: chosen)
            XCTAssertEqual(plan.preset, preset)
            XCTAssertEqual(plan.bars, bars)
            XCTAssertEqual(plan.placement.entryBar, 37)
            XCTAssertEqual(plan.placement.cueBar, 3)
            XCTAssertEqual(plan.semitones, 1)
        }
        // And past the end of both songs without falling over.
        let late = TransitionEdit(entryBar: 63, cueBar: 60, preset: .longBlend, bars: 32, semitones: 0, lanes: [], byHand: false)
        XCTAssertEqual(PairPlan.make(a: a, b: b, fixed: late).placement.entryBar, 63)
    }

    /// Saved edits from before the flag existed were drawn in the editor.
    func testOldEditsAreByHand() throws {
        let json = #"{"entryBar":4,"cueBar":0,"preset":"stemSwap","bars":16,"semitones":0,"lanes":[]}"#
        XCTAssertTrue(try JSONDecoder().decode(TransitionEdit.self, from: Data(json.utf8)).byHand)
    }

    /// Nothing of A sounds past the blend's end, where B starts gliding
    /// home: a mashup's switch on the last bar dissolves A's melody into it.
    func testAIsGoneByTheEndOfAMashup() {
        let lanes = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 16,
                                           vocalBar: 4, lowSwap: 16, mashup: true).lanes
        XCTAssertEqual(value(lanes, .a, .other, bar: 13.9), 1)
        XCTAssertLessThan(value(lanes, .a, .other, bar: 15.5), 0.2)
        for stem in StemKind.allCases { XCTAssertEqual(value(lanes, .a, stem, bar: 16.01), 0, "\(stem)") }
        XCTAssertEqual(value(lanes, .b, .other, bar: 15.9), 0)
        XCTAssertEqual(value(lanes, .b, .other, bar: 16.01), 1)
    }

    /// The half beat of silence before a drop ends with A gone, at any
    /// tempo (below 120 BPM A's beat used to open again for a few ms).
    func testNothingOfALeaksOutOfTheSilenceBeforeADrop() {
        for barSeconds in [1.6, 2.0, 2.8, 3.4] {
            let lanes = TransitionBuilder.make(.stemSwap, lanes: Lane.allLanes(), start: 10, barSeconds: barSeconds, bars: 16,
                                               lowSwap: 8, dropMoment: true).lanes
            for stem in [StemKind.drums, .bass] {
                let lane = lanes.first { $0.side == .a && $0.stem == stem }!
                for ms in [0.0, 0.5, 1, 2, 3, 5] {
                    XCTAssertEqual(lane.value(.volume, at: 10 + 8 * barSeconds + ms / 1000), 0, "\(stem) \(barSeconds) \(ms)")
                }
            }
            let b = lanes.first { $0.side == .b && $0.stem == .drums }!
            XCTAssertEqual(b.value(.volume, at: 10 + 8 * barSeconds + 0.006), 1)
        }
    }

    /// The exact search prices the whole set, not only its transitions: it
    /// finds what trying every order finds.
    func testExactOrderCountsWhatTheSetPaysFor() {
        var seed: UInt64 = 7
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        func permutations(_ x: [Int]) -> [[Int]] {
            x.count <= 1 ? [x] : x.indices.flatMap { i -> [[Int]] in
                var rest = x
                let head = rest.remove(at: i)
                return permutations(rest).map { [head] + $0 }
            }
        }
        for n in [4, 6, 7] {
            let costs = (0..<n).map { _ in (0..<n).map { _ in 3 * random() } }
            let washOuts = (0..<n).map { _ in (0..<n).map { _ in random() < 0.3 } }
            let energies = (0..<n).map { _ in random() }
            let found = SetOrdering.order(costs, washOuts: washOuts, energies: energies)
            XCTAssertEqual(Set(found), Set(0..<n))
            let best = permutations(Array(0..<n)).map { SetOrdering.total($0, costs, washOuts, energies) }.min()!
            XCTAssertEqual(SetOrdering.total(found, costs, washOuts, energies), best, accuracy: 1e-9)
        }
    }

    /// A song added to a set that has its order is fitted in; the others
    /// stay where they were.
    func testAnAddedSongIsFittedIn() {
        // 0 → 1 → 2 is the set; 3 belongs between 1 and 2.
        var costs = [[Double]](repeating: [Double](repeating: 5, count: 4), count: 4)
        costs[0][1] = 1; costs[1][2] = 1; costs[1][3] = 0.2; costs[3][2] = 0.2
        XCTAssertEqual(SetOrdering.insert([3], into: [0, 1, 2], costs), [0, 1, 3, 2])
        // Even where starting over would turn the set round.
        costs[2][1] = 0; costs[1][0] = 0
        XCTAssertEqual(SetOrdering.insert([3], into: [0, 1, 2], costs), [0, 1, 3, 2])
        // Larger sets: local search, still every song once.
        var seed: UInt64 = 3
        let big = (0..<16).map { _ in (0..<16).map { _ -> Double in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        } }
        XCTAssertEqual(Set(SetOrdering.order(big)), Set(0..<16))
    }

    /// A Wash Out's bridge comes in two lengths, and the plan says which.
    func testAWashOutPicksItsBridge() {
        let c = MusicalKey(tonicPitchClass: 0, isMajor: true)
        let plan = PairPlan.make(a: song(scale: 0, key: c, bpm: 100), b: song(scale: 0, key: c, bpm: 125))
        XCTAssertEqual(plan.preset, .echoOut)
        XCTAssertTrue([4, 8].contains(plan.bars))
        let lanes = TransitionBuilder.make(.echoOut, lanes: Lane.allLanes(), start: 0, barSeconds: 2, bars: 4).lanes
        XCTAssertEqual(value(lanes, .a, .drums, bar: -4.01), 1)
        XCTAssertEqual(value(lanes, .a, .drums, bar: -1.99), 0, accuracy: 0.01)
        XCTAssertEqual(value(lanes, .a, .other, bar: -0.5), 1)
        XCTAssertEqual(value(lanes, .b, .drums, bar: -0.01), 0)
        XCTAssertEqual(value(lanes, .b, .drums, bar: 0.01), 1)
    }

    /// Placement hears where B's voice really starts, not where its
    /// channel opens.
    func testPlacementHearsWhereTheVoiceStarts() {
        var s = popSong()
        s.stemLevel = ["vocals": [Float](repeating: -20, count: 64)]
        // Silent for the first eight bars, singing from the ninth.
        s.vocalBeatLevel = (0..<256).map { $0 < 32 ? -80 : -20 }
        XCTAssertEqual(AutoPlacement.vocalSounds(s, cue: 0, from: 4, limit: 16), 8)
        XCTAssertEqual(AutoPlacement.vocalSounds(s, cue: 0, from: 9.5, limit: 16), 9.5)
        XCTAssertEqual(AutoPlacement.vocalSounds(s, cue: 0, from: 2, limit: 6), 6, "not found by then: that's where it's taken to start")
    }
}
