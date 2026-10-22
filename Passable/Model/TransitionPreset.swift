import Foundation

/// Ready-made stem choreographies. Each writes automation relative to the
/// moment B enters, measured in bars of the master (A) grid, so they land on
/// phrase boundaries whatever the tempo.
enum TransitionPreset: String, CaseIterable, Codable, Identifiable {
    case stemSwap, dropSwap, longBlend, echoOut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stemSwap: return "Stem Swap"
        case .dropSwap: return "Drop Swap"
        case .longBlend: return "Long Blend"
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
    /// The DJ filter that leaves a kit's hats and cymbals: a high-pass
    /// around 6 kHz.
    static let hatsFilter = 0.96
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
         loop: Int = 0, loopBack: Int = 0, hats: Bool = false) {
        self.hats = hats
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
                      under: Double = 0, loop: Int = 0, loopBack: Int = 0, hats: Bool = false) -> [Lane] {
        make(preset, lanes: lanes, start: start, barSeconds: barSeconds, bars: bars, vocalBar: vocalBar,
             keysClash: keysClash, lowSwap: lowSwap, drumsLayer: drumsLayer, drumsLinger: drumsLinger,
             vocalIn: vocalIn, vocalOut: vocalOut,
             mashup: mashup, dropMoment: dropMoment, room: room, carry: carry, under: under,
             loop: loop, loopBack: loopBack, hats: hats).lanes
    }

    /// The automation and the beat rolls of a preset.
    static func make(_ preset: TransitionPreset, lanes: [Lane], start: Double, barSeconds: Double, bars: Int,
                     vocalBar: Int? = nil, keysClash: Bool = false, lowSwap: Int? = nil,
                     drumsLayer: Bool = true, drumsLinger: Bool = true, vocalIn: Double? = nil,
                     vocalOut: Double? = nil, mashup: Bool = false, dropMoment: Bool = false, rollBeat: Int? = nil,
                     vocalOutFade: Double = 0, vocalInFade: Double = 0, room: Double = 0, carry: Bool = false,
                     under: Double = 0, loop: Int = 0, loopBack: Int = 0, hats: Bool = false) -> Made {
        var builder = TransitionBuilder(lanes: lanes, start: start, barSeconds: barSeconds, bars: bars,
                                        vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap,
                                        drumsLayer: drumsLayer, drumsLinger: drumsLinger,
                                        vocalIn: vocalIn, vocalOut: vocalOut,
                                        mashup: mashup, dropMoment: dropMoment, rollBeat: rollBeat,
                                        vocalOutFade: vocalOutFade, vocalInFade: vocalInFade, room: room, carry: carry,
                                        under: under, loop: preset == .stemSwap ? loop : 0, loopBack: loopBack,
                                        hats: hats && !drumsLayer)
        builder.clearAll()
        builder.write(preset)
        builder.writeLoop()
        for (side, stem, from, to) in builder.silences { builder.silence(side, stem, from: from, to: to) }
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
    /// Carried (see `carry`), A's is gone as B's comes in a quarter in.
    static func melodyDissolve(_ preset: TransitionPreset, bars: Int, switchAt sw: Double, mashup: Bool = false,
                               carry: Bool = false) -> Double {
        guard preset == .stemSwap else { return sw }
        let n = Double(bars), q = n / 4
        if mashup { return min(sw, max(q, n - 2)) }
        if carry { return max(0, q - 2) }
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
        } else {
            automate(.b, .vocals, .volume, [(vin, 0, .hold), (vin + 0.001, 1, .linear)])
        }
    }

    /// A part of B comes in whole on the downbeat of bar `at`, and a
    /// filter (from `filter`) opens it up by bar `open`: a DJ brings a part
    /// in with the filter, never the fader, which is what makes a blend
    /// sound like a crossfade.
    private mutating func bringIn(_ stem: StemKind, at: Double, filter: Double, open: Double) {
        automate(.b, stem, .volume, [(at, 0, .hold), (at + 0.001, 1, .linear)])
        automate(.b, stem, .filter, [(at, filter, .sCurve), (open, 0.5, .linear)])
    }

    /// A's melody from bar `at` on: a low-pass sweep and a fade into a
    /// reverb wash over two bars, under B.
    private mutating func dissolveMelody(from at: Double) {
        automate(.a, .other, .filter, [(at, 0.5, .sCurve), (at + 2, 0.2, .linear)])
        automate(.a, .other, .reverb, [(at - 0.5, 0, .linear), (at + 1.5, 0.7, .linear), (at + 4, 0, .linear)])
        automate(.a, .other, .volume, [(at, 1, .logarithmic), (at + 2, 0, .linear)])
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
    private mutating func echoOutVocal(at out: Double, send: Double = 0.8, tail: Double = 1) {
        vocalExit = out
        automate(.a, .vocals, .delay, [(out - 1, 0, .linear), (out - 0.25, send, .hold), (out + tail, 0, .linear)])
        if vocalOutFade > 0 {
            automate(.a, .vocals, .volume, [(out - vocalOutFade, 1, .logarithmic), (out, 0, .linear)])
        } else {
            automate(.a, .vocals, .volume, [(out, 1, .hold), (out + 0.001, 0, .linear)])
        }
    }

    /// Tension into the big change at bar `at`: over the two bars before,
    /// A's beat thins (a gentle high-pass lifts the kick's weight) and its
    /// last beat is thrown into the echo, so the switch lands as a release.
    /// - Parameter drumsContinue: A's drums play on past the switch (their
    ///   own fade takes over), so the filter only eases back.
    private mutating func buildUp(to at: Double, drumsContinue: Bool) {
        guard at >= 2 else { return }
        automate(.a, .drums, .filter, [(at - 2, 0.5, .exponential), (at - 0.001, 0.63, .hold),
                                       (at, drumsContinue ? 0.5 : 0.63, .linear)])
        automate(.a, .drums, .delay, [(at - 1, 0, .exponential), (at - 0.25, 0.5, .hold), (at + 0.25, 0, .linear)])
    }

    /// The big switch at bar `at` as a moment rather than a fade: over the
    /// bar before it A's drums roll on their backbeat (eighths, sixteenths,
    /// thirty-seconds) as a high-pass lifts them and A's melody, A's bass
    /// drops out for the last two beats, B's tops step aside for the roll,
    /// and for the last half beat the music stops (only the roll's echo
    /// rings) before B lands in full.
    private mutating func buildDrop(at s: Double) {
        guard s >= 2 else { return buildUp(to: s, drumsContinue: false) }
        automate(.a, .drums, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.72, .hold), (s, 0.5, .linear)])
        automate(.a, .other, .filter, [(s - 2, 0.5, .exponential), (s - 0.125, 0.7, .hold), (s, 0.5, .linear)])
        // Only the tightest roll goes into the echo, and nothing once the
        // music stops: its first repeat fills the silence, and what's left
        // by the drop is faint, so B lands clean instead of under a smear.
        automate(.a, .drums, .delay, [(s - 0.25, 0, .hold), (s - 0.249, 0.3, .hold), (s - 0.125, 0, .linear)])
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
                // (the low kill keeps its kick out), a light high-pass
                // opening up as the switch nears.
                bringIn(.drums, at: 0, filter: 0.64, open: min(2 * q, sw))
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
            echoOutVocal(at: out)
            if keysClash {
                // A's melody washes out into a reverb tail as B's lands on
                // the swap.
                automate(.a, .other, .reverb, [(sw - 1, 0, .linear), (sw, 0.8, .hold), (sw + 0.001, 0, .linear)])
                automate(.a, .other, .volume, [(sw, 1, .hold), (sw + 0.001, 0, .linear)])
                automate(.b, .other, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
            } else if mashup {
                // B's voice is the thing heard over A's beat: its melody
                // waits for the swap, and A's dissolves under it, gone by
                // the blend's end (past it B glides home, and anything of
                // A's would drift off its beat).
                automate(.b, .other, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
                dissolveMelody(from: Self.melodyDissolve(preset, bars: bars, switchAt: sw, mashup: true))
            } else {
                // One part of B at a time, as a DJ brings them in: its tops
                // first, its melody a quarter in under a high-pass that
                // opens over the next eighth. The two melodies share at
                // most the bars from there to two past the swap, or past
                // half-way where B is still building up to a late swap (A's
                // beat and bass carry it there, not two melodies); A's then
                // dissolves (low-pass sweep into a reverb wash), so there's
                // never more than one song's harmony for long.
                bringIn(.other, at: q, filter: 0.7, open: q + max(1, q / 2))
                if under > 0.25, out > q + 0.01 {
                    // Under A's voice for as long as it sings, then up to
                    // full on the beat it leaves on: a step, not a fade.
                    let held = pow(10, -min(under, 12) / 20)
                    automate(.b, .other, .volume, [(q + 0.002, held, .hold), (out, held, .hold), (out + 0.001, 1, .linear)])
                }
                dissolveMelody(from: Self.melodyDissolve(preset, bars: bars, switchAt: sw, carry: carry))
            }
            if drumsLayer && drumsLinger && sw < n && !dropMoment {
                // A's tops thin out and hand over.
                automate(.a, .drums, .filter, [(3 * q, 0.5, .sCurve), (4 * q, 0.78, .linear)])
                automate(.a, .drums, .volume, [(3 * q, 1, .logarithmic), (4 * q, 0, .linear)])
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
                // B's tops from the first downbeat, opening up like a riser.
                automate(.b, .drums, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
                automate(.b, .drums, .filter, [(0, 0.8, .exponential), (h - 0.001, 0.62, .hold), (h, 0.5, .linear)])
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
                // A taste of B's melody over A's build, thin, then whole on
                // the drop: the two songs are heard together first.
                automate(.b, .other, .volume, [(h / 2, 0, .hold), (h / 2 + 0.001, 1, .linear)])
                automate(.b, .other, .filter, [(h / 2, 0.76, .hold), (h - 0.001, 0.72, .hold), (h, 0.5, .linear)])
                automate(.b, .other, .low, [(h, 0, .hold), (h + 0.001, 0.5, .linear)])
            }
            for stem in [StemKind.drums, .bass] {
                automate(.a, stem, .volume, [(h, 1, .hold), (h + 0.001, 0, .linear)])
            }
            // A's melody carries low end too (synth bass, 808s): it goes on
            // the drop, under B's bass line, while the rest of it dissolves.
            automate(.a, .other, .low, [(h, 0.5, .hold), (h + 0.001, 0, .linear)])
            if keysClash {
                automate(.a, .other, .reverb, [(h - 1, 0, .linear), (h, 0.8, .hold), (h + 0.001, 0, .linear)])
                automate(.a, .other, .volume, [(h, 1, .hold), (h + 0.001, 0, .linear)])
            } else {
                dissolveMelody(from: h)
            }
            echoOutVocal(at: out, send: 0.85)
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
            // Melody stems carry low end too: theirs trade places with the rest.
            automate(.b, .other, .low, [(2 * q, 0, .hold), (2 * q + 0.001, 0.5, .linear)])
            automate(.a, .other, .low, [(2 * q, 0.5, .hold), (2 * q + 0.001, 0, .linear)])
            handOverVocalLows(at: 2 * q)
            // B's drums come in whole on the first downbeat, their low end
            // killed; its bass line on the swap, as A's leaves (one line at
            // a time, lows or not).
            automate(.b, .drums, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
            automate(.b, .bass, .volume, [(2 * q, 0, .hold), (2 * q + 0.001, 1, .linear)])
            automate(.a, .bass, .volume, [(2 * q, 1, .hold), (2 * q + 0.001, 0, .linear)])
            // The voices hand over like a Drop Swap's: B's from the swap,
            // between lines where the caller found them; A's until then.
            let vin = max(2 * q, vocalIn ?? v)
            echoOutVocal(at: min(vocalOut ?? min(vin, 2 * q), keysClash ? 2 * q : n))
            if keysClash {
                automate(.a, .other, .reverb, [(2 * q - 1, 0, .linear), (2 * q, 0.8, .hold), (2 * q + 0.001, 0, .linear)])
                automate(.a, .other, .volume, [(2 * q, 1, .hold), (2 * q + 0.001, 0, .linear)])
                automate(.b, .other, .volume, [(2 * q, 0, .hold), (2 * q + 0.001, 1, .linear)])
            } else {
                bringIn(.other, at: 0, filter: 0.16, open: 2 * q)
                automate(.a, .other, .filter, [(2 * q, 0.5, .sCurve), (4 * q, 0.76, .linear)])
                automate(.a, .other, .volume, [(2 * q, 1, .logarithmic), (4 * q, 0, .linear)])
            }
            automate(.a, .drums, .volume, [(3 * q, 1, .sCurve), (4 * q, 0, .linear)])
            bringInVocal(at: vin)

        case .echoOut where n <= 1:
            // A cut on the one, for tempos too far apart to blend: what a
            // club DJ does rather than play a record everyone knows 15 %
            // off its tempo. A plays whole, at its own tempo, to the end
            // of its phrase; over its last bar its beat lifts (a gentle
            // high-pass) and its last beat goes into the echo, timed to A,
            // which rings on into half a beat of silence. Then B lands
            // whole on its downbeat at its own tempo. The beat stops for
            // that half-beat only: no bridge for the floor to cool in.
            for stem in [StemKind.drums, .bass, .other] {
                automate(.a, stem, .volume, [(-0.125, 1, .hold), (-0.124, 0, .linear)])
            }
            automate(.a, .drums, .filter, [(-1, 0.5, .exponential), (-0.126, 0.6, .hold)])
            automate(.a, .drums, .delay, [(-0.5, 0, .exponential), (-0.25, 0.5, .hold), (0, 0, .linear)])
            automate(.a, .other, .reverb, [(-0.5, 0, .linear), (-0.125, 0.6, .hold), (0.001, 0, .linear)])
            // B's voice with its beat, or a beat before on a pickup.
            let vin = max(-AutoPlacement.pickup, min(0, vocalIn ?? 0))
            // A's voice leaves on a line end in its last bars, at the cut
            // (or B's pickup) at the latest, thrown into the echo.
            let out = max(-4, min(-0.125, vin, vocalOut ?? -0.125))
            echoOutVocal(at: out, send: 0.85, tail: max(0.25, min(1, -out)))
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
                automate(.a, stem, .filter, [(-max(e / 2, 2 * half), 0.5, .sCurve), (-half, 0.2, .linear)])
                automate(.a, stem, .volume, [(-max(e / 2, 2 * half), 1, .logarithmic), (-half, 0, .linear)])
            }
            automate(.a, .drums, .delay, [(-half - 1, 0, .exponential), (-half - 0.25, 0.6, .hold), (-half + 0.5, 0, .linear)])
            // A's melody floats on into a reverb wash, whole, until the
            // music stops for half a beat before B's downbeat (a fade from
            // a bar out left two near-silent bars).
            automate(.a, .other, .reverb, [(-half, 0, .linear), (-0.5, 0.75, .hold), (0.001, 0, .linear)])
            automate(.a, .other, .volume, [(-0.125, 1, .hold), (-0.124, 0, .linear)])
            // The echo is timed to A's tempo: its send closes by B's
            // downbeat, so no more than its last repeats ring over B's beat.
            let vin = max(-AutoPlacement.pickup, min(0, vocalIn ?? 0))
            let out = max(-e, min(vin, vocalOut ?? -1))
            echoOutVocal(at: out, send: 0.85, tail: max(0.25, min(2, -out)))
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
