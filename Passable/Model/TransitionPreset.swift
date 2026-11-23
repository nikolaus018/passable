import Foundation

/// Ready-made stem choreographies. Each writes automation relative to the
/// moment B enters, measured in bars of the master (A) grid, so they land on
/// phrase boundaries whatever the tempo.
enum TransitionPreset: String, CaseIterable, Codable, Identifiable {
    case stemSwap, dropSwap, longBlend, mashup, echoOut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stemSwap: return "Stem Swap"
        case .dropSwap: return "Drop Swap"
        case .longBlend: return "Long Blend"
        case .mashup: return "Mashup"
        case .echoOut: return "Wash Out"
        }
    }

    var summary: String {
        switch self {
        case .stemSwap:
            return "B's drums and melody build in with their low end killed; kick and bass change hands on one downbeat (on B's drop if B is still building); A's vocal echoes out as B's vocal or low end takes over. Where the keys and grooves allow, B sings over A's beat early (a mashup); where B hits a hook or drop, A rolls into a half-beat of silence and B lands in full."
        case .dropSwap:
            return "A rides its build while B's drums creep in filtered; A's beat rolls into a half-beat of silence, then on B's drop everything flips at once and A's melody and vocal echo away."
        case .longBlend:
            return "A slow EQ blend: B's drums and melody come up with their low end killed, the lows and bass lines trade places mid-way, A filters out."
        case .mashup:
            return "A full club mashup: A's beat and groove ride underneath (or loop cleanly) while B's singer performs a full verse or hook on top, then B's bass and full instrumental slam in on the drop as A washes away. On clashing keys, A strips to a drum bed so B's vocal rides clean."
        case .echoOut:
            return "Two beats never play at once, so each song keeps its own tempo. At 1 bar it's a cut on the one (tempos too far apart to blend): A plays whole to its phrase end, its last beat echoes into half a beat of silence, and B lands whole on its downbeat. Longer, it's a bridge for a song with no steady beat (a live drummer): A's beat sinks away first and its melody and vocal float on into a reverb wash before B drops in."
        }
    }

    /// What a transition of this preset and length is called: a Wash Out
    /// one bar long is a cut.
    func name(bars: Int) -> String {
        self == .echoOut && bars <= 1 ? "Cut" : displayName
    }

    var defaultBars: Int {
        switch self {
        case .stemSwap: return 16
        case .dropSwap: return 8
        case .longBlend: return 32
        case .mashup: return 16
        case .echoOut: return 8
        }
    }
}

struct TransitionBuilder {
    /// Master-timeline seconds where B enters (bar 0 of the transition).
    let start: Double
    let barSeconds: Double
    let bars: Int
    /// Bar (from B's entry) where B's vocal comes in; nil = end of the blend.
    let vocalBar: Int?
    /// The keys don't fit: melodies are swapped, never layered.
    let keysClash: Bool
    /// Bar (from B's entry) where kick and bass change hands; nil = half-way.
    let lowSwap: Int?
    /// The two drum parts groove together, so B's can build in under A's.
    /// If not, A's beat plays on alone and B's comes in whole on the swap.
    let drumsLayer: Bool
    /// After the swap, A's drums play on under B's (thinning out) rather
    /// than stopping on it: only where the two kits groove there too.
    let drumsLinger: Bool
    /// Bars (from B's entry) where B's vocal is let in and A's taken out,
    /// placed between lines; nil = on the bar grid.
    let vocalIn: Double?, vocalOut: Double?
    /// B's vocal sings over A's beat from early in the blend (`vocalBar`
    /// may then be as early as a quarter in), not only from half-way.
    let mashup: Bool
    /// The switch is a drop (B's hook or a big lift of B): build into it
    /// with a roll and a moment of silence.
    let dropMoment: Bool
    /// Beat (0…3) of A's bar that carries its snare, which the roll
    /// repeats; nil: the backbeat, beat 2.
    let rollBeat: Int?
    /// Bars over which A's vocal blends out before it's gone, and B's
    /// blends in after it opens; 0 = a cut. Which is right depends on what
    /// the vocal is doing there: a cut is clean where a line has ended (or
    /// a word begins) and chops a word where it hasn't.
    let vocalOutFade: Double, vocalInFade: Double
    /// A's melody makes way before B's comes in (rather than layering
    /// with it until half-way or the switch), so A's beat and voice carry
    /// B's parts: for a B that would hardly be heard under all of A. What
    /// a DJ loops A's bare beat for; with stems, A's beat is already bare.
    let carry: Bool
    /// dB A's drums and melody give up (mid and high EQ) once B's melody is
    /// in, so B is heard as well as A rather than 10 dB under it: what a
    /// DJ does with the EQ, not the fader. Set from the two songs' levels
    /// there; 0 where B is already as loud.
    let room: Double
    /// dB B's melody is held down by while A's voice still sings, so it
    /// plays under the voice and not over it: a singer is what a crowd
    /// follows, and a new song's lead line at the same level is heard as
    /// a fight (and shows up every note that doesn't sit). It steps up to
    /// full as A's voice leaves. Set from the two songs' levels there.
    let under: Double
    /// Bar (from B's entry) from which A's voice is silent until it's taken
    /// out (its own pause before the cut): B's melody, held under it, steps
    /// up there rather than on the cut. nil: it sings up to the cut.
    let underUntil: Double?
    /// A's beat loops under the blend: from B's entry on, A's drums, bass
    /// line and melody repeat `loop` bars of themselves (those starting
    /// `loopBack` bars before the entry) instead of going where the song
    /// goes, so the blend plays over a steady bed whatever A does next (a
    /// verse, a breakdown, its ending). What a DJ sets a loop on the last
    /// bars of a chorus for. 0: A plays on.
    let loop: Int, loopBack: Int
    /// B's drums don't layer under A's whole (the two kits flam), but
    /// their hats sit with A's: B's hats alone come in from the first
    /// downbeat (a high-pass at `hatsFilter`), the rest of its kit on the
    /// swap. What a DJ does with the filter when two kicks and snares
    /// won't sit.
    let hats: Bool
    /// dB B's voice sings above A's where they change hands (as heard,
    /// each song at its set level; see `VocalPhrasing.step`). Two
    /// singers a few dB apart are heard as a jump in level the moment one
    /// takes over, which a DJ rides on the channel's trim: the louder of
    /// the two is met at the quieter one's level and eased back to its own
    /// over bars, slowly enough not to be heard as a fade. Only ever down
    /// (unity is the top of a volume lane).
    let voiceStep: Double
    /// Below this (dB) two voices sit level enough; past `voiceMatchMost`
    /// the difference is the songs' own, and only that much is taken off.
    static let voiceMatchLeast = 1.5, voiceMatchMost = 8.0
    /// The handover itself (A's last two bars, B's first two) is sung at
    /// the matched level; B's voice then eases back to its own over
    /// `voiceSettle` bars (by the blend's end, over no fewer than
    /// `voiceSettleLeast`), and A's eases down over `voiceYield` bars before.
    static let voiceHold = 2.0, voiceSettle = 8.0, voiceSettleLeast = 4.0, voiceYield = 4.0
    /// Linear gain a voice `step` dB louder than the other is met at.
    static func voiceMatch(_ step: Double) -> Double? {
        guard step >= voiceMatchLeast else { return nil }
        return pow(10, -min(step, voiceMatchMost) / 20)
    }
    /// The DJ filter that leaves a kit's hats and cymbals: a high-pass
    /// around 6 kHz.
    static let hatsFilter = 0.96
    /// How a `dropMoment` builds into the big switch: varied across a set so
    /// big drops stay fresh instead of repeating the same snare roll every time.
    enum BuildStyle: String, Codable, Equatable, CaseIterable {
        /// Classic 1-bar snare roll (1/8 → 1/16 → 1/32) into half a beat of silence.
        case snareRoll
        /// DJ loop-halving over two bars (1/2 bar → 1/4 → 1/8 → 1/16) into silence.
        case loopHalve
        /// Tension riser: high-pass + reverb swell without a stutter, into silence.
        case riser
        /// Bass-pull tension: A's bass & kick lows drop out two beats early into B's slam.
        case bassDrop
        /// A cappella break: A's instrumental drops out 1 bar early so the
        /// voice carries the tension solo into B's full drop.
        case acappellaBreak
        /// Fakeout drop (double drop misdirection): builds into the drop,
        /// strips ALL drums & bass for 1 bar so B's vocal + melody hang naked,
        /// then slams B's full drums & bass in one bar later.
        case fakeoutDrop
        /// Rhythmic fader-chop / stutter gate: syncopated 1/8th & 1/16th
        /// rhythmic gates over the final bar with resonant HPF sweep into the drop.
        case stutterGate
        /// 3/16th polyrhythmic roll: hypnotic off-kilter dotted-eighth groove
        /// loop across the final 1.5 bars that snaps back onto beat 1 of B's drop.
        case polyRoll
        /// 1-beat turntable spinback right before B's drop slams in (gated by
        /// `.turntable` and used only when A's vocal has already exited).
        case spinbackDrop
        /// 2-beat vinyl brake deceleration into B's drop (gated by `.turntable`
        /// and used only when A's vocal has already exited).
        case brakeDrop
        /// Fred again.. / James Hype vocal-chop stutter build: loops a vocal
        /// word/syllable (A's last word or B's upcoming hook) at 1/4 → 1/8 →
        /// 1/16 → 1/32 through a rising HPF + ping-pong delay into B's drop.
        case vocalChop
        /// Back-and-forth beat juggle: trades full-bass bars/beats between A
        /// and B over the final 2 bars into a snare acceleration and B's drop.
        case beatJuggle
        /// Pioneer RMX-1000 spiral echo freeze: floods A into ping-pong delay
        /// and cathedral reverb then cuts dry A half a bar early so only the
        /// spiraling stereo tail hangs in the air before B's drop slams in.
        case echoFreeze
        /// Underwater submarine low-pass slam: dives the mix down into a
        /// resonant ~330 Hz low-pass for 1.5 bars, breathes for half a beat,
        /// then snaps wide open on beat 1 of B's drop.
        case filterSlam
    }

    /// Style of build-up for `dropMoment` (default `.snareRoll`).
    let buildStyle: BuildStyle
    /// Bar (from B's entry) where the last sung word of A's vocal starts,
    /// so `echoOutVocal` throws only that word into the delay instead of
    /// smearing a whole bar of lyrics. nil: fall back to the 1-bar ramp.
    let vocalThrowStart: Double?
    /// dB A's melody is pocketed under B's vocal during a mashup.
    let mashupUnder: Double
    /// Delay send level for A's vocal echo-out (lowered when A already ends into
    /// a long natural pause so it doesn't blast an artificial echo on silence).
    let vocalSend: Double
    /// Vinyl brake / tape-stop spin-down on a 1-bar Cut instead of an echo cut.
    let vinylBrake: Bool
    /// Turntable spinback / backspin on a 1-bar Cut instead of an echo cut.
    let spinback: Bool
    /// Beatless a cappella tempo-bridge on a singing 1-bar Cut: kills A's
    /// drums & bass 2 bars early so A's isolated voice floats into reverb/echo
    /// before B slams in at its own tempo.
    let acapellaBridge: Bool
    /// Early vocal tease ("ghost hook"): plays `duration` bars of B's vocal
    /// from bar `from` at bar `at` (4 bars before the drop) through a radio HPF + echo.
    let vocalTease: (at: Double, from: Double, duration: Double)?
    /// B's melody is too quiet to take over from A's before the switch: A's
    /// plays on and dissolves over the last bar or two before it.
    let holdMelody: Bool
    /// Source word/syllable (deck + bar offset from B's entry) to stutter-chop
    /// during `BuildStyle.vocalChop`. nil falls back to A's vocal at `s - 1`.
    let vocalChop: (side: DeckSide, anchor: Double)?
    /// Where A's vocal ended up leaving and B's coming in (bars from B's
    /// entry), for the caller to check against the audio.
    private(set) var vocalExit: Double?, vocalEntry: Double?
    private(set) var lanes: [Lane]
    private(set) var rolls: [Roll] = []
    /// Stretches (bars from B's entry) where a stem stops dead, written
    /// last so they cut through whatever else the lane does there.
    private var silences: [(DeckSide, StemKind, Double, Double)] = []

    init(lanes: [Lane], start: Double, barSeconds: Double, bars: Int, vocalBar: Int? = nil, keysClash: Bool = false,
         lowSwap: Int? = nil, drumsLayer: Bool = true, drumsLinger: Bool = true, vocalIn: Double? = nil,
         vocalOut: Double? = nil, mashup: Bool = false, dropMoment: Bool = false, rollBeat: Int? = nil,
         vocalOutFade: Double = 0, vocalInFade: Double = 0, room: Double = 0, carry: Bool = false, under: Double = 0,
         loop: Int = 0, loopBack: Int = 0, hats: Bool = false, voiceStep: Double = 0, underUntil: Double? = nil,
         buildStyle: BuildStyle = .snareRoll, vocalThrowStart: Double? = nil, mashupUnder: Double = 0,
         vocalSend: Double = 0.78, vinylBrake: Bool = false, spinback: Bool = false,
         acapellaBridge: Bool = false, vocalTease: (at: Double, from: Double, duration: Double)? = nil,
         holdMelody: Bool = false, vocalChop: (side: DeckSide, anchor: Double)? = nil) {
        self.buildStyle = buildStyle
        self.vocalThrowStart = vocalThrowStart
        self.mashupUnder = mashupUnder
        self.vocalSend = vocalSend
        self.vinylBrake = vinylBrake
        self.spinback = spinback && !vinylBrake
        self.acapellaBridge = acapellaBridge && !vinylBrake && !spinback
        self.vocalTease = vocalTease
        self.holdMelody = holdMelody
        self.vocalChop = vocalChop
        self.underUntil = underUntil
        self.hats = hats
        self.voiceStep = voiceStep
        self.loop = loop
        self.loopBack = max(loop, loopBack)
        self.room = room
        self.under = under
        self.carry = carry
        self.vocalOutFade = vocalOutFade
        self.vocalInFade = vocalInFade
        self.mashup = mashup
        self.rollBeat = rollBeat
        self.dropMoment = dropMoment
        self.lowSwap = lowSwap
        self.drumsLayer = drumsLayer
        self.drumsLinger = drumsLinger
        self.vocalIn = vocalIn
        self.vocalOut = vocalOut
        self.lanes = lanes
        self.start = start
        self.barSeconds = barSeconds
        self.bars = bars
        self.vocalBar = vocalBar
        self.keysClash = keysClash
    }

    static func build(_ preset: TransitionPreset, lanes: [Lane], start: Double, barSeconds: Double, bars: Int,
                      vocalBar: Int? = nil, keysClash: Bool = false, lowSwap: Int? = nil,
                      drumsLayer: Bool = true, drumsLinger: Bool = true, vocalIn: Double? = nil, vocalOut: Double? = nil,
                      mashup: Bool = false, dropMoment: Bool = false, room: Double = 0, carry: Bool = false,
                      under: Double = 0, loop: Int = 0, loopBack: Int = 0, hats: Bool = false,
                      buildStyle: BuildStyle = .snareRoll, vocalThrowStart: Double? = nil,
                      mashupUnder: Double = 0, vocalSend: Double = 0.78, vinylBrake: Bool = false,
                      spinback: Bool = false, acapellaBridge: Bool = false,
                      vocalTease: (at: Double, from: Double, duration: Double)? = nil,
                      holdMelody: Bool = false, vocalChop: (side: DeckSide, anchor: Double)? = nil) -> [Lane] {
        make(preset, lanes: lanes, start: start, barSeconds: barSeconds, bars: bars, vocalBar: vocalBar,
             keysClash: keysClash, lowSwap: lowSwap, drumsLayer: drumsLayer, drumsLinger: drumsLinger,
             vocalIn: vocalIn, vocalOut: vocalOut,
             mashup: mashup, dropMoment: dropMoment, room: room, carry: carry, under: under,
             loop: loop, loopBack: loopBack, hats: hats, buildStyle: buildStyle,
             vocalThrowStart: vocalThrowStart, mashupUnder: mashupUnder,
             vocalSend: vocalSend, vinylBrake: vinylBrake, spinback: spinback,
             acapellaBridge: acapellaBridge, vocalTease: vocalTease, holdMelody: holdMelody,
             vocalChop: vocalChop).lanes
    }

    /// The automation and the beat rolls of a preset.
    static func make(_ preset: TransitionPreset, lanes: [Lane], start: Double, barSeconds: Double, bars: Int,
                     vocalBar: Int? = nil, keysClash: Bool = false, lowSwap: Int? = nil,
                     drumsLayer: Bool = true, drumsLinger: Bool = true, vocalIn: Double? = nil,
                     vocalOut: Double? = nil, mashup: Bool = false, dropMoment: Bool = false, rollBeat: Int? = nil,
                     vocalOutFade: Double = 0, vocalInFade: Double = 0, room: Double = 0, carry: Bool = false,
                     under: Double = 0, loop: Int = 0, loopBack: Int = 0, hats: Bool = false,
                     voiceStep: Double = 0, underUntil: Double? = nil, buildStyle: BuildStyle = .snareRoll,
                     vocalThrowStart: Double? = nil, mashupUnder: Double = 0, vocalSend: Double = 0.78,
                     vinylBrake: Bool = false, spinback: Bool = false, acapellaBridge: Bool = false,
                     vocalTease: (at: Double, from: Double, duration: Double)? = nil, holdMelody: Bool = false,
                     vocalChop: (side: DeckSide, anchor: Double)? = nil) -> Made {
        var builder = TransitionBuilder(lanes: lanes, start: start, barSeconds: barSeconds, bars: bars,
                                        vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap,
                                        drumsLayer: drumsLayer, drumsLinger: drumsLinger,
                                        vocalIn: vocalIn, vocalOut: vocalOut,
                                        mashup: mashup, dropMoment: dropMoment, rollBeat: rollBeat,
                                        vocalOutFade: vocalOutFade, vocalInFade: vocalInFade, room: room, carry: carry,
                                        under: under, loop: (preset == .stemSwap || preset == .mashup) ? loop : 0, loopBack: loopBack,
                                        hats: hats && !drumsLayer, voiceStep: voiceStep,
                                        underUntil: underUntil, buildStyle: buildStyle,
                                        vocalThrowStart: vocalThrowStart, mashupUnder: mashupUnder,
                                        vocalSend: vocalSend, vinylBrake: vinylBrake, spinback: spinback,
                                        acapellaBridge: acapellaBridge, vocalTease: vocalTease,
                                        holdMelody: holdMelody, vocalChop: vocalChop)
        builder.clearAll()
        builder.write(preset)
        builder.writeLoop()
        builder.writeVocalTease()
        builder.oneThrowAtATime()
        for (side, stem, from, to) in builder.silences { builder.silence(side, stem, from: from, to: to) }
        builder.switchBeforeTheBeat()
        return Made(lanes: builder.lanes, rolls: builder.rolls, vocalExit: builder.vocalExit,
                    vocalEntry: builder.vocalEntry)
    }

    struct Made {
        var lanes: [Lane]
        var rolls: [Roll]
        /// Bars (from B's entry) where A's vocal is gone and B's opens.
        var vocalExit: Double?, vocalEntry: Double?
    }

    /// Bars (from B's entry) where a mashup lets B's vocal in at the
    /// earliest, and where it must be in by.
    static func mashupWindow(bars n: Int) -> (earliest: Double, latest: Double) {
        (Double(n) / 4, Double(n) / 2)
    }

    /// Bar (from B's entry) where B takes over: kick and bass change hands
    /// (a Stem Swap's low swap, half-way or where A's own low end left; a
    /// Drop Swap's drop; a Long Blend's half-way), or 0 for a Wash Out,
    /// which drops B's beat on its first bar. The planner, placement and
    /// the builder all ask here, so they never disagree.
    static func switchBar(_ preset: TransitionPreset, bars: Int, lowSwap: Int?) -> Double {
        let n = Double(bars)
        switch preset {
        case .echoOut: return 0
        case .dropSwap, .longBlend: return n / 2
        case .mashup: return min(n, max(n / 2, Double(lowSwap ?? bars / 2)))
        case .stemSwap: return min(n, max(1, Double(lowSwap ?? bars / 2)))
        }
    }

    /// Bar (from B's entry) where A's melody starts to dissolve (over two
    /// bars) under B's where the two layer: at the switch, or past half-way
    /// only where B is still building up to a late one (A's beat and bass
    /// carry it there, not two melodies), and never before B's has been in
    /// for two bars. A Drop Swap's goes on its drop.
    /// In a mashup B's melody waits for the switch, so A's goes there (two
    /// bars before a switch on the blend's last bar: nothing of A's sounds
    /// past the end).
    /// Carried (see `carry`), A's closes down over the bar before B's
    /// comes in a quarter in and is gone a bar after: A's melody low-passed
    /// as B's opens up high-passed, the swap a DJ makes with the filters.
    /// (Gone as B's came in, as this was, the blend went two bars with
    /// neither melody: the deepest dips of a 117-song set, 6 to 10 dB, at
    /// bar 3 of a 16-bar blend.)
    static func melodyDissolve(_ preset: TransitionPreset, bars: Int, switchAt sw: Double, mashup: Bool = false,
                               carry: Bool = false) -> Double {
        if preset == .mashup { return min(sw, max(Double(bars) / 4, Double(bars) - 2)) }
        guard preset == .stemSwap else { return sw }
        let n = Double(bars), q = n / 4
        if mashup { return min(sw, max(q, n - 2)) }
        if carry { return q }
        if bars < 8 { return min(sw, max(q, n - 2)) }
        return min(max(sw, q + 2), max(q + 2, 2 * q))
    }

    /// Seconds before its downbeat a loop turns round: the seam's
    /// crossfade (see `MixRenderer.loopCrossfade`) is over before the kick
    /// on the one, which plays whole.
    static let loopLead = 0.012

    /// A's drums, bass line and melody loop from B's entry until they're
    /// out (see `loop`). The voice isn't looped: it has left.
    private mutating func writeLoop() {
        guard loop > 0 else { return }
        let from = start - Self.loopLead
        for stem in [StemKind.drums, .bass, .other] {
            rolls.append(Roll(side: .a, stem: stem, start: from, end: start + Double(bars + 4) * barSeconds,
                              anchor: from - Double(loopBack) * barSeconds, length: Double(loop) * barSeconds,
                              seamless: true))
        }
    }

    /// Ghost-hook vocal tease: previews a word-aligned slice of B's upcoming
    /// hook 4 bars early through a radio high-pass + lush ping-pong echo over
    /// A's beat, then resets cleanly before B's real vocal arrives.
    private mutating func writeVocalTease() {
        guard let tease = vocalTease, let vin = vocalEntry else { return }
        let dur = max(0.25, min(0.75, tease.duration))
        guard tease.at >= 0.5, tease.at + dur + 0.5 < vin else { return }
        rolls.append(Roll(side: .b, stem: .vocals,
                          start: start + tease.at * barSeconds,
                          end: start + (tease.at + dur) * barSeconds,
                          anchor: start + tease.from * barSeconds,
                          length: dur * barSeconds))
        automate(.b, .vocals, .volume, [
            (tease.at, 0, .sCurve), (tease.at + 0.03, 0.90, .linear),
            (tease.at + dur - 0.04, 0.90, .sCurve), (tease.at + dur, 0, .linear),
        ])
        automate(.b, .vocals, .filter, [
            (tease.at - 0.05, 0.72, .linear), (tease.at + dur + 0.05, 0.72, .sCurve),
            (tease.at + dur + 0.25, 0.5, .linear),
        ])
        automate(.b, .vocals, .delay, [
            (tease.at, 0, .sCurve), (tease.at + 0.04, 0.80, .linear),
            (tease.at + dur, 0.80, .sCurve), (tease.at + dur + 0.5, 0, .linear),
        ])
        automate(.b, .vocals, .reverb, [
            (tease.at, 0, .sCurve), (tease.at + 0.04, 0.52, .linear),
            (tease.at + dur, 0.52, .sCurve), (tease.at + dur + 0.5, 0, .linear),
        ])
    }

    /// Where A's own drums stop inside the blend (its breakdown, a break)
    /// while B's beat isn't playing yet: bars (from B's entry) `from..<to`
    /// that A's `length` bars of full beat from bar `source` loop over, so the
    /// floor never goes without a kick. What a DJ does with the loop button
    /// when the outgoing record drops into its breakdown early. nil: no
    /// such gap (or one too short to matter, under a bar).
    /// - Parameter a: A's structure as it plays (its bars from `entry`).
    /// - Parameter b: B's, as counted in the blend's bars (from `cue`).
    /// - Parameter bDrumsFrom: bar B's drums are let in from (its own may
    ///   still be silent there: an intro).
    static func drumBridge(a: TrackStructure, entry e: Int, b: TrackStructure?, cue c: Int, bars n: Int,
                           bDrumsFrom: Double, until end: Double) -> (from: Int, to: Int, source: Int, length: Int)? {
        func aBeat(_ k: Int) -> Bool { a.activity(.drums).indices.contains(e + k) && a.activity(.drums)[e + k] > TrackStructure.threshold }
        func bBeat(_ k: Int) -> Bool {
            Double(k) >= bDrumsFrom && (b.map { s in s.activity(.drums).indices.contains(c + k) && s.activity(.drums)[c + k] > TrackStructure.threshold } ?? false)
        }
        let last = min(n, Int(end.rounded(.up)))
        // (From the second bar: A's own beat in the blend's first is what
        // the loop is made of.)
        guard let from = (1..<max(1, last)).first(where: { !aBeat($0) && !bBeat($0) }), aBeat(from - 1) else { return nil }
        var to = from
        while to < last, !aBeat(to), !bBeat(to) { to += 1 }
        guard to > from else { return nil }
        // Looped: A's last bars of beat at full (within 6 dB of what its
        // kit plays at), a phrase of them if there are, else a bar; from
        // up to a phrase before the blend. (A bar already half into the
        // break, looped, brought the beat back 14 dB down.)
        guard let levels = a.stemLevel?[StemKind.drums.rawValue], !levels.isEmpty else { return nil }
        let loud = levels.filter { $0 > -80 }.sorted()
        guard !loud.isEmpty else { return nil }
        let full = loud[(loud.count - 1) * 9 / 10] - 6
        func aFull(_ k: Int) -> Bool { levels.indices.contains(e + k) && levels[e + k] >= full }
        guard let lastFull = stride(from: from - 1, through: -4, by: -1).first(where: aFull) else { return nil }
        let run = (1...4).reversed().first { k in (lastFull - k + 1...lastFull).allSatisfy(aFull) } ?? 1
        return (from, to, lastFull + 1 - run, run)
    }

    /// Bars within which two effect throws (an echo or reverb send opened
    /// and closed again) count as at once.
    static let throwSpacing = 1.5

    /// One throw per effect bus at a time: two delays or two reverbs landing on
    /// the same swap blur into mud, so on each bus the highest-priority stem
    /// wins (`vocals > drums > other > bass`). Delay and reverb stay independent
    /// so a vocal echo never wipes out a complementary melody reverb wash or
    /// riser swell.
    private mutating func oneThrowAtATime() {
        struct Throw { let lane: Int, parameter: LaneParameter, from: Double, to: Double, peak: Double, rank: Int }
        let stemRank: [StemKind] = [.vocals, .drums, .other, .bass]
        for parameter in [LaneParameter.delay, .reverb] {
            var all: [Throw] = []
            for (i, lane) in lanes.enumerated() {
                let points = lane[parameter].points
                guard let rank = stemRank.firstIndex(of: lane.stem) else { continue }
                var k = 0
                while k < points.count {
                    guard points[k].value > 0.001 else { k += 1; continue }
                    let first = max(0, k - 1)
                    var last = k, peak = k
                    while last < points.count && points[last].value > 0.001 {
                        if points[last].value > points[peak].value { peak = last }
                        last += 1
                    }
                    let end = min(last, points.count - 1)
                    all.append(Throw(lane: i, parameter: parameter, from: points[first].time, to: points[end].time,
                                     peak: points[peak].time, rank: rank * 2 + (lane.side == .a ? 0 : 1)))
                    k = last + 1
                }
            }
            var kept: [Throw] = []
            for t in all.sorted(by: { $0.rank < $1.rank }) {
                if kept.contains(where: { abs($0.peak - t.peak) < Self.throwSpacing * barSeconds }) {
                    lanes[t.lane][t.parameter].clear(t.from...t.to)
                } else {
                    kept.append(t)
                }
            }
        }
    }

    /// Bars over which a melody closes before a clashing swap, and the
    /// next one opens after it.
    static let clashSweep = 2.0

    /// Seconds ahead of the beat that a part is switched on or off.
    static let switchLead = 0.025
    /// Seconds a switch takes: a part cut in or out, a filter or an EQ band
    /// snapped open or shut. In one step (a millisecond or two), whatever
    /// the part was sounding is chopped mid-wave, which puts a tick on the
    /// mix: measured over a 59-song set (`passable-render --clicks`), half
    /// the transitions had a switch whose splatter came within 20 dB of the
    /// whole mix in its band, one in five within 10, nearly all on the swap
    /// (a kick's tail, a bass note, a voice's low end switched as it rang).
    /// Eight milliseconds is still a cut to the ear, and done ahead of the
    /// beat like every switch.
    static let switchRamp = 0.008
    /// Seconds a bass line or a low band is switched over: low notes ring
    /// through the beat, and a 50 Hz wave or 6th-order resonant low isolator
    /// switched in under a period clicks.
    static let lowRamp = 0.018
    /// Seconds a melody stem's volume is closed over: pure synth/lead tones
    /// cut during a bass-silent build bar need ~24 ms to stay click-free.
    static let melodyRamp = 0.024
    /// Seconds A's voice is closed over as it's taken out. Shut in a
    /// millisecond, whatever still rang there (a word's tail, its reverb,
    /// the stem's bleed) was chopped into a click; over 30 ms it's still a
    /// cut to the ear.
    static let vocalRelease = 0.03

    /// A part switched on or off on a beat is switched `switchLead` ahead
    /// of it. The grid puts a beat where its kick peaks, and a hit starts
    /// some milliseconds before its peak (measured over a set: a median of
    /// 6 ms, up to 20), so a part opened on the beat lost the start of its
    /// first hit (a weak, clicky first kick on the swap), and one closed on
    /// the beat let the first milliseconds of its next hit through (a click
    /// that flams the swap). Ahead of the beat sits the tail of the last
    /// hit, where a switch isn't heard.
    ///
    /// And every switch, on the beat or off it (a voice let in on a
    /// breath), is a ramp of `switchRamp` that ends where the switch is
    /// due, never a step: see `switchRamp`.
    private mutating func switchBeforeTheBeat() {
        let lead = Self.switchLead
        let tiny = max(0.0025, 0.0015 * barSeconds + 1e-6)
        func onGrid(_ time: Double) -> Bool { self.onGrid(time, within: 0.003) }
        for i in lanes.indices {
            // Where the lane's fader shuts (the moment it's shut by) and
            // opens (the moment it starts to): a filter or an EQ band
            // switched with it is switched while the lane is silent, after
            // the one and before the other. Swept in the same milliseconds
            // as the fader moves, a low-pass let the highs it had been
            // holding back through for an instant as the part left.
            var shut: [Double] = [], opens: [Double] = []
            for parameter in [LaneParameter.volume, .filter, .low, .mid, .high, .reverb, .delay] {
                var points = lanes[i][parameter].points
                var moved = false
                let baseLength = (lanes[i].stem == .bass || parameter == .low || (lanes[i].stem == .other && parameter == .volume))
                    ? Self.lowRamp : Self.switchRamp
                // (A send snapped open or shut chops what goes into the
                // effect, and an echo repeats the tick it's given. It's
                // ramped where it's due: a throw is timed to what it throws.)
                let send = parameter == .reverb || parameter == .delay
                var k = 1
                while k < points.count {
                    defer { k += 1 }
                    guard abs(points[k].value - points[k - 1].value) > 0.05 else { continue }
                    let length = (lanes[i].stem == .other && parameter == .volume && points[k].value < 0.001)
                        ? Self.melodyRamp : baseLength
                    let ramp = points[k].time - points[k - 1].time <= tiny
                    let held = points[k - 1].curve == .hold
                    guard ramp || held else { continue }
                    // Where the step is heard: a short ramp from its first
                    // point, a held value at the point it jumps to.
                    let at = ramp ? points[k - 1].time : points[k].time
                    // Where it's done by: ahead of the beat it's on.
                    var done = onGrid(at) && !send ? at - lead : at
                    let floor = ramp ? (k >= 2 ? points[k - 2].time + 1e-6 : -Double.infinity) : points[k - 1].time + 1e-6
                    let ceiling = k + 1 < points.count ? points[k + 1].time - 1e-6 : Double.infinity
                    if parameter != .volume, !send {
                        if let silent = shut.first(where: { abs($0 - done) < 0.03 }), silent + length < ceiling {
                            done = silent + length
                        } else if let open = opens.first(where: { abs($0 - done) < 0.03 }), open - length > floor {
                            done = open
                        }
                    }
                    guard done - length > floor else { continue }
                    if parameter == .volume {
                        if points[k].value < 0.001 { shut.append(done) }
                        if points[k - 1].value < 0.001 { opens.append(done - length) }
                    }
                    if ramp {
                        points[k - 1].time = done - length
                        points[k - 1].curve = .sCurve
                        points[k].time = done
                    } else {
                        points[k].time = done
                        // The value held up to the ramp, then the ramp.
                        points.insert(AutomationPoint(time: done - length, value: points[k - 1].value, curve: .sCurve), at: k)
                        k += 1
                    }
                    moved = true
                }
                guard moved else { continue }
                lanes[i][parameter].removeAll()
                for p in points { lanes[i][parameter].insert(p) }
            }
        }
    }

    /// Whether master `time` is on a sixteenth of the blend, give or take
    /// `within` seconds.
    private func onGrid(_ time: Double, within: Double) -> Bool {
        let sixteenths = (time - start) / barSeconds * 16
        return abs(sixteenths - sixteenths.rounded()) * barSeconds / 16 < within
    }

    private mutating func clearAll() {
        for i in lanes.indices {
            for p in LaneParameter.allCases { lanes[i][p].removeAll() }
        }
    }

    /// Writes `points` (bar, value, curve-leaving-this-point) on one lane.
    private mutating func automate(_ side: DeckSide, _ stem: StemKind, _ parameter: LaneParameter,
                                   _ points: [(Double, Double, CurveShape)]) {
        guard let i = lanes.firstIndex(where: { $0.side == side && $0.stem == stem }) else { return }
        for (bar, value, curve) in points {
            lanes[i][parameter].insert(AutomationPoint(time: start + bar * barSeconds, value: value, curve: curve))
        }
    }

    /// B's vocal comes in at bar `vin`, all at once: a DJ opens a vocal
    /// on the beat, never fades it up (that's what makes a blend sound like
    /// a crossfade). `vin` is the breath before a line or, failing that,
    /// the attack of a word.
    private mutating func bringInVocal(at vin: Double) {
        vocalEntry = vin
        if vocalInFade > 0 {
            automate(.b, .vocals, .volume, [(vin, 0, .sCurve), (vin + vocalInFade, 1, .linear)])
        } else if let g = Self.voiceMatch(voiceStep) {
            // (Back by the blend's end where there are four bars for it:
            // still easing past it, B was heard held back once it played
            // on its own.)
            let settle = min(Self.voiceSettle, max(Self.voiceSettleLeast, Double(bars) - vin - Self.voiceHold))
            automate(.b, .vocals, .volume, [(vin, 0, .hold), (vin + 0.001, g, .linear), (vin + Self.voiceHold, g, .sCurve),
                                            (vin + Self.voiceHold + settle, 1, .linear)])
        } else {
            automate(.b, .vocals, .volume, [(vin, 0, .hold), (vin + 0.001, 1, .linear)])
        }
    }

    /// A part of B comes in whole on the downbeat of bar `at`, and a
    /// filter (from `filter`) opens it up by bar `open`: a DJ brings a part
    /// in with the filter, never the fader, which is what makes a blend
    /// sound like a crossfade.
    /// - Parameter level: the fader it comes in at (1: whole).
    private mutating func bringIn(_ stem: StemKind, at: Double, filter: Double, open: Double, level: Double = 1) {
        automate(.b, stem, .volume, [(at, 0, .hold), (at + 0.001, level, .linear)])
        automate(.b, stem, .filter, [(at, filter, .sCurve), (open, 0.5, .linear)])
    }

    /// A's melody from bar `at` on: a deep low-pass sweep and smooth S-curve
    /// fade into a blooming reverb wash over two bars under B. Reverb peaks
    /// while the melody still has full body so the post-fader send feeds a
    /// genuine tail instead of fading into silence first.
    private mutating func dissolveMelody(from at: Double, over span: Double = 2) {
        automate(.a, .other, .filter, [(at, 0.5, .sCurve), (at + span, 0.14, .linear)])
        automate(.a, .other, .reverb, [(at - 0.25 * span, 0, .sCurve), (at + 0.0625 * span, 0.72, .linear),
                                       (at + 0.625 * span, 0.80, .sCurve), (at + 1.125 * span, 0, .linear)])
        automate(.a, .other, .volume, [(at, 1, .sCurve), (at + span, 0, .linear)])
    }

    /// A's drums (and melody, where the keys let B's layer) turn their mids
    /// and highs down by `room` dB over the beat before bar `at`, as B's
    /// melody comes in: a DJ's EQ making space for the incoming song. The
    /// cut stays while A's parts leave (lifting it on the switch pushed A
    /// back up just as B's beat landed) and resets once they're gone.
    private mutating func makeRoom(at: Double, until: Double, melody: Bool) {
        guard room > 0.25, at > 0, until > at else { return }
        let cut = 0.5 - min(room, 12) / 80
        let reset = Double(bars) + 4
        for stem in melody ? [StemKind.drums, .other] : [.drums] {
            for band in [LaneParameter.mid, .high] {
                automate(.a, stem, band, [(at - 0.25, 0.5, .sCurve), (at, cut, .hold), (reset, 0.5, .hold)])
            }
        }
    }

    /// The low end has one owner, voices included: a DJ's low knob works
    /// on the whole channel, and a deep voice carries as much under 150 Hz
    /// as a bass line's upper notes. B's vocal is low-cut until bar `at`,
    /// A's from then on.
    private mutating func handOverVocalLows(at: Double) {
        automate(.b, .vocals, .low, [(at, 0, .hold), (at + 0.001, 0.5, .linear)])
        if at < Double(bars) {
            automate(.a, .vocals, .low, [(at, 0.5, .hold), (at + 0.001, 0, .linear)])
        }
    }

    /// A's vocal is gone at bar `out`: its last words are thrown into the
    /// echo, and the channel cuts there (or blends out over the bars
    /// before, if it's still singing), so the echo carries it away.
    private mutating func echoOutVocal(at out: Double, send: Double = 0.8, tail: Double = 1, reverb: Double = 0) {
        vocalExit = out
        // If we know where A's last sung word begins, open the echo right on
        // that word instead of smearing a whole bar of lyrics into the delay.
        if let wordStart = vocalThrowStart, wordStart < out - 0.05, wordStart >= out - 1.0 {
            let lead = max(out - 1.0, wordStart - 0.04)
            automate(.a, .vocals, .delay, [(lead, 0, .sCurve), (wordStart, send, .linear),
                                           (out, send, .linear), (out + tail, 0, .linear)])
            if reverb > 0.01 {
                automate(.a, .vocals, .reverb, [(lead, 0, .sCurve), (wordStart, reverb, .linear),
                                                (out, reverb, .linear), (out + min(tail, 0.75), 0, .linear)])
            }
        } else {
            automate(.a, .vocals, .delay, [(out - 1, 0, .linear), (out - 0.25, send, .hold), (out + tail, 0, .linear)])
            if reverb > 0.01 {
                automate(.a, .vocals, .reverb, [(out - 0.75, 0, .sCurve), (out - 0.25, reverb, .linear),
                                                (out, reverb, .linear), (out + min(tail, 0.75), 0, .linear)])
            }
        }
        if vocalOutFade > 0 {
            automate(.a, .vocals, .volume, [(out - vocalOutFade, 1, .logarithmic), (out, 0, .linear)])
        } else {
            // Closed over `vocalRelease`, shut by `out`: nothing of what
            // follows gets through. Cut on the beat (nothing to cut on was
            // found), it shuts ahead of it like every switch (see
            // `switchBeforeTheBeat`, which leaves a ramp this long alone).
            let end = onGrid(start + out * barSeconds, within: 0.0005) ? out - Self.switchLead / barSeconds : out
            let close = end - Self.vocalRelease / barSeconds
            // (A louder voice eases down to B's over its last bars, before
            // B's entry if that's where it leaves: A has played on its own
            // for 45 s by then, the last blend's automation long done.)
            if let g = Self.voiceMatch(-voiceStep) {
                let held = close - Self.voiceHold
                automate(.a, .vocals, .volume, [(held - Self.voiceYield, 1, .sCurve), (held, g, .linear),
                                                (close, g, .linear), (end, 0, .linear)])
            } else {
                automate(.a, .vocals, .volume, [(close, 1, .linear), (end, 0, .linear)])
            }
        }
    }

    /// Tension into the big change at bar `at`: over the two bars before,
    /// A's beat lifts into a resonant high-pass (~614 Hz), its bass gently
    /// pulls back over the final two beats (~287 Hz), and its last beat throws
    /// into the echo so B's low end lands as a real release.
    /// - Parameter drumsContinue: A's drums play on past the switch (their
    ///   own fade takes over from there).
    private mutating func buildUp(to at: Double, drumsContinue: Bool) {
        guard at >= 2 else { return }
        // 0.78 (~614 Hz) creates genuine club tension into the swap; where A's
        // drums linger past it, their fade continues smoothly upward from here.
        automate(.a, .drums, .filter, [(at - 2, 0.5, .exponential), (at, 0.78, .linear)])
        // Close the drum echo send right on the switch so A's beat-1 kick after
        // the swap doesn't smear over B's downbeat.
        automate(.a, .drums, .delay, [(at - 1, 0, .exponential), (at - 0.25, 0.45, .linear), (at, 0, .linear)])
        // Subtle 2-beat sub-bass tension lift right into B's bass drop
        // (skipped if the bass is already low-passed, e.g. drum-bed mashup).
        if at >= 4, let bi = lanes.firstIndex(where: { $0.side == .a && $0.stem == .bass }), lanes[bi][.filter].isEmpty {
            automate(.a, .bass, .filter, [(at - 0.5, 0.5, .exponential), (at, 0.72, .linear)])
        }
    }

    /// The big switch at bar `at` as a moment rather than a fade. Supports
    /// multiple DJ build styles (`buildStyle`): classic snare stutter,
    /// 2-bar loop-halving, filter/reverb riser, tension bass-pull, or an
    /// a cappella break where A's voice carries solo into B's drop.
    private mutating func buildDrop(at s: Double) {
        guard s >= 2 else { return buildUp(to: s, drumsContinue: false) }
        switch buildStyle {
        case .snareRoll:
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.85, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.82, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .reverb, [(s - 1.5, 0, .exponential), (s - 0.25, 0.65, .linear), (s - 0.125, 0, .linear)])
            // Only the tightest roll goes into the echo, and nothing once the
            // music stops: its first repeat fills the silence, and what's left
            // by the drop is faint, so B lands clean instead of under a smear.
            automate(.a, .drums, .delay, [(s - 0.25, 0, .hold), (s - 0.249, 0.35, .hold), (s - 0.125, 0, .linear)])
            // (Over a loop, the hit that's rolled is the loop's: A's drums
            // themselves are somewhere else in the song by now.)
            var backbeat = s - 1 + 0.25 * Double(rollBeat ?? 1)
            if loop > 0, backbeat >= 0 { backbeat = Double(-loopBack) + backbeat.truncatingRemainder(dividingBy: Double(loop)) }
            for (from, to, length) in [(s - 1, s - 0.5, 0.125), (s - 0.5, s - 0.25, 0.0625), (s - 0.25, s - 0.125, 0.03125)] {
                rolls.append(Roll(side: .a, stem: .drums, start: start + from * barSeconds, end: start + to * barSeconds,
                                  anchor: start + backbeat * barSeconds, length: length * barSeconds))
            }
            silences.append((.a, .bass, s - 0.5, s))
            silences.append((.b, .drums, s - 1, s))
            for stem in [StemKind.drums, .other] { silences.append((.a, stem, s - 0.125, s)) }
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.125, s)) }

        case .loopHalve:
            // Classic DJ loop-halving: repeat half a bar, then a quarter,
            // eighth, and sixteenth while high-passing into half a beat of
            // silence before B slams in.
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.86, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.83, .hold), (s, 0.5, .linear)])
            automate(.a, .drums, .delay, [(s - 0.5, 0, .exponential), (s - 0.25, 0.45, .linear), (s - 0.125, 0, .linear)])
            var anchor = s - 2
            if loop > 0, anchor >= 0 { anchor = Double(-loopBack) + anchor.truncatingRemainder(dividingBy: Double(loop)) }
            for (from, to, length) in [(s - 2, s - 1, 0.5), (s - 1, s - 0.5, 0.25),
                                       (s - 0.5, s - 0.25, 0.125), (s - 0.25, s - 0.125, 0.0625)] {
                rolls.append(Roll(side: .a, stem: .drums, start: start + from * barSeconds, end: start + to * barSeconds,
                                  anchor: start + anchor * barSeconds, length: length * barSeconds))
            }
            silences.append((.a, .bass, s - 1, s))
            silences.append((.b, .drums, s - 1, s))
            for stem in [StemKind.drums, .other] { silences.append((.a, stem, s - 0.125, s)) }
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.125, s)) }

        case .riser:
            // Smooth resonant filter + reverb wash swell without a stutter roll:
            // sweeps up to ~1.9 kHz on drums and ~1.5 kHz on melody into a crisp
            // drop release.
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.87, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.85, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .reverb, [(s - 2, 0, .sCurve), (s - 0.5, 0.85, .linear), (s - 0.125, 0.85, .linear), (s + 0.05, 0, .linear)])
            silences.append((.a, .bass, s - 0.5, s))
            silences.append((.b, .drums, s - 0.5, s))
            for stem in [StemKind.drums, .other] { silences.append((.a, stem, s - 0.125, s)) }
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.125, s)) }

        case .bassDrop:
            // Tension bass pull: A's bass & kick lows vanish two beats before
            // the drop while tops sweep into an echo, then B slams in full
            // without breaking the groove.
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s, 0.83, .linear)])
            automate(.a, .drums, .delay, [(s - 0.75, 0, .exponential), (s - 0.25, 0.5, .linear), (s, 0, .linear)])
            silences.append((.a, .bass, s - 0.5, s))
            silences.append((.b, .drums, s - 0.5, s))

        case .acappellaBreak:
            // A cappella tension break: sweep A's drums and melody into a
            // reverb wash over bar s-2..s-1, then pull beat, bass, and melody
            // for one full bar so A's voice carries solo into B's drop on `s`.
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 1, 0.84, .linear), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 2, 0.5, .sCurve), (s - 1, 0.16, .linear), (s, 0.5, .linear)])
            automate(.a, .other, .reverb, [(s - 2, 0, .sCurve), (s - 1.25, 0.80, .linear), (s - 0.5, 0, .linear)])
            silences.append((.a, .bass, s - 1, s))
            silences.append((.a, .drums, s - 1, s))
            silences.append((.a, .other, s - 1, s))
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 1, s)) }

        case .fakeoutDrop:
            // Fakeout drop: build resonant tension into `s`, then strip ALL
            // drums & bass (and A's melody) for 1 full bar (`s..<s+1`) so B's
            // iconic vocal & melody hang naked in the room before B's kick &
            // bass slam in on `s+1`.
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.86, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.84, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .reverb, [(s - 1.5, 0, .sCurve), (s - 0.375, 0.80, .linear),
                                           (s - 0.125, 0.80, .linear), (s + 0.05, 0, .linear)])
            // Ensure B's melody is wide open (unfiltered) during the naked fakeout bar.
            if let bi = lanes.firstIndex(where: { $0.side == .b && $0.stem == .other }), !lanes[bi][.filter].isEmpty {
                let openEnd = start + (s + 2.5) * barSeconds
                lanes[bi][.filter].clear((start + (s - 0.05) * barSeconds)...openEnd)
                automate(.b, .other, .filter, [(s - 0.05, 0.5, .linear), (s, 0.5, .linear)])
            }
            silences.append((.a, .bass, s - 0.5, s))
            silences.append((.a, .drums, s - 0.125, s))
            // Keep A's melody out through its dissolve window so it never pops
            // back in over B's naked fakeout bar.
            silences.append((.a, .other, s - 0.125, min(Double(bars) + 2, s + 2.5)))
            silences.append((.b, .other, s - 0.125, s))
            silences.append((.b, .drums, s - 0.5, s + 1))
            silences.append((.b, .bass, s - 0.125, s + 1))

        case .stutterGate:
            // James Hype style accelerating rhythmic fader-chop / trance-gate:
            // syncopated 1/8th → 1/16th rhythmic gates across the final 1.25
            // bars with a resonant HPF sweep and wide stereo ping-pong delay
            // catching every chopped transient before B's full drop on `s`.
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.87, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.85, .hold), (s, 0.5, .linear)])
            automate(.a, .drums, .delay, [(s - 1.25, 0, .sCurve), (s - 0.75, 0.58, .linear),
                                          (s - 0.25, 0.62, .linear), (s - 0.125, 0, .linear)])
            silences.append((.a, .bass, s - 1, s))
            silences.append((.b, .drums, s - 1, s))
            for (f, t) in [(s - 1.125, s - 1.0), (s - 0.875, s - 0.75), (s - 0.625, s - 0.5),
                           (s - 0.375, s - 0.3125), (s - 0.25, s - 0.1875), (s - 0.125, s)] {
                silences.append((.a, .drums, f, t))
                // On clashing keys, A's melody is already low-passing and fading
                // out over s-0.5..s; hard-gating a low-passed synth puts a mid-band click.
                if !keysClash { silences.append((.a, .other, f, t)) }
            }
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.125, s)) }

        case .polyRoll:
            // 3/16th polyrhythmic loop roll: hypnotic dotted-eighth tension
            // across the final 1.5 bars that snaps violently back onto the 4/4
            // downbeat when B's drop slams in.
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.86, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.83, .hold), (s, 0.5, .linear)])
            automate(.a, .drums, .delay, [(s - 1, 0, .sCurve), (s - 0.375, 0.48, .linear), (s - 0.125, 0, .linear)])
            var anchor = s - 1.5
            if loop > 0, anchor >= 0 { anchor = Double(-loopBack) + anchor.truncatingRemainder(dividingBy: Double(loop)) }
            rolls.append(Roll(side: .a, stem: .drums,
                              start: start + (s - 1.5) * barSeconds, end: start + (s - 0.125) * barSeconds,
                              anchor: start + anchor * barSeconds, length: 0.1875 * barSeconds))
            silences.append((.a, .bass, s - 1, s))
            silences.append((.b, .drums, s - 1, s))
            for stem in [StemKind.drums, .other] { silences.append((.a, stem, s - 0.125, s)) }
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.125, s)) }

        case .spinbackDrop:
            // Classic 1-beat turntable backspin right into B's drop on `s`.
            // Roll fades to 0 by `s - 0.08`; volume closes silently afterward at
            // `s - 0.05` so no ramp cuts into live audio.
            let spinStart = start + (s - 0.25) * barSeconds
            let spinEnd = start + (s - 0.08) * barSeconds
            for stem in [StemKind.drums, .bass, .other] {
                rolls.append(Roll(side: .a, stem: stem, start: spinStart, end: spinEnd,
                                  anchor: spinStart, length: spinEnd - spinStart, spinback: true))
            }
            automate(.a, .other, .reverb, [(s - 0.5, 0, .sCurve), (s - 0.25, 0.65, .linear),
                                           (s - 0.08, 0.65, .linear), (s + 0.04, 0, .linear)])
            silences.append((.a, .drums, s - 0.05, s))
            silences.append((.a, .bass, s - 0.05, s))
            silences.append((.a, .other, s - 0.05, min(Double(bars) + 2, s + 2.5)))
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.25, s)) }

        case .brakeDrop:
            // 2-beat vinyl turntable brake coasting down into B's drop on `s`.
            // Roll fades to 0 by `s - 0.08`; volume closes silently afterward at
            // `s - 0.05` so no ramp cuts into live audio.
            let brakeStart = start + (s - 0.5) * barSeconds
            let brakeEnd = start + (s - 0.08) * barSeconds
            for stem in [StemKind.drums, .bass, .other] {
                rolls.append(Roll(side: .a, stem: stem, start: brakeStart, end: brakeEnd,
                                  anchor: brakeStart, length: brakeEnd - brakeStart, brake: true))
            }
            automate(.a, .other, .reverb, [(s - 0.75, 0, .sCurve), (s - 0.375, 0.58, .linear),
                                           (s - 0.08, 0.58, .linear), (s + 0.04, 0, .linear)])
            silences.append((.a, .drums, s - 0.05, s))
            silences.append((.a, .bass, s - 0.05, s))
            silences.append((.a, .other, s - 0.05, min(Double(bars) + 2, s + 2.5)))
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.5, s)) }

        case .vocalChop:
            // Fred again.. / James Hype vocal stutter build: chops the chosen
            // vocal hook/word (A's last word or B's upcoming hook syllable) at
            // 1/4 → 1/8 → 1/16 → 1/32 through a rising HPF + stereo ping-pong
            // delay into half a beat of dead air before B slams in on `s`.
            let useB = vocalChop?.side == .b && (vocalExit ?? s) <= s - 1.0 && (vocalEntry ?? s) >= s - 0.125
            let side: DeckSide = useB ? .b : .a
            let anchor = useB ? (vocalChop?.anchor ?? s) : (vocalChop?.anchor ?? (s - 1))
            automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.88, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.86, .hold), (s, 0.5, .linear)])
            for (from, to, length) in [(s - 1.0, s - 0.5, 0.25), (s - 0.5, s - 0.375, 0.125),
                                       (s - 0.375, s - 0.25, 0.0625), (s - 0.25, s - 0.125, 0.03125)] {
                rolls.append(Roll(side: side, stem: .vocals,
                                  start: start + from * barSeconds, end: start + to * barSeconds,
                                  anchor: start + anchor * barSeconds, length: length * barSeconds))
            }
            if useB {
                automate(.b, .vocals, .volume, [
                    (s - 1.0, 0, .sCurve), (s - 0.96, 0.98, .linear),
                    (s - 0.145, 0.98, .sCurve), (s - 0.125, 0, .linear),
                ])
                automate(.b, .vocals, .filter, [
                    (s - 1.02, 0.56, .exponential), (s - 0.125, 0.80, .hold), (s - 0.06, 0.5, .linear),
                ])
                automate(.b, .vocals, .delay, [
                    (s - 1.0, 0, .sCurve), (s - 0.5, 0.78, .linear),
                    (s - 0.125, 0.78, .sCurve), (s - 0.04, 0, .linear),
                ])
                automate(.b, .vocals, .reverb, [
                    (s - 1.0, 0, .sCurve), (s - 0.25, 0.56, .linear), (s - 0.06, 0, .linear),
                ])
            } else {
                automate(.a, .vocals, .filter, [
                    (s - 1.0, 0.5, .exponential), (s - 0.125, 0.82, .hold), (s, 0.5, .linear),
                ])
                automate(.a, .vocals, .delay, [
                    (s - 1.0, 0, .sCurve), (s - 0.5, 0.78, .linear), (s - 0.125, 0, .linear),
                ])
            }
            silences.append((.a, .bass, s - 1, s))
            silences.append((.b, .drums, s - 1, s))
            for stem in [StemKind.drums, .other] { silences.append((.a, stem, s - 0.125, s)) }
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.125, s)) }

        case .beatJuggle:
            // High-adrenaline 2-bar full-bass call-and-response clash: trades
            // 2-beat and 1-beat full-bass slams between A and B before
            // accelerating into a 1/8 → 1/16 snare burst + half-beat dead air
            // straight into B's drop slam.
            var backbeat = s - 1 + 0.25 * Double(rollBeat ?? 1)
            if loop > 0, backbeat >= 0 { backbeat = Double(-loopBack) + backbeat.truncatingRemainder(dividingBy: Double(loop)) }
            for (from, to, length) in [(s - 0.5, s - 0.25, 0.125), (s - 0.25, s - 0.125, 0.0625)] {
                rolls.append(Roll(side: .a, stem: .drums, start: start + from * barSeconds, end: start + to * barSeconds,
                                  anchor: start + backbeat * barSeconds, length: length * barSeconds))
            }
            if drumsLayer && !keysClash && s >= 4 {
                // Keep both decks unfiltered and punchy during the 2-beat & 1-beat
                // full-bass trade, then sweep A's snare burst up into B's drop.
                automate(.a, .drums, .filter, [(s - 0.5, 0.5, .exponential), (s - 0.125, 0.86, .hold), (s, 0.5, .linear)])
                automate(.a, .drums, .delay, [(s - 0.5, 0, .sCurve), (s - 0.25, 0.56, .linear), (s - 0.125, 0, .linear)])
                // Open B's drums filter cleanly before B's first juggle slam.
                if let di = lanes.firstIndex(where: { $0.side == .b && $0.stem == .drums }) {
                    lanes[di][.filter].clear((start + (s - 1.55) * barSeconds)...(start + (s + 0.05) * barSeconds))
                    automate(.b, .drums, .filter, [(s - 1.55, 0.5, .linear), (s, 0.5, .linear)])
                    lanes[di][.low].clear((start + (s - 1.55) * barSeconds)...(start + (s + 0.05) * barSeconds))
                }
                if let bi = lanes.firstIndex(where: { $0.side == .b && $0.stem == .bass }) {
                    lanes[bi][.volume].clear((start + (s - 1.55) * barSeconds)...(start + (s + 0.05) * barSeconds))
                }
                // Punch B's full bass & kick low-end OPEN on B's exact juggle turns
                // (`s-1.5..s-1.0` and `s-0.75..s-0.5`) while A is silenced!
                automate(.b, .bass, .volume, [
                    (s - 1.5, 0, .hold), (s - 1.499, 1, .hold), (s - 1.0, 1, .hold), (s - 0.999, 0, .hold),
                    (s - 0.75, 0, .hold), (s - 0.749, 1, .hold), (s - 0.5, 1, .hold), (s - 0.499, 0, .hold),
                    (s, 0, .hold), (s + 0.001, 1, .linear),
                ])
                automate(.b, .drums, .low, [
                    (s - 1.5, 0, .hold), (s - 1.499, 0.5, .hold), (s - 1.0, 0.5, .hold), (s - 0.999, 0, .hold),
                    (s - 0.75, 0, .hold), (s - 0.749, 0.5, .hold), (s - 0.5, 0.5, .hold), (s - 0.499, 0, .hold),
                    (s, 0, .hold), (s + 0.001, 0.5, .linear),
                ])
                // Trade hits: A (s-2..s-1.5) → B (s-1.5..s-1.0) → A (s-1.0..s-0.75) → B (s-0.75..s-0.5) → A roll!
                for (f, t) in [(s - 2.0, s - 1.5), (s - 1.0, s - 0.75), (s - 0.5, s)] {
                    silences.append((.b, .drums, f, t))
                    silences.append((.b, .other, f, t))
                }
                for (f, t) in [(s - 1.5, s - 1.0), (s - 0.75, s - 0.5)] {
                    silences.append((.a, .drums, f, t))
                    silences.append((.a, .bass, f, t))
                    silences.append((.a, .other, f, t))
                }
            } else {
                // When B's drums wait for `s` or keys clash, chop A's own beat rhythmically into the roll.
                automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.85, .hold), (s, 0.5, .linear)])
                automate(.a, .drums, .delay, [(s - 0.5, 0, .sCurve), (s - 0.25, 0.52, .linear), (s - 0.125, 0, .linear)])
                silences.append((.b, .drums, s - 1, s))
                for (f, t) in [(s - 1.5, s - 1.25), (s - 0.75, s - 0.625)] {
                    silences.append((.a, .drums, f, t))
                }
            }
            silences.append((.a, .bass, s - 0.5, s))
            silences.append((.a, .drums, s - 0.125, s))
            // Keep A's melody out past the drop dissolve so it never snaps back open on B's drop.
            silences.append((.a, .other, s - 0.125, min(Double(bars) + 2, s + 2.5)))
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.125, s)) }

        case .echoFreeze:
            // Pioneer RMX-1000 spiral echo freeze: sweeps A's tops up into a
            // lush stereo ping-pong delay + cathedral reverb bloom, then cuts
            // dry A half a bar early so ONLY the spiraling echo hangs in space
            // before B's full drop slams in on `s`.
            automate(.a, .drums, .filter, [(s - 1.75, 0.5, .exponential), (s - 0.5, 0.87, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 1.75, 0.5, .exponential), (s - 0.5, 0.85, .hold), (s, 0.5, .linear)])
            automate(.a, .drums, .delay, [(s - 1.5, 0, .sCurve), (s - 0.875, 0.82, .linear),
                                          (s - 0.5, 0.82, .linear), (s - 0.45, 0, .linear)])
            automate(.a, .other, .reverb, [(s - 1.5, 0, .sCurve), (s - 0.75, 0.86, .linear),
                                           (s - 0.5, 0.86, .linear), (s - 0.45, 0, .linear)])
            silences.append((.a, .bass, s - 1.0, s))
            silences.append((.a, .drums, s - 0.5, s))
            silences.append((.a, .other, s - 0.5, min(Double(bars) + 2, s + 2.5)))
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.5, s)) }

        case .filterSlam:
            // Club underwater submarine low-pass slam: dives A's beat & melody
            // (and B's incoming tops) down into a resonant ~330 Hz underwater
            // low-pass with a warm reverb bloom, pulls bass for 2 beats into a
            // half-beat breath, then snaps B wide open at full brightness on `s`.
            automate(.a, .drums, .filter, [(s - 1.75, 0.5, .sCurve), (s - 0.125, 0.18, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .filter, [(s - 1.75, 0.5, .sCurve), (s - 0.125, 0.16, .hold), (s, 0.5, .linear)])
            automate(.a, .other, .reverb, [(s - 1.5, 0, .sCurve), (s - 0.375, 0.76, .linear),
                                           (s - 0.125, 0.76, .linear), (s + 0.04, 0, .linear)])
            if drumsLayer {
                if let di = lanes.firstIndex(where: { $0.side == .b && $0.stem == .drums }) {
                    lanes[di][.filter].clear((start + (s - 1.75) * barSeconds)...(start + (s + 0.05) * barSeconds))
                }
                automate(.b, .drums, .filter, [(s - 1.75, 0.5, .sCurve), (s - 0.125, 0.18, .hold), (s, 0.5, .linear)])
            }
            if !keysClash && !mashup {
                if let oi = lanes.firstIndex(where: { $0.side == .b && $0.stem == .other }) {
                    lanes[oi][.filter].clear((start + (s - 1.75) * barSeconds)...(start + (s + 0.05) * barSeconds))
                }
                automate(.b, .other, .filter, [(s - 1.75, 0.5, .sCurve), (s - 0.125, 0.18, .hold), (s, 0.5, .linear)])
            }
            silences.append((.a, .bass, s - 0.5, s))
            silences.append((.b, .drums, s - 0.125, s))
            silences.append((.a, .drums, s - 0.125, s))
            silences.append((.a, .other, s - 0.125, min(Double(bars) + 2, s + 2.5)))
            for stem in [StemKind.drums, .bass, .other] { silences.append((.b, stem, s - 0.125, s)) }
        }
    }

    /// The volume of a stem drops to nothing from bar `from` to bar `to`
    /// and comes back to whatever it would have been.
    private mutating func silence(_ side: DeckSide, _ stem: StemKind, from: Double, to: Double) {
        guard let i = lanes.firstIndex(where: { $0.side == side && $0.stem == stem }), to > from else { return }
        let t0 = start + from * barSeconds, t1 = start + to * barSeconds
        // Just before, and just after (past any hard cut right on `to`).
        // (A cut lands a thousandth of a bar after its downbeat: over two
        // milliseconds below 120 BPM, which left the stem open for that
        // long right on the drop.)
        let lead = t0 - 0.002, back = t1 + max(0.002, 0.002 * barSeconds)
        let before = lanes[i].value(.volume, at: lead), after = lanes[i].value(.volume, at: back)
        // What the stem does from `to` on: a move that starts right there
        // keeps its shape, one already under way carries on in a line.
        let last = lanes[i][.volume].points.last { $0.time <= back }
        let curve = last.map { $0.time >= t1 - 1e-6 || $0.curve == .hold ? $0.curve : .linear } ?? .linear
        lanes[i][.volume].clear(lead...back)
        lanes[i][.volume].insert(AutomationPoint(time: lead, value: before, curve: .linear))
        lanes[i][.volume].insert(AutomationPoint(time: t0, value: 0, curve: .hold))
        lanes[i][.volume].insert(AutomationPoint(time: t1, value: after, curve: curve))
    }

    private mutating func write(_ preset: TransitionPreset) {
        let n = Double(bars)
        // Never before A's vocal is out (the swap), never after the end;
        // in a mashup from a quarter in.
        let earliest = mashup ? Self.mashupWindow(bars: bars).earliest : n / 2
        let v = min(n, max(earliest, Double(vocalBar ?? bars)))
        switch preset {
        case .stemSwap:
            let q = n / 4
            // Half-way or later, unless A's own low end left earlier.
            let sw = Self.switchBar(preset, bars: bars, lowSwap: lowSwap)
            // The low end has one owner at a time: A's kick and bass until the
            // half-way downbeat, B's from there. B's drums come in with their
            // lows killed (hats, snares, percussion) and take the kick over in
            // the same instant A's drums hand it off.
            if drumsLayer {
                // B's hats, snares and percussion in on the first downbeat
                // (the low kill keeps its kick out), high-passed at ~1,310 Hz
                // (24 dB/oct DJ sweep) opening smoothly over the first phrase.
                bringIn(.drums, at: 0, filter: 0.84, open: min(q, sw))
            } else if hats {
                automate(.b, .drums, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
                automate(.b, .drums, .filter, [(0, Self.hatsFilter, .hold), (sw - 0.001, Self.hatsFilter, .hold), (sw, 0.5, .linear)])
            } else {
                automate(.b, .drums, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
            }
            // Melody stems carry low end too (synth bass, 808s): B's stays
            // killed, A's goes, on the same downbeat.
            for stem in [StemKind.drums, .other] {
                automate(.b, stem, .low, [(sw, 0, .hold), (sw + 0.001, 0.5, .linear)])
                if sw < n {
                    automate(.a, stem, .low, [(sw, 0.5, .hold), (sw + 0.001, 0, .linear)])
                }
            }
            // Hard bass swap on the same downbeat. One bass line at a time,
            // lows or not: two lines moving at once (each in its own key and
            // rhythm) are mud, not a blend.
            automate(.a, .bass, .volume, [(sw, 1, .hold), (sw + 0.001, 0, .linear)])
            automate(.b, .bass, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
            handOverVocalLows(at: sw)
            // A's vocal echoes out as B's arrives or B takes the low end,
            // whichever comes first: pulled any earlier, it leaves a hole.
            // Clashing keys: nothing of B's in its key (melody, voice)
            // plays over anything of A's (melody, bass line, voice). The
            // melodies and voices all swap with the low end, so A's voice
            // sings on until then: nothing of B's in a key is there yet.
            let vin = keysClash ? max(sw, vocalIn ?? v) : vocalIn ?? v
            // A caller that heard where B's voice really starts singing may
            // keep A's past the moment B's (still silent) channel opens.
            // (Never past the swap on clashing keys: B's melody lands there.)
            let out = min(vocalOut ?? min(vin, sw), keysClash ? sw : .infinity)
            echoOutVocal(at: out, send: vocalSend)
            if keysClash {
                // Two keys never sound together, and the one changes into
                // the other the way a DJ does it with the filters: A's
                // melody closes down (low-pass to ~430 Hz) over 1.5 bars
                // into a blooming reverb tail and fades cleanly out over the
                // final two beats, while B's sweeps open from ~280 Hz over
                // the bar after so the midrange body never dips on the swap.
                let out = max(0, sw - 1.5)
                automate(.a, .other, .filter, [(out, 0.5, .sCurve), (sw, 0.20, .hold), (sw + 0.001, 0.5, .linear)])
                // Peak the reverb send before the half-bar exit fade so the
                // post-fader wash blooms across the harmonic handover.
                automate(.a, .other, .reverb, [(sw - 1, 0, .sCurve), (sw - 0.5, 0.80, .linear),
                                               (sw - 0.125, 0.80, .linear), (sw + 0.05, 0, .linear)])
                automate(.a, .other, .volume, [(max(0, sw - 0.5), 1, .sCurve), (sw, 0, .linear)])
                bringIn(.other, at: sw, filter: 0.68, open: min(n + 2, sw + 1.0))
            } else if mashup {
                // B's voice is the thing heard over A's beat: its melody
                // waits for the swap, and A's dissolves under it, gone by
                // the blend's end (past it B glides home, and anything of
                // A's would drift off its beat).
                automate(.b, .other, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
                let dissolve = Self.melodyDissolve(preset, bars: bars, switchAt: sw, mashup: true)
                if mashupUnder > 0.25, dissolve > vin + 0.25 {
                    // Carve a vocal pocket in A's melody mids while B sings over A.
                    let pocket = 0.5 - min(mashupUnder, 6) / 80
                    automate(.a, .other, .mid, [(max(0, vin - 0.25), 0.5, .sCurve), (vin, pocket, .linear),
                                                (dissolve + 2, pocket, .linear), (Double(bars) + 4, 0.5, .linear)])
                }
                dissolveMelody(from: dissolve)
            } else {
                // One part of B at a time, as a DJ brings them in: its tops
                // first, its melody a quarter in under a high-pass (~1,020 Hz)
                // that opens smoothly over the next bars. The two melodies
                // share at most the bars from there to two past the swap, or
                // past half-way where B is still building up to a late swap
                // (A's beat and bass carry it there, not two melodies); A's
                // then dissolves (low-pass sweep into a reverb wash), so
                // there's never more than one song's harmony for long.
                let lift = min(out, underUntil ?? out)
                let bMelFilter = carry ? 0.72 : 0.82
                let bMelOpen = carry ? q + 1.0 : q + max(1, q / 2)
                if under > 0.25, lift > q + 0.01 {
                    // Under A's voice for as long as it sings (volume + gentle
                    // mid vocal pocket), then up to full on the beat it leaves
                    // on: a step, not a fade.
                    let held = pow(10, -min(under, 12) / 20)
                    bringIn(.other, at: q, filter: bMelFilter, open: bMelOpen, level: held)
                    automate(.b, .other, .volume, [(lift, held, .hold), (lift + 0.001, 1, .linear)])
                    let midCut = 0.5 - min(under, 4) / 80
                    automate(.b, .other, .mid, [(q, midCut, .linear), (max(q + 0.01, lift - 0.125), midCut, .sCurve), (lift, 0.5, .linear)])
                } else {
                    bringIn(.other, at: q, filter: bMelFilter, open: bMelOpen)
                    // Reverse mashup: if A's voice carries on past the swap over
                    // B's new beat, carve a gentle mid pocket in B's melody so
                    // A's singer stays crystal clear until exiting.
                    if out > sw + 0.5 {
                        automate(.b, .other, .mid, [(max(0, sw - 0.25), 0.5, .sCurve), (sw, 0.4625, .linear),
                                                    (max(sw + 0.1, out - 0.125), 0.4625, .sCurve), (out, 0.5, .linear)])
                    }
                }
                let dissolve = Self.melodyDissolve(preset, bars: bars, switchAt: sw, carry: carry)
                // (Over two bars in a long blend: a bar's fade of a held
                // melody there ticked on its low notes.)
                let holdFade: Double = bars >= 16 ? 2 : 1
                if holdMelody, sw - holdFade > dissolve {
                    dissolveMelody(from: sw - holdFade, over: holdFade)
                } else {
                    dissolveMelody(from: dissolve)
                }
            }
            if drumsLayer && drumsLinger && sw < n && !dropMoment {
                // A's tops thin out and hand over smoothly from where the
                // build-up left the filter (~614 Hz) up to ~2.2 kHz.
                let fadeFrom = sw <= q ? max(sw, 2 * q) : 3 * q
                automate(.a, .drums, .filter, [(fadeFrom, sw >= 2 ? 0.78 : 0.5, .sCurve), (4 * q, 0.88, .linear)])
                automate(.a, .drums, .volume, [(fadeFrom, 1, .sCurve), (4 * q, 0, .linear)])
            } else {
                // One beat at a time: A's carries the build and hands
                // straight over to B's on the switch.
                automate(.a, .drums, .volume, [(sw, 1, .hold), (sw + 0.001, 0, .linear)])
            }
            bringInVocal(at: vin)
            makeRoom(at: q, until: sw, melody: !keysClash)
            if dropMoment {
                buildDrop(at: sw)
            } else {
                buildUp(to: sw, drumsContinue: drumsLayer && drumsLinger && sw < n)
            }

        case .dropSwap:
            // A rides its build; on the drop everything flips to B at once.
            let h = Self.switchBar(preset, bars: bars, lowSwap: lowSwap)
            let vin = max(h, vocalIn ?? v)
            // A caller that heard where B's voice really starts singing may
            // keep A's past the moment B's (still silent) channel opens.
            let out = min(vocalOut ?? min(vin, h), keysClash ? h : .infinity)
            if drumsLayer {
                // B's tops from the first downbeat, opening like a riser from
                // ~1 kHz down to ~100 Hz before slamming full on the drop.
                automate(.b, .drums, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
                automate(.b, .drums, .filter, [(0, 0.80, .exponential), (h - 0.001, 0.54, .hold), (h, 0.5, .linear)])
            } else {
                automate(.b, .drums, .volume, [(h, 0, .hold), (h + 0.001, 1, .linear)])
            }
            // No second kick before the drop.
            automate(.b, .drums, .low, [(h, 0, .hold), (h + 0.001, 0.5, .linear)])
            handOverVocalLows(at: h)
            automate(.b, .bass, .volume, [(h, 0, .hold), (h + 0.001, 1, .linear)])
            if keysClash {
                automate(.b, .other, .volume, [(h, 0, .hold), (h + 0.001, 1, .linear)])
            } else {
                // A taste of B's melody over A's build, opening clearly into
                // the drop so both songs are genuinely heard together first
                // (pocketed under A's vocal when `under` is active).
                let lift = min(out, underUntil ?? out)
                if under > 0.25, lift > h / 2 + 0.01 {
                    let held = pow(10, -min(under, 12) / 20)
                    automate(.b, .other, .volume, [(h / 2, 0, .hold), (h / 2 + 0.001, held, .linear),
                                                   (lift, held, .hold), (lift + 0.001, 1, .linear)])
                    let midCut = 0.5 - min(under, 4) / 80
                    automate(.b, .other, .mid, [(h / 2, midCut, .linear), (max(h / 2 + 0.01, lift - 0.125), midCut, .sCurve), (lift, 0.5, .linear)])
                } else {
                    automate(.b, .other, .volume, [(h / 2, 0, .hold), (h / 2 + 0.001, 1, .linear)])
                }
                automate(.b, .other, .filter, [(h / 2, 0.74, .exponential), (h - 0.001, 0.54, .hold), (h, 0.5, .linear)])
                automate(.b, .other, .low, [(h, 0, .hold), (h + 0.001, 0.5, .linear)])
            }
            for stem in [StemKind.drums, .bass] {
                automate(.a, stem, .volume, [(h, 1, .hold), (h + 0.001, 0, .linear)])
            }
            // A's melody carries low end too (synth bass, 808s): it goes on
            // the drop, under B's bass line, while the rest of it dissolves.
            automate(.a, .other, .low, [(h, 0.5, .hold), (h + 0.001, 0, .linear)])
            if keysClash {
                automate(.a, .other, .reverb, [(h - 1, 0, .sCurve), (h - 0.25, 0.8, .linear),
                                               (h, 0.8, .linear), (h + 0.05, 0, .linear)])
                automate(.a, .other, .volume, [(h, 1, .hold), (h + 0.001, 0, .linear)])
            } else {
                dissolveMelody(from: h)
            }
            echoOutVocal(at: out, send: min(0.85, vocalSend + 0.07))
            bringInVocal(at: vin)
            if dropMoment {
                buildDrop(at: h)
            } else {
                buildUp(to: h, drumsContinue: false)
            }

        case .longBlend:
            let q = n / 4
            // B's low end starts killed so it can come up under A's bass.
            automate(.b, .bass, .low, [(2 * q, 0, .hold), (2 * q + 0.001, 0.5, .linear)])
            automate(.b, .drums, .low, [(2 * q, 0, .hold), (2 * q + 0.001, 0.5, .linear)])
            automate(.a, .bass, .low, [(2 * q, 0.5, .hold), (2 * q + 0.001, 0, .linear)])
            automate(.a, .drums, .low, [(2 * q, 0.5, .hold), (2 * q + 0.001, 0, .linear)])
            // Melody stems carry low end too: B's opens on the swap, while A's
            // sweeps out smoothly as A's melody begins receding (avoiding an
            // abrupt isolator snap mid-low-pass at 2*q).
            automate(.b, .other, .low, [(2 * q, 0, .hold), (2 * q + 0.001, 0.5, .linear)])
            if keysClash {
                automate(.a, .other, .low, [(2 * q, 0.5, .hold), (2 * q + 0.001, 0, .linear)])
            } else {
                automate(.a, .other, .low, [(2 * q - 0.08, 0.5, .sCurve), (2 * q, 0, .linear)])
            }
            handOverVocalLows(at: 2 * q)
            // B's drums layer from the first downbeat when the two kits lock
            // (or B's hats alone if only hats lock); otherwise B's drums land
            // cleanly on the half-way swap so two non-locking kits never flam.
            if drumsLayer {
                bringIn(.drums, at: 0, filter: 0.82, open: q)
            } else if hats {
                automate(.b, .drums, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
                automate(.b, .drums, .filter, [(0, Self.hatsFilter, .hold), (2 * q - 0.001, Self.hatsFilter, .hold), (2 * q, 0.5, .linear)])
            } else {
                automate(.b, .drums, .volume, [(2 * q, 0, .hold), (2 * q + 0.001, 1, .linear)])
            }
            automate(.b, .bass, .volume, [(2 * q, 0, .hold), (2 * q + 0.001, 1, .linear)])
            automate(.a, .bass, .volume, [(2 * q, 1, .hold), (2 * q + 0.001, 0, .linear)])
            // The voices hand over like a Drop Swap's: B's from the swap,
            // between lines where the caller found them; A's until then.
            let vin = max(2 * q, vocalIn ?? v)
            let out = min(vocalOut ?? min(vin, 2 * q), keysClash ? 2 * q : n)
            echoOutVocal(at: out, send: vocalSend)
            if keysClash {
                automate(.a, .other, .reverb, [(2 * q - 1, 0, .sCurve), (2 * q - 0.25, 0.8, .linear),
                                               (2 * q, 0.8, .linear), (2 * q + 0.05, 0, .linear)])
                automate(.a, .other, .volume, [(2 * q, 1, .hold), (2 * q + 0.001, 0, .linear)])
                automate(.b, .other, .volume, [(2 * q, 0, .hold), (2 * q + 0.001, 1, .linear)])
            } else {
                let lift = min(out, underUntil ?? out)
                if under > 0.25, lift > q + 0.01 {
                    let held = pow(10, -min(under, 12) / 20)
                    bringIn(.other, at: q, filter: 0.78, open: min(2 * q, q + max(2, q / 2)), level: held)
                    automate(.b, .other, .volume, [(lift, held, .hold), (lift + 0.001, 1, .linear)])
                    let midCut = 0.5 - min(under, 4) / 80
                    automate(.b, .other, .mid, [(q, midCut, .linear), (max(q + 0.01, lift - 0.125), midCut, .sCurve), (lift, 0.5, .linear)])
                } else {
                    bringIn(.other, at: q, filter: 0.78, open: min(2 * q, q + max(2, q / 2)))
                }
                // Warm progressive melody handover: A's melody begins receding
                // gently into a low-pass wash half a phrase before the swap and
                // clears half a phrase after so A's and B's leads don't pile up
                // over B's incoming vocal while A's drums carry the groove on.
                automate(.a, .other, .filter, [(1.5 * q, 0.5, .sCurve), (2.5 * q, 0.22, .linear)])
                automate(.a, .other, .reverb, [(1.25 * q, 0, .sCurve), (1.75 * q, 0.65, .linear),
                                               (2.25 * q, 0.65, .sCurve), (2.75 * q, 0, .linear)])
                automate(.a, .other, .volume, [(1.5 * q, 1, .sCurve), (2.5 * q, 0, .linear)])
            }
            if drumsLayer && drumsLinger {
                automate(.a, .drums, .filter, [(3 * q, 0.5, .sCurve), (4 * q, 0.88, .linear)])
                automate(.a, .drums, .volume, [(3 * q, 1, .sCurve), (4 * q, 0, .linear)])
            } else {
                automate(.a, .drums, .volume, [(2 * q, 1, .hold), (2 * q + 0.001, 0, .linear)])
            }
            bringInVocal(at: vin)
            makeRoom(at: q, until: 2 * q, melody: !keysClash)

        case .mashup:
            // Full club mashup (16–32 bars): B's singer rides over A's groove
            // for an entire verse or hook (0..<sw), then B's real bass, kick,
            // and full melody slam in on `sw` as A washes into reverb.
            let q = n / 4
            let sw = Self.switchBar(.mashup, bars: bars, lowSwap: lowSwap)
            let vin = max(0, min(sw - 1, vocalIn ?? 0))
            let out = min(vin, vocalOut ?? vin)
            // Drums: if grooves lock, B's low-killed drums sweep smoothly in
            // underneath B's vocal to build energy into the drop; otherwise
            // A's beat drives cleanly solo until B slams in on `sw`.
            if drumsLayer {
                bringIn(.drums, at: 0, filter: 0.86, open: sw)
            } else if hats {
                automate(.b, .drums, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
                automate(.b, .drums, .filter, [(0, Self.hatsFilter, .hold), (sw - 0.001, Self.hatsFilter, .hold), (sw, 0.5, .linear)])
            } else {
                automate(.b, .drums, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
            }
            for stem in [StemKind.drums, .other] {
                automate(.b, stem, .low, [(sw, 0, .hold), (sw + 0.001, 0.5, .linear)])
                if sw < n {
                    automate(.a, stem, .low, [(sw, 0.5, .hold), (sw + 0.001, 0, .linear)])
                }
            }
            automate(.a, .bass, .volume, [(sw, 1, .hold), (sw + 0.001, 0, .linear)])
            automate(.b, .bass, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
            handOverVocalLows(at: sw)
            // A's vocal echoes out with a lush reverb tail right before B's singer takes over.
            echoOutVocal(at: out, send: vocalSend, reverb: 0.42)
            bringInVocal(at: vin)

            if keysClash {
                // Drum-bed mashup: strip A's melody out smoothly over the
                // first 2 bars and filter A's bass to pure sub so B's vocal
                // rides clash-free over A's beat until B's full song drops on `sw`.
                let stripEnd = min(2.0, max(1.0, sw / 2))
                automate(.a, .other, .filter, [(0, 0.5, .sCurve), (stripEnd, 0.14, .linear)])
                automate(.a, .other, .reverb, [(0, 0, .sCurve), (stripEnd * 0.35, 0.72, .linear), (stripEnd, 0, .linear)])
                automate(.a, .other, .volume, [(0, 1, .sCurve), (stripEnd, 0, .linear)])
                automate(.a, .bass, .filter, [(0, 0.5, .sCurve), (min(1.0, sw / 4), 0.12, .linear)])
                automate(.b, .other, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
            } else {
                // Harmonic club mashup: A's full melody stays as the musical
                // bed under B's voice, pocketed cleanly in the mids, then
                // dissolves into reverb as B's real instrumental slams in on `sw`.
                let dissolve = Self.melodyDissolve(.mashup, bars: bars, switchAt: sw)
                let pocketDB = max(3.5, min(6.0, mashupUnder > 0.25 ? mashupUnder : 3.5))
                let pocket = 0.5 - pocketDB / 80
                if dissolve > vin + 0.25 {
                    automate(.a, .other, .mid, [(max(0, vin - 0.25), 0.5, .sCurve), (vin, pocket, .linear),
                                                (dissolve + 2, pocket, .linear), (n + 4, 0.5, .linear)])
                }
                dissolveMelody(from: dissolve)
                if dropMoment {
                    automate(.b, .other, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
                } else {
                    bringIn(.other, at: sw, filter: 0.78, open: min(n, sw + 1.5))
                }
            }
            if drumsLayer && drumsLinger && sw < n && !dropMoment {
                let fadeFrom = max(sw, 3 * q)
                automate(.a, .drums, .filter, [(fadeFrom, sw >= 2 ? 0.78 : 0.5, .sCurve), (n, 0.88, .linear)])
                automate(.a, .drums, .volume, [(fadeFrom, 1, .sCurve), (n, 0, .linear)])
            } else {
                automate(.a, .drums, .volume, [(sw, 1, .hold), (sw + 0.001, 0, .linear)])
            }
            if dropMoment {
                buildDrop(at: sw)
            } else {
                buildUp(to: sw, drumsContinue: drumsLayer && drumsLinger && sw < n)
            }

        case .echoOut where n <= 1:
            // A cut on the one, for tempos too far apart to blend: what a
            // club DJ does rather than play a record everyone knows 15 %
            // off its tempo. Either a classic turntable vinyl brake spin-down
            // or a resonant HPF + echo lift into half a beat of silence before
            // B lands whole on its downbeat at its own tempo.
            if vinylBrake {
                let brakeStart = start - 0.5 * barSeconds
                let brakeEnd = start - 0.06 * barSeconds
                for stem in [StemKind.drums, .bass, .other] {
                    rolls.append(Roll(side: .a, stem: stem, start: brakeStart, end: brakeEnd,
                                      anchor: brakeStart, length: brakeEnd - brakeStart, brake: true))
                    automate(.a, stem, .volume, [(-0.06, 1, .hold), (-0.059, 0, .linear)])
                }
                automate(.a, .other, .reverb, [(-0.625, 0, .sCurve), (-0.375, 0.55, .linear),
                                               (-0.25, 0.55, .linear), (-0.06, 0, .linear)])
            } else if spinback {
                let spinStart = start - 0.25 * barSeconds
                let spinEnd = start - 0.06 * barSeconds
                for stem in [StemKind.drums, .bass, .other] {
                    rolls.append(Roll(side: .a, stem: stem, start: spinStart, end: spinEnd,
                                      anchor: spinStart, length: spinEnd - spinStart, spinback: true))
                    automate(.a, stem, .volume, [(-0.06, 1, .hold), (-0.059, 0, .linear)])
                }
                automate(.a, .other, .reverb, [(-0.375, 0, .sCurve), (-0.25, 0.68, .linear),
                                               (-0.125, 0.68, .linear), (-0.06, 0, .linear)])
            } else if acapellaBridge {
                // Open-format a cappella tempo-bridge: kill A's beat & bass 2
                // bars early so A's singing voice + softly reverbed melody
                // float beatless into a cathedral wash, then B slams in at its
                // own completely different tempo on beat 1.
                for stem in [StemKind.drums, .bass] {
                    automate(.a, stem, .filter, [(-2, 0.5, .sCurve), (-1.25, 0.14, .linear)])
                    automate(.a, stem, .volume, [(-2, 1, .sCurve), (-1.25, 0, .linear)])
                }
                automate(.a, .drums, .delay, [(-2.25, 0, .sCurve), (-1.75, 0.55, .linear), (-1.25, 0, .linear)])
                automate(.a, .other, .filter, [(-2, 0.5, .sCurve), (-0.125, 0.22, .linear)])
                automate(.a, .other, .reverb, [(-1.5, 0, .sCurve), (-0.5, 0.78, .linear), (-0.125, 0.78, .linear), (0.001, 0, .linear)])
                automate(.a, .other, .volume, [(-1.25, 1, .sCurve), (-0.125, 0, .linear)])
            } else {
                for stem in [StemKind.drums, .bass, .other] {
                    automate(.a, stem, .volume, [(-0.125, 1, .hold), (-0.124, 0, .linear)])
                }
                automate(.a, .drums, .filter, [(-1, 0.5, .exponential), (-0.126, 0.82, .hold)])
                automate(.a, .drums, .delay, [(-0.5, 0, .exponential), (-0.25, 0.5, .linear), (-0.125, 0.5, .linear), (0, 0, .linear)])
                automate(.a, .other, .reverb, [(-0.625, 0, .sCurve), (-0.25, 0.65, .linear), (-0.125, 0.65, .linear), (0.001, 0, .linear)])
            }
            // B's voice with its beat, or a beat before on a pickup.
            let vin = max(-AutoPlacement.pickup, min(0, vocalIn ?? 0))
            // A's voice leaves on a line end in its last bars, at the cut
            // (or B's pickup) at the latest, thrown into the echo.
            let out = max(-4, min(-0.125, vin, vocalOut ?? -0.125))
            echoOutVocal(at: out, send: min(0.85, vocalSend + 0.07), tail: max(0.25, min(1, -out)), reverb: 0.45)
            for stem in [StemKind.drums, .bass, .other] {
                automate(.b, stem, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
            }
            bringInVocal(at: vin)

        case .echoOut:
            // The tempos can't be matched, so two beats must never play at
            // once. Like a DJ bridging a tempo jump: A's beat leaves first,
            // its melody and vocal float on beatless (no tempo to clash
            // with), B's intro rises under them opening like a riser, and
            // B's beat drops on its downbeat as A washes into reverb.
            // (A's beat stays until two bars before the drop: leaving
            // half-way through an eight-bar bridge, it left four bars
            // 7 dB under the set's level. Two beatless bars are a breath;
            // four are a hole.)
            let e = max(1, min(n, 8)), half = min(2, e / 2)
            for stem in [StemKind.drums, .bass] {
                automate(.a, stem, .filter, [(-max(e / 2, 2 * half), 0.5, .sCurve), (-half, 0.14, .linear)])
                automate(.a, stem, .volume, [(-max(e / 2, 2 * half), 1, .sCurve), (-half, 0, .linear)])
            }
            automate(.a, .drums, .delay, [(-half - 1, 0, .exponential), (-half - 0.25, 0.6, .hold), (-half + 0.5, 0, .linear)])
            // A's melody floats on into a reverb wash, whole, until the
            // music stops for half a beat before B's downbeat (a fade from
            // a bar out left two near-silent bars).
            automate(.a, .other, .reverb, [(-half, 0, .sCurve), (-0.5, 0.78, .hold), (0.001, 0, .linear)])
            automate(.a, .other, .volume, [(-0.125, 1, .hold), (-0.124, 0, .linear)])
            // The echo is timed to A's tempo: its send closes by B's
            // downbeat, so no more than its last repeats ring over B's beat.
            let vin = max(-AutoPlacement.pickup, min(0, vocalIn ?? 0))
            let out = max(-e, min(vin, vocalOut ?? -1))
            echoOutVocal(at: out, send: min(0.85, vocalSend + 0.07), tail: max(0.25, min(2, -out)))
            // The tempos differ: B's melody never plays over A's (two
            // rhythms that can't line up). It lands with B's beat, as A's
            // is washing away.
            for stem in [StemKind.drums, .bass, .other] {
                automate(.b, stem, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
            }
            // B's voice with its beat, or a beat before on a pickup: never
            // held back while its song plays.
            bringInVocal(at: vin)
        }
    }
}
