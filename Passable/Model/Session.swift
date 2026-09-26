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

    var title: String { url?.deletingPathExtension().lastPathComponent ?? "No track loaded" }
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
    @Published var lanes: [Lane] = Lane.allLanes() { didSet { rebuildSnapshot() } }

    /// A's bar on which B's cue bar lands.
    @Published var entryBar = 0 {
        didSet {
            guard entryBar != oldValue else { return }
            if !isRestoring && !isPlacing { pushUndo(Arrangement(lanes: lanes, entryBar: oldValue, cueBar: cueBar)) }
            alignmentChanged(from: oldValue)
        }
    }
    /// B's bar (usually its first downbeat) that lines up with `entryBar`.
    @Published var cueBar = 0 {
        didSet {
            guard cueBar != oldValue else { return }
            if !isRestoring && !isPlacing { pushUndo(Arrangement(lanes: lanes, entryBar: entryBar, cueBar: oldValue)) }
            alignmentChanged(from: nil)
        }
    }
    @Published var semitones = 0
    @Published var autoKey = true
    @Published var preset: TransitionPreset = .stemSwap
    @Published var transitionBars = TransitionPreset.stemSwap.defaultBars
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
    private var exportTask: Task<Void, Never>?
    private var clock: Timer?

    init() {
        clock = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func deck(_ side: DeckSide) -> Deck { side == .a ? deckA : deckB }

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
        guard let a = deckA.analysis?.grid.bpm, let b = deckB.analysis?.grid.bpm, a > 0, b > 0 else { return 1 }
        return [0.5, 1, 2].min { abs(log2(a / (b * $0))) < abs(log2(a / (b * $1))) }!
    }

    /// Playback rate applied to B.
    var rate: Double {
        guard let a = deckA.analysis?.grid.bpm, let b = deckB.analysis?.grid.bpm, a > 0, b > 0 else { return 1 }
        return a / (b * tempoMultiplier)
    }

    /// B's grid as heard after matching, on B's own clock.
    var matchedGridB: BeatGrid? {
        guard let g = deckB.analysis?.grid else { return nil }
        return BeatGrid(bpm: g.bpm * tempoMultiplier, firstDownbeat: g.firstDownbeat).scaled(by: rate)
    }

    var masterGrid: BeatGrid? { deckA.analysis?.grid }

    var keyAfterShift: MusicalKey? { deckB.analysis?.key.transposed(by: semitones) }

    /// Nil when the keys clash and no shift of ±2 or less fixes it.
    @Published private(set) var keyClash: String?

    private func autoShift(a: TrackAnalysis, b: TrackAnalysis) -> Int {
        if let shift = b.key.harmonicShift(toMatch: a.key, limit: 2) {
            keyClash = nil
            return shift
        }
        keyClash = "Keys clash (\(b.key.camelotCode) vs \(a.key.camelotCode)) and fixing it takes a big pitch shift. Echo Out avoids overlap."
        return 0
    }

    func setSemitones(_ value: Int, auto: Bool = false) {
        autoKey = auto
        if !auto { keyClash = nil }
        let value = auto ? (deckB.analysis.flatMap { b in deckA.analysis.map { autoShift(a: $0, b: b) } } ?? 0) : value
        guard value != semitones || matched == nil else { return }
        semitones = max(-6, min(6, value))
        rematch()
    }

    private func rematch() {
        guard let b = deckB.loaded, deckA.loaded != nil else { return }
        matchTicket?.cancel()
        let ticket = TrackProcessor.Ticket()
        matchTicket = ticket
        matched = nil
        matchStatus = "Matching tempo & key…"
        rebuildSnapshot()
        processor.match(b, rate: rate, semitones: semitones, ticket: ticket) { [weak self] result in
            Task { @MainActor in
                guard let self, self.matchTicket === ticket else { return }
                self.matchStatus = nil
                switch result {
                case .success(let m):
                    self.matched = m
                    if self.lanes.allSatisfy({ $0.envelopes.allSatisfy(\.isEmpty) }) { self.writePreset() }
                    self.rebuildSnapshot()
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
    }

    /// Bars after B's entry where its vocal comes in (from auto placement).
    private var vocalHandoff: Int?

    /// Why the automatic placement chose what it did, shown in the panel.
    @Published private(set) var placementNote: String?

    private func place(a: TrackAnalysis, b: TrackAnalysis) {
        let result = AutoPlacement.place(a: a, b: b, bars: transitionBars, preset: preset)
        vocalHandoff = result.vocalHandoff
        isPlacing = true
        defer { isPlacing = false }
        cueBar = result.cueBar
        entryBar = result.entryBar
        placementNote = result.reason.isEmpty ? nil : result.reason
    }

    /// Re-pick the entry and cue bars for the current preset and length,
    /// then write the preset there.
    func autoArrange() {
        guard let a = deckA.analysis, let b = deckB.analysis else { return }
        checkpoint()
        resetAutomation()
        place(a: a, b: b)
        writePreset()
    }

    func applyPreset() {
        checkpoint()
        writePreset()
    }

    private func writePreset() {
        guard let g = masterGrid else { return }
        lanes = TransitionBuilder.build(preset, lanes: lanes, start: g.downbeat(entryBar),
                                        barSeconds: g.barSeconds, bars: transitionBars, vocalBar: vocalHandoff)
    }

    func clearAutomation() {
        checkpoint()
        resetAutomation()
    }

    private func resetAutomation() {
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
        var entryBar: Int
        var cueBar: Int
    }

    private var undoStack: [Arrangement] = []
    private var redoStack: [Arrangement] = []
    private var isRestoring = false
    private var isPlacing = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var currentArrangement: Arrangement { Arrangement(lanes: lanes, entryBar: entryBar, cueBar: cueBar) }

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
        entryBar = state.entryBar
        cueBar = state.cueBar
        lanes = state.lanes
        isRestoring = false
        rebuildSnapshot()
        updateUndoState()
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
        case .halve: grid.bpm /= 2
        case .double: grid.bpm *= 2
        case .shiftBeats(let k): grid.firstDownbeat += Double(k) * grid.beatSeconds
        case .nudge(let ms): grid.firstDownbeat += ms / 1000
        }
        while grid.firstDownbeat >= grid.barSeconds { grid.firstDownbeat -= grid.barSeconds }
        while grid.firstDownbeat < 0 { grid.firstDownbeat += grid.barSeconds }
        loaded.analysis.grid = grid
        loaded.analysis.structure = TrackStructure.measure(stems: loaded.stems, grid: grid)
        StemCache.saveAnalysis(loaded.analysis, to: loaded.directory)
        setDeck(side) { $0.loaded = loaded }
        decksChanged(loadedSide: side)
    }

    /// Snaps to the master grid's beats (or finer when zoomed in).
    func snap(_ seconds: Double, division: Double) -> Double {
        guard let g = masterGrid else { return seconds }
        let step = g.beatSeconds / division
        return g.firstDownbeat + ((seconds - g.firstDownbeat) / step).rounded() * step
    }

    // MARK: - Rendering

    private func makeSnapshot() -> MixSnapshot {
        let anySolo = lanes.contains(where: \.isSoloed)
        let sr = AudioIO.sampleRate
        let data = lanes.map { lane -> MixSnapshot.LaneData in
            let audio = lane.side == .a ? deckA.loaded?.stems[lane.stem] : matched?.stems[lane.stem]
            return MixSnapshot.LaneData(
                audio: audio,
                offset: Int((laneOffset(lane) * sr).rounded()),
                envelopes: lane.envelopes,
                audible: !lane.isMuted && (!anySolo || lane.isSoloed))
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
        transport.isPlaying ? pause() : play()
    }

    func play() {
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
        playback.pause()
        transport.isPlaying = false
    }

    func seek(to seconds: Double) {
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
        return "\(a) → \(b).wav"
    }
}
