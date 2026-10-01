import AppKit
import Foundation

struct Deck {
    enum Status: Equatable {
        case empty
        case decoding
        case separating(Double)
        case analyzing
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .decoding, .separating, .analyzing: return true
            default: return false
            }
        }
    }

    var url: URL?
    var status: Status = .empty
    var loaded: TrackProcessor.Loaded?

    var title: String { url.map(SongTitle.of) ?? "No track loaded" }
    var analysis: TrackAnalysis? { loaded?.analysis }
}

/// Playhead state lives apart from the session so its 30 Hz updates redraw
/// only the playhead, not eight waveforms.
@MainActor
final class Transport: ObservableObject {
    @Published var seconds: Double = 0
    @Published var isPlaying = false
}

@MainActor
final class Session: ObservableObject {
    @Published private(set) var deckA = Deck()
    @Published private(set) var deckB = Deck()
    @Published var lanes: [Lane] = Lane.allLanes() {
        didSet {
            rebuildSnapshot()
            host?.editorMonitorChanged()
            editChanged()
        }
    }

    /// Beat rolls, on the same timeline as the lanes. Set before `lanes`
    /// wherever both change, so the lanes' update carries both.
    private(set) var rolls: [Roll] = []

    /// A's bar on which B's cue bar lands.
    @Published var entryBar = 0 {
        didSet {
            guard entryBar != oldValue else { return }
            if !isRestoring && !isPlacing {
                pushUndo(Arrangement(lanes: lanes, rolls: rolls, entryBar: oldValue, cueBar: cueBar, preset: preset,
                                     bars: transitionBars))
            }
            alignmentChanged(from: oldValue)
            editChanged()
        }
    }
    /// B's bar (usually its first downbeat) that lines up with `entryBar`.
    @Published var cueBar = 0 {
        didSet {
            guard cueBar != oldValue else { return }
            if !isRestoring && !isPlacing {
                pushUndo(Arrangement(lanes: lanes, rolls: rolls, entryBar: entryBar, cueBar: oldValue, preset: preset,
                                     bars: transitionBars))
            }
            alignmentChanged(from: nil)
            editChanged()
        }
    }
    @Published var semitones = 0
    @Published var autoKey = true
    @Published var preset: TransitionPreset = .stemSwap {
        didSet { if preset != oldValue { scheduleRematch(); editChanged() } }
    }
    @Published var transitionBars = TransitionPreset.stemSwap.defaultBars {
        didSet { if transitionBars != oldValue { scheduleRematch(); editChanged() } }
    }
    @Published var masterVolume: Double = 0.85 { didSet { rebuildSnapshot() } }

    @Published private(set) var matched: TrackProcessor.Matched?
    @Published private(set) var matchStatus: String?
    @Published private(set) var exportProgress: Double?
    @Published var alert: String?

    let transport = Transport()
    private let playback = PlaybackEngine()
    private let processor = TrackProcessor()
    private var loadTickets: [DeckSide: TrackProcessor.Ticket] = [:]
    private var matchTicket: TrackProcessor.Ticket?
    private var pendingPlan: TrackProcessor.MatchPlan?
    private var rematchTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var clock: Timer?

    init() {
        clock = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func deck(_ side: DeckSide) -> Deck { side == .a ? deckA : deckB }

    // MARK: - Editing a set's transition

    /// The set whose transition this editor shows. Edits go back to it, and
    /// its player plays: the editor's timeline is A's own clock, the set's
    /// is `hostOffset` ahead of it.
    weak var host: SetSession?
    var hostOffset = 0.0
    /// Changes whenever a different transition is opened.
    @Published private(set) var pairID = UUID()
    /// "3 → 4": which transition of the set this is.
    @Published private(set) var transitionTitle: String?
    /// Bars of A the set lets the transition start on.
    @Published var entryRange: ClosedRange<Int>?
    /// Shaped by hand, rather than the automatic plan.
    @Published private(set) var isEdited = false
    private var isOpening = false
    /// What was last opened or sent to the host: only a real change (not a
    /// mute, solo or which parameter a lane shows) counts as an edit.
    private var baseline: TransitionEdit?

    var hasPair: Bool { deckA.loaded != nil && deckB.loaded != nil }

    var currentEdit: TransitionEdit {
        TransitionEdit(entryBar: entryBar, cueBar: cueBar, preset: preset, bars: transitionBars,
                       semitones: semitones, lanes: lanes, rolls: rolls)
    }

    /// Shows one transition of a set, exactly as the set plays it.
    func open(title: String, a: Deck, b: Deck, edit: TransitionEdit, isEdited: Bool, matched: TrackProcessor.Matched?,
              placement: AutoPlacement.Result, placedAs: (preset: TransitionPreset, bars: Int),
              entryRange: ClosedRange<Int>, offset: Double) {
        isOpening = true
        isRestoring = true
        defer { isOpening = false; isRestoring = false }
        for ticket in loadTickets.values { ticket.cancel() }
        rematchTask?.cancel()
        matchTicket?.cancel()
        matchTicket = nil
        pendingPlan = nil
        matchStatus = nil
        deckA = a
        deckB = b
        // In a set, the plan's key shift (if any) is what B plays at.
        autoKey = edit.semitones == 0
        keyClash = nil
        semitones = edit.semitones
        preset = edit.preset
        transitionBars = edit.bars
        cueBar = edit.cueBar
        entryBar = edit.entryBar
        // What placement found holds where it placed: the plan's preset
        // and length, its entry and cue. A hand edit keeps where vocals and
        // lows change hands, not a mashup or roll it may no longer suit.
        placedFor = Placed(preset: placedAs.preset, bars: placedAs.bars,
                           entryBar: isEdited ? placement.entryBar : edit.entryBar,
                           cueBar: isEdited ? placement.cueBar : edit.cueBar,
                           mashup: !isEdited && placement.mashup, dropMoment: !isEdited && placement.dropMoment,
                           lowSwap: placement.lowSwap, vocalHandoff: placement.vocalHandoff)
        placementNote = isEdited || placement.reason.isEmpty ? nil : placement.reason
        self.matched = matched
        rolls = edit.rolls
        lanes = edit.lanes
        self.entryRange = entryRange
        self.isEdited = isEdited
        hostOffset = offset
        transitionTitle = title
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoState()
        baseline = currentEdit
        pairID = UUID()
        rebuildSnapshot()
        syncTransport()
    }

    func close() {
        isOpening = true
        defer { isOpening = false }
        deckA = Deck()
        deckB = Deck()
        matched = nil
        transitionTitle = nil
        pairID = UUID()
    }

    private func editChanged() {
        guard let host, !isOpening, !isRestoring, hasPair else { return }
        let edit = currentEdit
        if let baseline, Self.sameContent(baseline, edit) { return }
        baseline = edit
        isEdited = true
        placementNote = nil
        host.editorChanged(edit)
    }

    private static func sameContent(_ a: TransitionEdit, _ b: TransitionEdit) -> Bool {
        a.entryBar == b.entryBar && a.cueBar == b.cueBar && a.preset == b.preset && a.bars == b.bars
            && a.semitones == b.semitones && a.lanes.map(\.envelopes) == b.lanes.map(\.envelopes) && a.rolls == b.rolls
    }

    /// Keeps the transition exactly as it is, as a hand edit: later changes
    /// elsewhere in the set no longer re-plan it.
    func keepAsEdited() {
        guard let host, hasPair, !isEdited else { return }
        isEdited = true
        placementNote = nil
        baseline = currentEdit
        host.editorChanged(currentEdit)
    }

    /// Mute and solo, for the set's player.
    func isAudible(_ side: DeckSide, _ stem: StemKind) -> Bool {
        let anySolo = lanes.contains(where: \.isSoloed)
        guard let lane = lanes.first(where: { $0.side == side && $0.stem == stem }) else { return true }
        return !lane.isMuted && (!anySolo || lane.isSoloed)
    }

    /// Mirrors the set's playhead on the editor's clock.
    func syncTransport() {
        guard let host else { return }
        let seconds = host.transport.seconds - hostOffset
        if abs(transport.seconds - seconds) > 1e-4 { transport.seconds = seconds }
        if transport.isPlaying != host.transport.isPlaying { transport.isPlaying = host.transport.isPlaying }
    }

    private func setDeck(_ side: DeckSide, _ update: (inout Deck) -> Void) {
        if side == .a { update(&deckA) } else { update(&deckB) }
    }

    // MARK: - Loading

    func load(_ url: URL, into side: DeckSide) {
        pause()
        loadTickets[side]?.cancel()
        let ticket = TrackProcessor.Ticket()
        loadTickets[side] = ticket
        matchTicket?.cancel()
        matchTicket = nil
        pendingPlan = nil
        matched = nil
        setDeck(side) { $0 = Deck(url: url, status: .decoding) }
        rebuildSnapshot()

        processor.load(url, ticket: ticket, progress: { [weak self] progress in
            Task { @MainActor in
                guard let self, self.loadTickets[side] === ticket else { return }
                self.setDeck(side) {
                    switch progress {
                    case .decoding: $0.status = .decoding
                    case .separating(let p): $0.status = .separating(p)
                    case .analyzing: $0.status = .analyzing
                    }
                }
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.loadTickets[side] === ticket else { return }
                switch result {
                case .success(let loaded):
                    self.setDeck(side) { $0.loaded = loaded; $0.status = .ready }
                    self.decksChanged(loadedSide: side)
                case .failure(let error):
                    if error is CancellationError { return }
                    self.setDeck(side) { $0.status = .failed(error.localizedDescription) }
                }
            }
        })
    }

    private func decksChanged(loadedSide: DeckSide) {
        // A new track makes the old choreography meaningless; the preset is
        // re-applied once B has been matched.
        resetAutomation()
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoState()
        if loadedSide == .b || deckB.loaded == nil { cueBar = 0 }
        if let a = deckA.analysis, let b = deckB.analysis {
            if autoKey { semitones = autoShift(a: a, b: b) }
            preset = recommendedPreset
            transitionBars = preset.defaultBars
            place(a: a, b: b)
            rematch()
        }
        rebuildSnapshot()
    }

    // MARK: - Matching

    /// B's tempo relative to A, folded by an octave when the two were
    /// detected at half/double time of each other.
    var tempoMultiplier: Double {
        guard let a = deckA.analysis?.grid.bpm, let b = deckB.analysis?.grid.bpm else { return 1 }
        return MixMath.tempoMultiplier(a: a, b: b)
    }

    /// B's rate relative to its own tempo while it plays under A.
    var rate: Double {
        guard let a = deckA.analysis?.grid.bpm, let b = deckB.analysis?.grid.bpm else { return 1 }
        return MixMath.rate(a: a, b: b)
    }

    /// The rate B is actually matched at. Wash Out never layers the two
    /// tracks, so B keeps its own tempo and only its downbeat is lined up.
    var matchRate: Double { preset == .echoOut ? 1 : rate }

    /// B's grid as heard while matched, on B's own clock. Bars stay B's own
    /// bars (the ones its structure and cue bar are counted in), even when
    /// it runs half- or double-time against A.
    var matchedGridB: BeatGrid? {
        deckB.analysis?.grid.scaled(by: matchRate)
    }

    var glideBars: Int { MixMath.glideBars(rate: matchRate) }

    var masterGrid: BeatGrid? { deckA.analysis?.grid }

    func trimDB(_ side: DeckSide) -> Double { MixMath.trimDB(deck(side).analysis) }

    var keyAfterShift: MusicalKey? { deckB.analysis?.key.transposed(by: semitones) }

    /// Nil when the keys sit together; otherwise why the melodies swap.
    @Published private(set) var keyClash: String?

    /// Songs keep their own key: a known song even a semitone off sounds
    /// wrong for all of its time. Where the keys clash the melodies swap
    /// rather than layer, and the panel says which shift would let them
    /// layer, for the user to choose.
    private func autoShift(a: TrackAnalysis, b: TrackAnalysis) -> Int {
        if b.key.harmonicShift(toMatch: a.key, limit: 0) != nil {
            keyClash = nil
        } else if let shift = b.key.harmonicShift(toMatch: a.key, limit: 2) {
            keyClash = "Keys clash (\(b.key.camelotCode) vs \(a.key.camelotCode)): the melodies swap instead of layering. Shifting B by \(shift > 0 ? "+" : "")\(shift) st would let them layer."
        } else {
            keyClash = "Keys clash (\(b.key.camelotCode) vs \(a.key.camelotCode)) and fixing it takes a big pitch shift. The melodies swap instead of layering."
        }
        return 0
    }

    /// B's key (after the shift) doesn't sit with A's.
    var keysIncompatible: Bool {
        guard let a = deckA.analysis?.key, let b = keyAfterShift else { return false }
        return b.harmonicShift(toMatch: a, limit: 0) == nil
    }

    var recommendedPreset: TransitionPreset {
        tempoMultiplier != 1 ? .echoOut : MixMath.recommendedPreset(rate: rate)
    }

    func setSemitones(_ value: Int, auto: Bool = false) {
        autoKey = auto
        if !auto { keyClash = nil }
        let automatic = host != nil ? 0 : (deckB.analysis.flatMap { b in deckA.analysis.map { autoShift(a: $0, b: b) } } ?? 0)
        let value = auto ? automatic : value
        guard value != semitones || matched == nil else { return }
        semitones = max(-6, min(6, value))
        rematch()
        editChanged()
    }

    /// What B should be rendered as for the current arrangement: matched to
    /// A until the transition is over, then back to its own tempo.
    private var desiredPlan: TrackProcessor.MatchPlan? {
        guard deckA.loaded != nil, deckB.loaded != nil, let g = masterGrid else { return nil }
        let sr = AudioIO.sampleRate
        // As in a set: B glides home once A's melody has dissolved.
        let tail = preset == .stemSwap
            ? SetBuilder.exitTail(bars: transitionBars, lowSwap: placedHere?.lowSwap) : 0
        let map = TimeMap.glide(rate: matchRate, rampStart: (transitionEnd + Double(tail) * g.barSeconds - offsetB) * sr,
                                rampLength: Double(glideBars) * g.barSeconds * sr)
        return .init(map: map, semitones: semitones)
    }

    /// Moving the transition moves where B's glide starts, so B is
    /// re-rendered, once the edits settle.
    private func scheduleRematch() {
        guard deckB.loaded != nil, deckA.loaded != nil else { return }
        rematchTask?.cancel()
        rematchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.rematch()
        }
    }

    private func rematch() {
        rematchTask?.cancel()
        guard let b = deckB.loaded, let plan = desiredPlan else { return }
        if pendingPlan?.isSame(as: plan) == true || (pendingPlan == nil && matched?.plan.isSame(as: plan) == true) { return }
        matchTicket?.cancel()
        let ticket = TrackProcessor.Ticket()
        matchTicket = ticket
        pendingPlan = plan
        // When only the glide moved, the old rendition is identical up to
        // where it glided: keep playing it until the new one is ready.
        if let old = matched, old.plan.map.rate != plan.map.rate || old.plan.semitones != plan.semitones {
            matched = nil
        }
        matchStatus = "Matching tempo & key…"
        rebuildSnapshot()
        processor.match(b, plan: plan, ticket: ticket) { [weak self] result in
            Task { @MainActor in
                guard let self, self.matchTicket === ticket else { return }
                self.matchStatus = nil
                self.matchTicket = nil
                self.pendingPlan = nil
                switch result {
                case .success(let m):
                    self.matched = m
                    if self.host == nil, self.lanes.allSatisfy({ $0.envelopes.allSatisfy(\.isEmpty) }) { self.writePreset() }
                    self.rebuildSnapshot()
                    // The arrangement may have moved on while this rendered.
                    if let plan = self.desiredPlan, !plan.isSame(as: m.plan) { self.scheduleRematch() }
                case .failure(let error):
                    if !(error is CancellationError) { self.alert = error.localizedDescription }
                }
            }
        }
    }

    // MARK: - Arrangement

    /// Master-timeline seconds at which B's frame 0 plays.
    var offsetB: Double {
        guard let a = masterGrid, let b = matchedGridB else { return 0 }
        return a.downbeat(entryBar) - b.downbeat(cueBar)
    }

    var transitionStart: Double { masterGrid?.downbeat(entryBar) ?? 0 }

    var transitionEnd: Double {
        guard let g = masterGrid else { return 0 }
        return preset == .echoOut ? g.downbeat(entryBar) : g.downbeat(entryBar + transitionBars)
    }

    var barCountA: Int { deckA.analysis.map { $0.grid.barCount(duration: $0.duration) } ?? 0 }
    var barCountB: Int { deckB.analysis.map { $0.grid.barCount(duration: $0.duration) } ?? 0 }

    var lengthSeconds: Double {
        let a = deckA.analysis?.duration ?? 0
        guard let b = matched?.stems.values.map(\.count).max() else { return a }
        return max(a, offsetB + Double(b) / AudioIO.sampleRate)
    }

    func peaks(for lane: Lane) -> [Float]? {
        lane.side == .a ? deckA.loaded?.peaks[lane.stem] : matched?.peaks[lane.stem]
    }

    func laneOffset(_ lane: Lane) -> Double { lane.side == .a ? 0 : offsetB }

    /// Moving the entry point drags the automation with it, so a transition
    /// you've shaped by hand survives being slid to a different phrase.
    private func alignmentChanged(from oldEntry: Int?) {
        if !isRestoring, let oldEntry, let g = masterGrid {
            let shift = g.downbeat(entryBar) - g.downbeat(oldEntry)
            rolls = rolls.map { $0.shifted(by: shift) }
            for i in lanes.indices {
                for p in LaneParameter.allCases {
                    var moved = Envelope()
                    for point in lanes[i][p].points {
                        var q = point
                        q.time += shift
                        moved.insert(q)
                    }
                    lanes[i][p] = moved
                }
            }
        }
        rebuildSnapshot()
        scheduleRematch()
    }

    /// What auto placement found, for the preset, length and spot it
    /// placed: a mashup, a roll into the drop, and the bars (from B's
    /// entry) where B's vocal comes in and the low end changes hands.
    private struct Placed {
        let preset: TransitionPreset, bars: Int, entryBar: Int, cueBar: Int
        let mashup: Bool, dropMoment: Bool
        let lowSwap: Int?, vocalHandoff: Int?
    }
    private var placedFor: Placed?
    /// `placedFor`, if it was placed for the preset, length and spot in
    /// use. Anywhere else it's another song's bars: a Drop Swap's half-way
    /// (bar 4 of 8) is a quarter into a 16-bar Stem Swap, and a low swap
    /// on B's drop lands in B's verse once B is moved.
    private var placedHere: Placed? {
        placedFor.flatMap {
            $0.preset == preset && $0.bars == transitionBars && $0.entryBar == entryBar && $0.cueBar == cueBar ? $0 : nil
        }
    }

    /// Why the automatic placement chose what it did, shown in the panel.
    @Published private(set) var placementNote: String?

    private func place(a: TrackAnalysis, b: TrackAnalysis) {
        let result = AutoPlacement.place(a: a, b: b, bars: transitionBars, preset: preset,
                                         trimA: Float(trimDB(.a)), trimB: Float(trimDB(.b)), keysClash: keysIncompatible,
                                         mashup: !keysIncompatible && abs(matchRate - 1) < MixMath.mashupStretch,
                                         bShift: semitones)
        placedFor = Placed(preset: preset, bars: transitionBars, entryBar: result.entryBar, cueBar: result.cueBar,
                           mashup: result.mashup, dropMoment: result.dropMoment, lowSwap: result.lowSwap,
                           vocalHandoff: result.vocalHandoff)
        isPlacing = true
        defer { isPlacing = false }
        cueBar = result.cueBar
        entryBar = result.entryBar
        placementNote = result.reason.isEmpty ? nil : result.reason
    }

    /// Re-pick the entry and cue bars for the current preset and length,
    /// then write the preset there.
    func autoArrange() {
        if let host { return host.revertToAuto() }
        guard let a = deckA.analysis, let b = deckB.analysis else { return }
        checkpoint()
        resetAutomation()
        place(a: a, b: b)
        writePreset()
    }

    /// Picking a preset or a length rewrites the automation with it.
    func choosePreset(_ p: TransitionPreset) {
        guard p != preset else { return }
        checkpoint()
        preset = p
        transitionBars = p.defaultBars
        writePreset()
    }

    func chooseBars(_ bars: Int) {
        guard bars != transitionBars else { return }
        checkpoint()
        transitionBars = bars
        writePreset()
    }

    func applyPreset() {
        checkpoint()
        writePreset()
    }

    private func writePreset() {
        guard let g = masterGrid else { return }
        let placed = placedHere
        let made = TransitionBuilder.make(preset, lanes: lanes, start: g.downbeat(entryBar),
                                          barSeconds: g.barSeconds, bars: transitionBars, vocalBar: placed?.vocalHandoff,
                                          keysClash: keysIncompatible,
                                          lowSwap: placed?.lowSwap,
                                          mashup: placed?.mashup ?? false, dropMoment: placed?.dropMoment ?? false,
                                          vocalOutFade: vocalFade(.a), vocalInFade: vocalFade(.b) / 2)
        rolls = made.rolls
        lanes = made.lanes
    }

    /// The editor places vocals on the bar grid, not between lines: where
    /// the vocal is singing at that bar, a cut would chop a word, so it
    /// blends (1 bar for A's exit; B's entry uses half).
    private func vocalFade(_ side: DeckSide) -> Double {
        guard let g = masterGrid, let stem = side == .a ? deckA.loaded?.stems[.vocals] : matched?.stems[.vocals],
              let ref = VocalPhrasing.reference(deck(side).analysis?.structure) else { return 1 }
        let probe = TransitionBuilder.make(preset, lanes: Lane.allLanes(), start: g.downbeat(entryBar), barSeconds: g.barSeconds,
                                           bars: transitionBars, vocalBar: placedHere?.vocalHandoff,
                                           keysClash: keysIncompatible, lowSwap: placedHere?.lowSwap,
                                           mashup: placedHere?.mashup ?? false, dropMoment: placedHere?.dropMoment ?? false)
        let beat = g.barSeconds / 4
        if side == .a, let exit = probe.vocalExit {
            let t = g.downbeat(entryBar) + exit * g.barSeconds
            return VocalPhrasing.sounding(stem, offset: 0, reference: ref, at: t, beat: beat) ? 1 : 0
        }
        if side == .b, let entry = probe.vocalEntry {
            let t = g.downbeat(entryBar) + entry * g.barSeconds - beat
            return VocalPhrasing.sounding(stem, offset: offsetB, reference: ref, at: t, beat: beat) ? 1 : 0
        }
        return 0
    }

    func clearAutomation() {
        checkpoint()
        resetAutomation()
    }

    private func resetAutomation() {
        rolls = []
        for i in lanes.indices {
            for p in LaneParameter.allCases { lanes[i][p].removeAll() }
        }
    }

    // MARK: - Lane editing

    /// - Parameter undoable: false for the continuous updates of a drag,
    ///   whose undo step was recorded when it began.
    func updateLane(_ id: String, undoable: Bool = true, _ change: (inout Lane) -> Void) {
        guard let i = lanes.firstIndex(where: { $0.id == id }) else { return }
        if undoable { checkpoint() }
        change(&lanes[i])
    }

    // MARK: - Undo

    private struct Arrangement {
        var lanes: [Lane]
        var rolls: [Roll]
        var entryBar: Int
        var cueBar: Int
        var preset: TransitionPreset
        var bars: Int
    }

    private var undoStack: [Arrangement] = []
    private var redoStack: [Arrangement] = []
    private var isRestoring = false
    private var isPlacing = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var currentArrangement: Arrangement {
        Arrangement(lanes: lanes, rolls: rolls, entryBar: entryBar, cueBar: cueBar, preset: preset, bars: transitionBars)
    }

    /// Records the arrangement as it is now, before an edit.
    func checkpoint() { pushUndo(currentArrangement) }

    private func pushUndo(_ state: Arrangement) {
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoState()
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        redoStack.append(currentArrangement)
        restore(state)
    }

    func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append(currentArrangement)
        restore(state)
    }

    private func restore(_ state: Arrangement) {
        isRestoring = true
        preset = state.preset
        transitionBars = state.bars
        entryBar = state.entryBar
        cueBar = state.cueBar
        rolls = state.rolls
        lanes = state.lanes
        isRestoring = false
        rebuildSnapshot()
        updateUndoState()
        editChanged()
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Grid correction

    enum GridEdit {
        case halve, double
        /// Move the downbeat by whole beats (fixes a wrong bar phase).
        case shiftBeats(Int)
        /// Move the whole grid by milliseconds.
        case nudge(Double)
    }

    /// Manual override for when beat detection gets a track wrong. Rebuilds
    /// the placement and matching from the corrected grid.
    func adjustGrid(_ side: DeckSide, _ edit: GridEdit) {
        guard var loaded = deck(side).loaded else { return }
        var grid = loaded.analysis.grid
        switch edit {
        // Nothing plays slower than 60 or faster than 200: past that a second
        // click would only break the grid (Beauty And A Beat once reached
        // 512 BPM that way).
        case .halve: guard grid.bpm / 2 >= 60 else { return }; grid.bpm /= 2
        case .double: guard grid.bpm * 2 <= 200 else { return }; grid.bpm *= 2
        case .shiftBeats(let k): grid.firstDownbeat += Double(k) * grid.beatSeconds
        case .nudge(let ms): grid.firstDownbeat += ms / 1000
        }
        while grid.firstDownbeat >= grid.barSeconds { grid.firstDownbeat -= grid.barSeconds }
        while grid.firstDownbeat < 0 { grid.firstDownbeat += grid.barSeconds }
        loaded.analysis.grid = grid
        loaded.analysis.structure = TrackStructure.measure(stems: loaded.stems, grid: grid)
        StemCache.saveAnalysis(loaded.analysis, to: loaded.directory)
        setDeck(side) { $0.loaded = loaded }
        if let host, let url = deck(side).url { return host.gridChanged(url, loaded) }
        decksChanged(loadedSide: side)
    }

    /// Beat grid of whatever leads at each moment: A's, until B starts
    /// gliding back to its own tempo; B's own from there on.
    struct GridLine {
        var time: Double
        var bar: Int
        /// 0 on the downbeat.
        var beat: Int
    }

    /// Where B's grid takes over, with what's needed to place its beats.
    private var gridB: (from: Double, grid: BeatGrid, map: TimeMap, offset: Double)? {
        guard let m = matched, m.plan.map.hasGlide, let g = deckB.analysis?.grid else { return nil }
        return (offsetB + m.plan.map.rampStart / AudioIO.sampleRate, g, m.plan.map, offsetB)
    }

    /// Master-timeline span over which B glides back to its own tempo.
    var glideRange: ClosedRange<Double>? {
        guard let b = gridB else { return nil }
        return b.from...(b.offset + b.map.rampEnd / AudioIO.sampleRate)
    }

    func gridLines(from t0: Double, to t1: Double, barStep: Int, beats: Bool) -> [GridLine] {
        guard let a = masterGrid else { return [] }
        let sr = AudioIO.sampleRate
        var lines: [GridLine] = []
        func add(_ time: Double, _ index: Int) {
            let bar = Int((Double(index) / 4).rounded(.down)), beat = index - 4 * bar
            guard beats || beat == 0, beat != 0 || bar % barStep == 0 else { return }
            lines.append(GridLine(time: time, bar: bar, beat: beat))
        }
        let b = gridB
        let aEnd = min(t1, b?.from ?? t1)
        if t0 < aEnd {
            var i = Int(((t0 - a.firstDownbeat) / a.beatSeconds).rounded(.down)) - 4
            while a.beat(i) <= aEnd {
                if a.beat(i) >= t0 - a.barSeconds && a.beat(i) < aEnd { add(a.beat(i), i) }
                i += 1
            }
        }
        if let b, t1 > b.from {
            let from = max(t0, b.from)
            let sourceSeconds = { (t: Double) in b.map.source((t - b.offset) * sr) / sr }
            var i = Int(((sourceSeconds(from) - b.grid.firstDownbeat) / b.grid.beatSeconds).rounded(.down))
            while true {
                let t = b.offset + b.map.output(b.grid.beat(i) * sr) / sr
                if t > t1 + b.grid.barSeconds { break }
                if t >= from { add(t, i) }
                i += 1
            }
        }
        return lines
    }

    /// Snaps to the beats of the grid in force there (or finer when zoomed in).
    func snap(_ seconds: Double, division: Double) -> Double {
        let sr = AudioIO.sampleRate
        if let b = gridB, seconds >= b.from {
            let step = b.grid.beatSeconds / division
            let x = b.map.source((seconds - b.offset) * sr) / sr
            let snapped = b.grid.firstDownbeat + ((x - b.grid.firstDownbeat) / step).rounded() * step
            return b.offset + b.map.output(snapped * sr) / sr
        }
        guard let g = masterGrid else { return seconds }
        let step = g.beatSeconds / division
        return g.firstDownbeat + ((seconds - g.firstDownbeat) / step).rounded() * step
    }

    // MARK: - Rendering

    /// - Parameter including: lanes to render (the rest are silent), for
    ///   measuring one side or stem of the mix on its own.
    func makeSnapshot(including: (Lane) -> Bool = { _ in true }) -> MixSnapshot {
        let anySolo = lanes.contains(where: \.isSoloed)
        let sr = AudioIO.sampleRate
        let data = lanes.map { lane -> MixSnapshot.LaneData in
            let audio = lane.side == .a ? deckA.loaded?.stems[lane.stem] : matched?.stems[lane.stem]
            return MixSnapshot.LaneData(
                audio: audio,
                offset: Int((laneOffset(lane) * sr).rounded()),
                envelopes: lane.envelopes,
                audible: !lane.isMuted && (!anySolo || lane.isSoloed) && including(lane),
                trim: Float(pow(10, trimDB(lane.side) / 20)),
                rolls: rolls.filter { $0.side == lane.side && $0.stem == lane.stem }.sorted { $0.start < $1.start }
                    .compactMap { MixSnapshot.FrameRoll($0, sampleRate: sr) })
        }
        // Dotted-eighth echo: syncopated against the grid, so repeats sit
        // between the kicks instead of on top of them.
        let beat = masterGrid?.beatSeconds ?? 0.5
        return MixSnapshot(lanes: data, length: Int(lengthSeconds * sr), delaySeconds: beat * 0.75,
                           masterGain: Float(masterVolume))
    }

    private func rebuildSnapshot() {
        playback.renderer.setSnapshot(makeSnapshot())
    }

    // MARK: - Transport

    func togglePlay() {
        if let host { return host.togglePlay() }
        transport.isPlaying ? pause() : play()
    }

    func play() {
        if let host { return host.play() }
        guard deckA.loaded != nil || matched != nil else { return }
        if transport.seconds >= lengthSeconds { seek(to: 0) }
        do {
            try playback.play()
            transport.isPlaying = true
        } catch {
            alert = "Couldn't start audio: \(error.localizedDescription)"
        }
    }

    func pause() {
        if let host { return host.pause() }
        playback.pause()
        transport.isPlaying = false
    }

    func seek(to seconds: Double) {
        if let host {
            host.seek(to: seconds + hostOffset)
            return syncTransport()
        }
        let s = max(0, min(seconds, lengthSeconds))
        playback.renderer.seek(to: Int(s * AudioIO.sampleRate))
        transport.seconds = s
    }

    /// Cue a few bars before B enters: the one place you'll audition most.
    func seekToTransition() {
        guard let g = masterGrid else { return seek(to: 0) }
        seek(to: g.downbeat(max(0, entryBar - 4)))
    }

    private func tick() {
        if host != nil { return syncTransport() }
        guard transport.isPlaying else { return }
        let s = Double(playback.renderer.currentFrame) / AudioIO.sampleRate
        transport.seconds = s
        if s >= lengthSeconds + 3 { pause() }
    }

    // MARK: - Export

    enum ExportRange { case full, transition }

    func export(_ range: ExportRange, to url: URL) {
        guard exportTask == nil else { return }
        let sr = AudioIO.sampleRate
        let frames: Range<Int>
        switch range {
        case .full:
            frames = 0..<Int(lengthSeconds * sr)
        case .transition:
            guard let g = masterGrid else { return }
            let from = g.downbeat(max(0, entryBar - 8))
            let to = min(lengthSeconds, transitionEnd + 8 * g.barSeconds)
            frames = Int(from * sr)..<Int(to * sr)
        }
        let snapshot = makeSnapshot()
        exportProgress = 0
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try Exporter.render(snapshot: snapshot, range: frames, tail: 3, to: url) { [weak self] p in
                    Task { @MainActor in self?.exportProgress = p }
                }
            }
            await self?.finishExport(result, url: url)
        }
    }

    private func finishExport(_ result: Result<Void, Error>, url: URL) {
        exportTask = nil
        exportProgress = nil
        switch result {
        case .success: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let error): alert = "Render failed: \(error.localizedDescription)"
        }
    }

    var suggestedExportName: String {
        let a = deckA.url?.deletingPathExtension().lastPathComponent ?? "A"
        let b = deckB.url?.deletingPathExtension().lastPathComponent ?? "B"
        return "\(a) → \(b).m4a"
    }
}
