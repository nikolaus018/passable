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
        XCTAssertTrue(Harmony.fits(scale(0), scale(7)), "neighbours on the key wheel")
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
}
