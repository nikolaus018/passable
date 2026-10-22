import AppKit
import Foundation
import MediaPlayer

/// A DJ set: any number of songs, put in the order that flows best, every
/// transition planned automatically, played back or rendered as one mix.
@MainActor
final class SetSession: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var status: Deck.Status = .decoding
        var loaded: TrackProcessor.Loaded?
        /// Asked for while the set was playing, and mixed in (see `request`).
        var requested = false

        var title: String { SongTitle.of(url) }
        var analysis: TrackAnalysis? { loaded?.analysis }

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.status == b.status && a.analysis == b.analysis
        }
    }

    @Published private(set) var items: [Item] = [] {
        didSet { if persists { UserDefaults.standard.set(items.map(\.url.path), forKey: Self.storageKey) } }
    }
    /// Remembers the set between launches (off for headless measurement).
    private let persists: Bool
    private static let storageKey = "setTracks"
    private static let editsKey = "setEdits"
    @Published private(set) var mix: SetMix? {
        didSet { lamp.setBeats(from: mix) }
    }
    @Published private(set) var buildStatus: String?
    @Published private(set) var exportProgress: Double?
    /// What the export or open in progress is doing, for its progress bar.
    @Published private(set) var exportLabel = "Rendering…"
    @Published var alert: String?
    @Published var masterVolume: Double = 0.85 { didSet { refreshSnapshot() } }
    /// The transition shown in the editor (index of its outgoing song).
    @Published private(set) var focused: Int?

    enum Tab: String, CaseIterable, Identifiable {
        case set = "Set", transition = "Transition"
        var id: String { rawValue }
    }
    @Published var tab: Tab = .set

    /// The transition editor, always showing one transition of this set.
    let editor = Session()
    let transport = Transport()
    /// (Internal so a harness can watch the audio thread keep time.)
    let playback = PlaybackEngine()
    /// A lamp or plug that flashes on the beat.
    private(set) lazy var lamp = LampModel(playback: playback, persists: persists)
    private let processor = TrackProcessor()
    /// Hand-shaped transitions, by pair of songs.
    private var edits: [PairKey: TransitionEdit] = [:] {
        didSet { saveEdits() }
    }
    private var focusedKey: PairKey?
    /// Reopen the focused transition in the editor after the next build
    /// (its content changed from outside the editor).
    private var reopenFocus = false
    /// Songs were added since the set was last ordered.
    private var needsOrdering = false
    /// Those songs: with others already in their order, they are fitted in
    /// where they go best and the rest stays put.
    private var unplaced: Set<UUID> = []
    private var buildTask: Task<Void, Never>?
    private var orderTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var clock: Timer?

    init(persists: Bool = true) {
        self.persists = persists
        editor.host = self
        if persists { loadEdits() }
        clock = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if persists { setUpMediaKeys() }
    }

    /// Brings back the set from the last launch, in its saved order.
    func restore() {
        guard persists, items.isEmpty, let paths = UserDefaults.standard.stringArray(forKey: Self.storageKey) else { return }
        add(paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) })
        needsOrdering = false
        unplaced = []
    }

    var isReady: Bool { !items.isEmpty && items.allSatisfy { $0.loaded != nil } }

    // MARK: - Tracks

    /// - Parameter asListed: the songs keep the order they come in (a
    ///   measurement comparing the same pairs from run to run).
    func add(_ urls: [URL], asListed: Bool = false) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = Item(url: url)
            items.append(item)
            if !asListed {
                unplaced.insert(item.id)
                needsOrdering = true
            }
            load(item.id)
        }
        invalidate()
    }

    // MARK: - Requests

    /// A song asked for while the set plays, on its way into it.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var status: Deck.Status = .decoding

        var title: String { SongTitle.of(url) }
    }

    /// Requests still being fetched, separated and analysed.
    @Published private(set) var requests: [Request] = []
    /// Where the last request went, in words.
    @Published private(set) var requestNote: String?
    /// The request the build under way is for, and how often it may still
    /// be moved a song later if the music has caught up with its spot.
    private var placing: (id: UUID, tries: Int)?
    /// Seconds a request needs before the transition it changes: the set
    /// is planned and the song rendered at the blend's tempo meanwhile.
    private static let requestLead = 20.0

    func isInSet(_ url: URL) -> Bool { items.contains { $0.url == url } }
    func isRequested(_ url: URL) -> Bool { requests.contains { $0.url == url } }

    /// A song request: the song goes into the set as soon as it can, after
    /// the song that's playing or the first one after it that it isn't
    /// hopeless next to, and the set carries on from there as it was. The
    /// music never stops for it: the song is got ready on the side, and
    /// the set is rebuilt around the part that's playing.
    /// - Returns: false if the song is in the set already (or asked for).
    @discardableResult
    func request(_ url: URL) -> Bool {
        guard !isInSet(url), !isRequested(url) else { return false }
        // No set playing yet: it's simply one more song of it.
        guard mix != nil, isReady else {
            add([url])
            return true
        }
        let request = Request(url: url)
        requests.append(request)
        func update(_ change: (inout Request) -> Void) {
            guard let i = requests.firstIndex(where: { $0.id == request.id }) else { return }
            change(&requests[i])
        }
        processor.load(url, ticket: .init(), progress: { [weak self] progress in
            Task { @MainActor in
                guard let self, let i = self.requests.firstIndex(where: { $0.id == request.id }) else { return }
                switch progress {
                case .decoding: self.requests[i].status = .decoding
                case .separating(let p): self.requests[i].status = .separating(p)
                case .analyzing: self.requests[i].status = .analyzing
                }
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.requests.removeAll { $0.id == request.id }
                switch result {
                case .success(let loaded): self.place(url, loaded)
                case .failure(let error):
                    self.alert = "“\(SongTitle.of(url))” couldn't be loaded: \(error.localizedDescription)"
                }
            }
        })
        return true
    }

    // MARK: - Playing the room

    /// When a song leaves, where that was said while it played (see
    /// `mixNow` and `hold`): kept for as long as the two songs stay
    /// neighbours, so what has played stays as it played.
    private var exits: [PairKey: SetBuilder.Exit] = [:]
    /// The change the build under way is for: what the pair's exit was
    /// before, how often bringing the next song in may still be tried a
    /// phrase later, and which of the two it is.
    private var adjusting: (key: PairKey, was: SetBuilder.Exit?, tries: Int, now: Bool)?
    /// The set as last built, for the next build to take over what holds.
    private var lastBuilt: SetMix?
    /// What came of the last such change, in words.
    @Published private(set) var liveNote: String?
    /// Seconds a change needs before the transition it moves: twice what
    /// the last live change took to plan and render (about a second: the
    /// set is built from the last one, only the transition that changes
    /// is new), and never under three. What the player then has to be
    /// sure of is only the second and a half after the playhead (see
    /// `continues`).
    private var liveLead: Double { max(3, 2 * liveBuild) }
    /// Seconds the last live change took to build.
    private var liveBuild = 1.5
    private var liveStarted: Date?

    /// The way out of the song that's playing, while it can still be
    /// changed: an automatic one that hasn't begun.
    private var upcoming: (transition: SetMix.Transition, key: PairKey)? {
        guard let mix, isReady, adjusting == nil, placing == nil, let i = currentIndex,
              let t = mix.transitions.first(where: { $0.from == i }), !(t.isEdited && t.edit.byHand),
              transport.seconds < t.begins - 2 * t.barSeconds - liveLead - Self.liveAhead else { return nil }
        return (t, PairKey(from: mix.tracks[t.from].url, to: mix.tracks[t.to].url))
    }

    /// Whether `mixNow` and `hold` have anything to change.
    var canPlayTheRoom: Bool { upcoming != nil }

    /// The bars a jump leaves out of a track (see `SetMix.Track.skip`).
    private func skippedBars(_ track: SetMix.Track) -> Range<Int>? {
        let grid = track.loaded.analysis.grid
        return track.skip.map {
            Int(grid.bars(at: $0.from).rounded())..<Int(grid.bars(at: $0.to).rounded())
        }
    }

    /// Brings the next song in now: on the first phrase of the playing
    /// song that's far enough ahead to get the set ready for (see
    /// `liveLead`), instead of where it was planned. What a DJ does when
    /// the floor has had enough of a record. The music never stops for it.
    func mixNow() {
        guard let (t, key) = upcoming else { return }
        bringIn(t, key, tries: 2)
    }

    private func bringIn(_ t: SetMix.Transition, _ key: PairKey, tries: Int) {
        guard let mix, let s = mix.tracks[t.from].loaded.analysis.structure else { return }
        let track = mix.tracks[t.from], grid = track.loaded.analysis.grid
        let starts = AutoPlacement.phrases(s, boundary: s.boundaryStrength()).starts
        let skipped = skippedBars(track), now = transport.seconds
        guard let bar = starts.indices.first(where: { g in
            starts[g] && g < t.edit.entryBar && !(skipped?.contains(g) ?? false)
                && track.master(grid.downbeat(g)) - 2 * grid.barSeconds >= now + liveLead + Self.liveAhead
        }) else {
            say("“\(SongTitle.of(key.to))” is about to come in as it is")
            return
        }
        // (A's glide to the blend's tempo starts no sooner than the first
        // bar that hasn't been heard yet.)
        let ahead = (0..<bar).first { track.master(grid.downbeat($0)) >= now + liveLead + Self.liveAhead } ?? bar
        adjusting = (key, exits[key], tries, true)
        liveStarted = Date()
        exits[key] = .init(range: bar...bar, skip: skipped, wayOutFrom: ahead)
        say("Bringing in “\(SongTitle.of(key.to))”…", lasting: false)
        rebuild()
    }

    /// Keeps the song that's playing for longer: its way out starts at
    /// least sixteen bars later than planned (wherever suits from there),
    /// if it has that much left to play. What a DJ does when the floor
    /// loves a record. Again for longer still.
    func hold() {
        guard let (t, key) = upcoming, let mix else { return }
        let track = mix.tracks[t.from], analysis = track.loaded.analysis
        let later = t.edit.entryBar + 16
        guard later <= analysis.grid.barCount(duration: analysis.duration) - 4 else {
            say("“\(SongTitle.of(key.from))” has nothing more to play")
            return
        }
        adjusting = (key, exits[key], 0, false)
        liveStarted = Date()
        exits[key] = .init(range: later...Int.max, skip: skippedBars(track))
        say("Holding “\(SongTitle.of(key.from))”…", lasting: false)
        rebuild()
    }

    /// Whether the mix built for a change of exit (if that's what it was
    /// built for) can take over from `old`: the music hasn't caught up
    /// with what it changed, and it changed something. If not, the change
    /// is undone (or, bringing the next song in, tried a phrase later) and
    /// the set plays on as it was.
    private func adjusted(_ old: SetMix, into new: SetMix) -> Bool {
        guard let change = adjusting else { return true }
        adjusting = nil
        let was = old.transitions.first { old.tracks[$0.from].url == change.key.from && old.tracks[$0.to].url == change.key.to }
        let now = new.transitions.first { new.tracks[$0.from].url == change.key.from && new.tracks[$0.to].url == change.key.to }
        let moved = was.flatMap { w in now.map { change.now ? $0.start < w.start - 1 : $0.start > w.start + 1 } } ?? false
        if let started = liveStarted { liveBuild = Date().timeIntervalSince(started) }
        if moved, continues(old, into: new, ahead: Self.liveAhead) {
            say(change.now ? "“\(SongTitle.of(change.key.to))” comes in at \(Theme.time(now?.begins ?? 0))"
                : "“\(SongTitle.of(change.key.from))” plays until \(Theme.time(now?.begins ?? 0))")
            return true
        }
        exits[change.key] = change.was
        buildStatus = nil
        if moved, change.now, change.tries > 0, let (t, key) = upcoming {
            bringIn(t, key, tries: change.tries - 1)
        } else {
            say(moved ? "Too late: “\(SongTitle.of(change.key.to))” is on its way in"
                : change.now ? "“\(SongTitle.of(change.key.to))” can't come in sooner"
                : "“\(SongTitle.of(change.key.from))” has nothing more to play")
        }
        return false
    }

    private var noteTask: Task<Void, Never>?

    private func say(_ note: String, lasting: Bool = true) {
        liveNote = note
        noteTask?.cancel()
        guard lasting else { return }
        noteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self?.liveNote = nil }
        }
    }

    /// Whether `b` can follow `a` on a shared beat: anything but a pair
    /// whose tempos are too far apart to match.
    private func mixes(_ a: TrackAnalysis?, _ b: TrackAnalysis) -> Bool {
        guard let a else { return true }
        return MixMath.preset(a, b) != .echoOut
    }

    /// The first place a requested song may go: after the song that's
    /// leading, or after the next one if the way out of this one is too
    /// close (or under way) to change.
    private func earliestRequestSlot() -> Int {
        guard let mix else { return items.count }
        let current = min(currentIndex ?? 0, items.count - 1)
        if let out = mix.transitions.first(where: { $0.from == current }),
           transport.seconds > out.cue - Self.requestLead {
            return min(items.count, current + 2)
        }
        return current + 1
    }

    private func place(_ url: URL, _ loaded: TrackProcessor.Loaded) {
        guard !isInSet(url) else { return }
        var item = Item(url: url)
        item.loaded = loaded
        item.status = .ready
        item.requested = true
        guard mix != nil, isReady else {
            // The set is being rebuilt for something else: at its end.
            items.append(item)
            rebuild()
            return
        }
        let earliest = earliestRequestSlot()
        let slot = (earliest...items.count).first { mixes(items[$0 - 1].analysis, loaded.analysis) } ?? earliest
        items.insert(item, at: slot)
        placing = (item.id, 2)
        requestNote = "“\(item.title)” plays after “\(items[slot - 1].title)”"
        rebuild()
    }

    /// Whether `new` plays what `old` is playing now, and for the next
    /// seconds: the same songs at the same places, and no transition
    /// begun that the old mix didn't have. Then the player can change
    /// over to it mid-song and nobody hears it.
    /// Seconds after the playhead a rebuilt set has to play exactly as the
    /// old one: a request's (its song is loaded meanwhile, on its own
    /// time), and a live change's, which takes over at once.
    private static let requestAhead = 5.0, liveAhead = 1.5

    private func continues(_ old: SetMix, into new: SetMix, ahead seconds: Double = SetSession.requestAhead) -> Bool {
        let now = transport.seconds, ahead = now + seconds
        // (A transition touches nothing before the two bars ahead of where
        // it begins: the outgoing voice's echo opens there at the earliest.)
        for (k, t) in new.transitions.enumerated() where t.begins - 2 * t.barSeconds <= ahead {
            guard k < old.transitions.count else { return false }
            let was = old.transitions[k]
            guard old.tracks[was.from].url == new.tracks[t.from].url, old.tracks[was.to].url == new.tracks[t.to].url,
                  abs(was.start - t.start) < 1e-3, abs(was.end - t.end) < 1e-3 else { return false }
        }
        // And the song that's leading sits where it sat (its way out may
        // have changed: where it glides to the next blend's tempo, a jump
        // it takes or no longer takes).
        let leading = old.transitions.last(where: { $0.end <= now })?.to ?? 0
        guard leading < new.tracks.count, new.tracks[leading].url == old.tracks[leading].url else { return false }
        let a = old.tracks[leading], b = new.tracks[leading]
        var own = 0.0
        while own < a.loaded.analysis.duration {
            let at = a.master(own)
            if at >= now - 1, at <= ahead, abs(b.master(own) - at) > 1e-3 { return false }
            own += 0.5
        }
        return true
    }

    /// The music has caught up with the spot a request was built for: one
    /// song later, and built again. False if there's nowhere later to go
    /// (or it has been moved often enough): it goes in as built.
    private func moveRequestLater() -> Bool {
        guard let request = placing, request.tries > 0,
              let i = items.firstIndex(where: { $0.id == request.id }) else { return false }
        let slot = min(items.count - 1, max(i + 1, earliestRequestSlot()))
        guard slot > i else { return false }
        let item = items.remove(at: i)
        items.insert(item, at: slot)
        placing = (request.id, request.tries - 1)
        requestNote = "“\(item.title)” plays after “\(items[slot - 1].title)”"
        rebuild()
        return true
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        invalidate()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        invalidate()
    }

    private func load(_ id: UUID) {
        guard let url = items.first(where: { $0.id == id })?.url else { return }
        processor.load(url, ticket: .init(), progress: { [weak self] progress in
            Task { @MainActor in
                self?.update(id) {
                    switch progress {
                    case .decoding: $0.status = .decoding
                    case .separating(let p): $0.status = .separating(p)
                    case .analyzing: $0.status = .analyzing
                    }
                }
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let loaded):
                    self.update(id) { $0.loaded = loaded; $0.status = .ready }
                    guard self.isReady else { return }
                    if self.needsOrdering { self.autoOrder(keepingOrder: true) } else { self.rebuild() }
                case .failure(let error):
                    self.update(id) { $0.status = .failed(error.localizedDescription) }
                    self.rebuild()
                }
            }
        })
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    // MARK: - Ordering

    /// Puts the songs in the order with the smoothest, most driving run of
    /// transitions, then builds the mix.
    /// - Parameter keepingOrder: songs added to a set that has its order
    ///   are fitted in where they go best, and the others stay as they
    ///   are (Auto-Order itself starts from scratch).
    func autoOrder(keepingOrder: Bool = false) {
        needsOrdering = false
        orderTask?.cancel()
        let ready = items.filter { $0.analysis != nil }
        let new = keepingOrder ? unplaced : []
        unplaced = []
        guard ready.count == items.count, items.count > 1 else { return rebuild() }
        let placed = ready.indices.filter { !new.contains(ready[$0].id) }, added = ready.indices.filter { new.contains(ready[$0].id) }
        let fitIn = !added.isEmpty && placed.count > 1
        let analyses = ready.map { $0.analysis! }
        let songs = ready.compactMap(\.loaded)
        let ids = ready.map(\.id)
        // Every pair of songs is planned to price it: seconds for a long
        // set, so not on the main thread.
        buildTask?.cancel()
        buildStatus = "Ordering songs…"
        orderTask = Task { [weak self] in
            let order = await Task.detached(priority: .userInitiated) {
                let costs = SetOrdering.costMatrix(analyses, drums: BeatAlign.attacks(of: songs), remembered: true)
                let washOuts = SetOrdering.washOuts(analyses), energies = analyses.map(SetOrdering.energy)
                return fitIn ? SetOrdering.insert(added, into: placed, costs, washOuts: washOuts, energies: energies)
                    : SetOrdering.order(costs, washOuts: washOuts, energies: energies)
            }.value
            // The list changed meanwhile (a song removed, rows dragged):
            // that order is the newer word.
            guard !Task.isCancelled, let self, self.items.map(\.id) == ids else { return }
            let reordered = order.map { ready[$0] }
            if reordered.map(\.id) != ids {
                self.items = reordered
                self.invalidate()
            } else {
                self.rebuild()
            }
        }
    }

    /// Why each neighbour pair fits (or doesn't), for the list.
    /// Why the automatic plan chose what it did, for a tooltip.
    func reasoning(from i: Int) -> String? {
        guard let t = mix?.transitions.first(where: { $0.from == i }), !t.isEdited else { return nil }
        return t.plan.placement.reason.isEmpty ? nil : t.plan.placement.reason
    }

    func summary(from i: Int) -> String? {
        guard let mix, let t = mix.transitions.first(where: { $0.from == i }) else { return nil }
        // Drawn by hand, only what was drawn is known; a chosen spot or
        // preset is still planned, and described, like any other.
        if t.isEdited, t.edit.byHand {
            var parts = [t.edit.preset.name(bars: t.edit.bars)]
            if t.edit.preset != .echoOut { parts.append("\(t.edit.bars) bars") }
            if t.edit.semitones != 0 { parts.append("B \(t.edit.semitones > 0 ? "+" : "")\(t.edit.semitones) st") }
            return parts.joined(separator: " · ")
        }
        var parts = [t.plan.preset.name(bars: t.plan.bars)]
        if t.plan.preset != .echoOut {
            parts.append("\(t.plan.bars) bars")
            let share = t.plan.shared
            parts.append(share.a == 1 ? String(format: "%+.1f%% tempo", t.plan.stretchPercent)
                         : String(format: "tempos meet (A %+.1f%%, B %+.1f%%)", (share.a - 1) * 100, (share.b - 1) * 100))
        }
        if t.edit.semitones != 0 { parts.append("B \(t.edit.semitones > 0 ? "+" : "")\(t.edit.semitones) st to fit") }
        if t.plan.preset != .echoOut { parts.append(t.melodiesClash ? "melodies clash, swapped" : "melodies fit") }
        if t.skippedBars > 0 { parts.append("A skips \(t.skippedBars) bars of verse and breakdown") }
        parts += t.payoff
        return parts.joined(separator: " · ")
    }

    func isEdited(from i: Int) -> Bool {
        mix?.transitions.first(where: { $0.from == i })?.isEdited ?? false
    }

    // MARK: - Building

    /// The song list changed: the old mix no longer applies.
    private func invalidate() {
        // (A Hold or Mix Now was said of the set as it was.)
        adjusting = nil
        exits = [:]
        orderTask?.cancel()
        pause()
        mix = nil
        updateNowPlaying()
        reopenFocus = true
        refreshSnapshot()
        rebuild()
    }

    private func rebuild() {
        buildTask?.cancel()
        guard isReady, !needsOrdering else {
            if let failed = items.first(where: { if case .failed = $0.status { return true } else { return false } }) {
                buildStatus = "“\(failed.title)” couldn't be loaded. Remove it to build the set."
            } else {
                buildStatus = items.isEmpty ? nil : "Waiting for all songs to be analysed…"
            }
            return
        }
        let tracks = items.compactMap { item in item.loaded.map { (url: item.url, loaded: $0) } }
        var reuse: [URL: TrackProcessor.Matched] = [:]
        for t in mix?.tracks ?? [] { if let m = t.matched { reuse[t.url] = m } }
        let edits = self.edits, exits = self.exits
        // (Whatever of the last build still holds is taken over from it.)
        let previous = mix ?? lastBuilt
        if mix == nil { buildStatus = "Planning transitions…" }
        let processor = self.processor
        // A change made while the music plays is wanted now, not after a pause.
        let wait: UInt64 = adjusting == nil ? 250_000_000 : 0
        buildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled else { return }
            do {
                let mix = try await SetBuilder.build(tracks, edits: edits, reuse: reuse, previous: previous, exits: exits,
                                                     processor: processor) { text in
                    Task { @MainActor in if self?.mix == nil { self?.buildStatus = text } }
                }
                guard !Task.isCancelled, let self else { return }
                // Built around what's playing for a request: if the music
                // has moved on into what it changed, it goes a song later.
                if self.placing != nil, let old = self.mix, !self.continues(old, into: mix), self.moveRequestLater() { return }
                self.placing = nil
                // The same for a change of when the playing song leaves:
                // too late, it plays as it was going to.
                if let old = self.mix, !self.adjusted(old, into: mix) { return }
                self.lastBuilt = mix
                self.mix = mix
                self.buildStatus = nil
                self.refreshSnapshot()
                self.refreshFocus()
            } catch is CancellationError {
            } catch {
                self?.buildStatus = nil
                self?.alert = error.localizedDescription
            }
        }
    }

    /// Held M or S: the vocal of the song that's playing, muted (the crowd
    /// sings the chorus) or alone, for as long as the key is down.
    struct VocalHold: Equatable {
        let track: Int
        let solo: Bool
    }

    @Published private(set) var vocalHold: VocalHold?

    /// Press and release of M (`solo` false) or S. Taken from the song
    /// leading at the press and kept until the release, whatever the
    /// editor shows meanwhile.
    func holdVocals(solo: Bool, down: Bool) {
        if down {
            guard vocalHold == nil, let i = currentIndex else { return }
            vocalHold = VocalHold(track: i, solo: solo)
        } else {
            guard vocalHold != nil else { return }
            vocalHold = nil
        }
        refreshSnapshot()
    }

    func makeSnapshot(including: (Int, StemKind) -> Bool = { _, _ in true }) -> MixSnapshot {
        // Mute and solo in the editor apply to the two songs it shows.
        let pair = mix.flatMap { mix in focused.flatMap { i in mix.transitions.first { $0.from == i } } }
        let editor = self.editor
        let anySolo = pair != nil && editor.lanes.contains(where: \.isSoloed)
        let hold = vocalHold
        return mix?.snapshot(masterGain: Float(masterVolume)) { track, stem in
            guard including(track, stem) else { return false }
            if let hold {
                let held = track == hold.track && stem == .vocals
                if hold.solo { return held }
                if held { return false }
            }
            guard let pair else { return true }
            if track == pair.from { return editor.isAudible(.a, stem) }
            if track == pair.to { return editor.isAudible(.b, stem) }
            return !anySolo
        } ?? .empty
    }

    /// Mute or solo changed in the editor.
    func editorMonitorChanged() {
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        playback.renderer.setSnapshot(makeSnapshot())
    }

    var length: Double { mix?.length ?? 0 }

    // MARK: - The editor

    /// Shows a transition in the editor tab and cues it.
    func edit(transitionFrom i: Int) {
        focus(i, reopen: true)
        tab = .transition
        guard let t = mix?.transitions.first(where: { $0.from == i }) else { return }
        seek(to: t.cue)
    }

    private func focus(_ i: Int?, reopen: Bool) {
        guard let mix, let i, let t = mix.transitions.first(where: { $0.from == i }) else {
            focused = nil
            focusedKey = nil
            editor.close()
            return
        }
        let a = mix.tracks[t.from], b = mix.tracks[t.to]
        let key = PairKey(from: a.url, to: b.url)
        focused = i
        editor.hostOffset = t.delta
        editor.entryRange = t.entryRange
        // A as the set renders it, around the transition (past any jump).
        let hosted = Session.Hosted(edit: t.edit, aMatched: a.matched, aMap: a.map, aOffset: a.stemOffset(at: t.start) - t.delta,
                                    bOffset: b.offset - t.delta, barSeconds: t.barSeconds)
        guard reopen || key != focusedKey else {
            editor.adopt(t.edit, matched: b.matched, placement: played(t), hosted: hosted)
            return editor.syncTransport()
        }
        focusedKey = key
        editor.open(title: "\(t.from + 1) → \(t.to + 1)",
                    a: Deck(url: a.url, status: .ready, loaded: a.loaded),
                    b: Deck(url: b.url, status: .ready, loaded: b.loaded),
                    edit: t.edit, isEdited: t.isEdited, matched: b.matched, placement: played(t),
                    placedAs: (t.plan.preset, t.plan.bars), entryRange: t.entryRange, offset: t.delta, hosted: hosted)
    }

    /// The plan's placement as the set really plays it: a mashup only where
    /// it passed the checks on the audio.
    private func played(_ t: SetMix.Transition) -> AutoPlacement.Result {
        var p = t.plan.placement
        p.mashup = t.payoff.contains { $0.hasPrefix("mashup") }
        p.dropMoment = t.dropAt != nil
        return p
    }

    /// After a build: keep the editor on its transition (by pair, since the
    /// order may have changed), re-opening it only when its content changed
    /// from outside the editor.
    private func refreshFocus() {
        guard let mix else { return }
        let index = focusedKey.flatMap { key in
            mix.transitions.first { mix.tracks[$0.from].url == key.from && mix.tracks[$0.to].url == key.to }?.from
        } ?? (focused.map { min($0, mix.transitions.count - 1) } ?? (mix.transitions.isEmpty ? nil : 0))
        let reopen = reopenFocus || index.map { i in
            let t = mix.transitions[i]
            return PairKey(from: mix.tracks[t.from].url, to: mix.tracks[t.to].url) != focusedKey
        } ?? true
        reopenFocus = false
        focus(index, reopen: reopen)
    }

    /// The editor changed the focused transition.
    func editorChanged(_ edit: TransitionEdit) {
        guard let key = focusedKey else { return }
        edits[key] = edit
        rebuild()
    }

    /// The editor rewrote its lanes without changing what was chosen: it
    /// shows the set's own again.
    func editorUnchanged() {
        guard mix != nil, let i = focused, focusedKey != nil else { return }
        focus(i, reopen: false)
    }

    /// Hands the focused transition back to the automatic plan.
    func revertToAuto() {
        guard let key = focusedKey else { return }
        edits[key] = nil
        reopenFocus = true
        rebuild()
    }

    /// A song's beat grid was corrected in the editor: everything placed on
    /// the old grid is stale.
    func gridChanged(_ url: URL, _ loaded: TrackProcessor.Loaded) {
        if let i = items.firstIndex(where: { $0.url == url }) { items[i].loaded = loaded }
        edits = edits.filter { $0.key.from != url && $0.key.to != url }
        reopenFocus = true
        rebuild()
    }

    private func saveEdits() {
        guard persists else { return }
        let list = edits.map { StoredEdit(pair: $0.key, edit: $0.value) }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.editsKey) }
    }

    private func loadEdits() {
        guard let data = UserDefaults.standard.data(forKey: Self.editsKey),
              let list = try? JSONDecoder().decode([StoredEdit].self, from: data) else { return }
        edits = Dictionary(list.map { ($0.pair, $0.edit) }, uniquingKeysWith: { a, _ in a })
    }

    private struct StoredEdit: Codable {
        let pair: PairKey
        let edit: TransitionEdit
    }

    // MARK: - Transport

    func togglePlay() { transport.isPlaying ? pause() : play() }

    func play() {
        guard mix != nil else { return }
        if transport.seconds >= length { seek(to: 0) }
        do {
            try playback.play()
            transport.isPlaying = true
            updateNowPlaying()
        } catch {
            alert = "Couldn't start audio: \(error.localizedDescription)"
        }
    }

    func pause() {
        playback.pause()
        transport.isPlaying = false
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        let s = max(0, min(seconds, length))
        playback.renderer.seek(to: Int(s * AudioIO.sampleRate))
        transport.seconds = s
        updateNowPlaying()
    }

    // MARK: - Skipping

    /// Where Next and Previous land: the start of the set and just before
    /// each transition, so every jump lands ahead of a mix.
    private var cuePoints: [Double] {
        guard let mix else { return [] }
        return [0] + mix.transitions.map(\.cue)
    }

    /// Where Next lands: right where each transition begins, no lead-in.
    private var transitionStarts: [Double] { mix?.transitions.map(\.begins) ?? [] }

    /// Jumps straight to the next transition.
    func skipForward() {
        let now = transport.seconds
        guard let next = transitionStarts.first(where: { $0 > now + 0.5 }) else { return }
        jump(to: next)
    }

    /// Back to the lead-in of the song that's playing; pressed again right
    /// away, to the one before (like a CD player).
    func skipBack() {
        guard mix != nil else { return }
        let now = transport.seconds
        jump(to: cuePoints.last(where: { $0 < now - 3 }) ?? 0)
    }

    private func jump(to seconds: Double) {
        seek(to: seconds)
        if let i = transitionAt(seconds), i != focused { focus(i, reopen: false) }
    }

    var canSkipForward: Bool { transitionStarts.contains { $0 > transport.seconds + 0.5 } }

    /// Four bars before a transition, to audition it.
    func cue(transitionFrom i: Int) {
        guard let t = mix?.transitions.first(where: { $0.from == i }) else { return }
        focus(i, reopen: false)
        seek(to: t.cue)
        play()
    }

    /// Plays the set from where a song comes in (the start, for the first).
    func play(song i: Int) {
        guard let mix else { return }
        if let t = mix.transitions.first(where: { $0.to == i }) {
            jump(to: max(0, t.start))
        } else {
            jump(to: 0)
        }
        play()
    }

    /// Which song is playing (the incoming one once a transition is over).
    var currentIndex: Int? {
        guard let mix else { return nil }
        let t = transport.seconds
        return mix.transitions.last(where: { $0.end <= t })?.to ?? 0
    }

    /// The transition being played or coming up next.
    private func transitionAt(_ seconds: Double) -> Int? {
        guard let mix else { return nil }
        return (mix.transitions.first { seconds < $0.settled } ?? mix.transitions.last)?.from
    }

    private func tick() {
        // The output went away and couldn't be restarted: say so, rather
        // than show a clock that's frozen.
        if transport.isPlaying && !playback.isRunning {
            transport.isPlaying = false
            updateNowPlaying()
        }
        if transport.isPlaying {
            let s = Double(playback.renderer.currentFrame) / AudioIO.sampleRate
            transport.seconds = s
            if s >= length + 2 { pause() }
            if currentIndex != nowPlayingIndex { updateNowPlaying() }
            // The editor follows the music.
            if let i = transitionAt(s), i != focused { focus(i, reopen: false) }
        }
        editor.syncTransport()
    }

    // MARK: - Media keys

    /// The keyboard's ⏯ ⏮ ⏭ keys, headphone buttons and Control Center
    /// drive the set like a player.
    private func setUpMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            command.addTarget { event in
                Task { @MainActor in action(event) }
                return .success
            }
        }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlay() }
        on(center.playCommand) { [weak self] _ in self?.play() }
        on(center.pauseCommand) { [weak self] _ in self?.pause() }
        on(center.nextTrackCommand) { [weak self] _ in self?.skipForward() }
        on(center.previousTrackCommand) { [weak self] _ in self?.skipBack() }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) }
        }
    }

    /// The song Control Center shows; published so the set list can follow
    /// the music.
    @Published private(set) var nowPlayingIndex: Int?

    /// What macOS shows as playing (and so where the media keys go).
    private func updateNowPlaying() {
        guard persists else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard mix != nil, let i = currentIndex, items.indices.contains(i) else {
            nowPlayingIndex = nil
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        nowPlayingIndex = i
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: items[i].title,
            MPMediaItemPropertyArtist: "Passable Set · song \(i + 1) of \(items.count)",
            MPMediaItemPropertyPlaybackDuration: length,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: transport.seconds,
            MPNowPlayingInfoPropertyPlaybackRate: transport.isPlaying ? 1.0 : 0.0,
        ]
        center.playbackState = transport.isPlaying ? .playing : .paused
    }

    // MARK: - Export

    enum ExportRange { case set, focusedTransition }

    func export(_ range: ExportRange, to url: URL) {
        guard exportTask == nil, let mix else { return }
        let sr = AudioIO.sampleRate
        let frames: Range<Int>
        switch range {
        case .set:
            frames = 0..<Int(length * sr)
        case .focusedTransition:
            guard let t = mix.transitions.first(where: { $0.from == focused }) else { return }
            // (From four bars before anything happens, as Listen plays it: a
            // Wash Out's bridge begins up to eight bars before B's downbeat.)
            frames = Int(max(0, min(t.cue, t.start - 8 * t.barSeconds)) * sr)..<Int(min(length, t.settled + 8 * t.barSeconds) * sr)
        }
        let snapshot = makeSnapshot()
        exportLabel = "Rendering…"
        exportProgress = 0
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try Exporter.render(snapshot: snapshot, range: frames, tail: 3, to: url) { p in
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
        case .failure(let error): alert = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Set files

    /// Packs the set, songs included, into one `.passable` file.
    func exportSet(to url: URL) {
        guard exportTask == nil, !items.isEmpty else { return }
        let songs = items.map { (url: $0.url, analysis: $0.analysis) }
        let index = Dictionary(items.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { a, _ in a })
        // Every hand edit between songs of this set, not just neighbours:
        // they come back if the order is changed later.
        let transitions = edits.compactMap { key, edit in
            index[key.from].flatMap { from in index[key.to].map { PassableFile.Transition(from: from, to: $0, edit: edit) } }
        }.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        let volume = masterVolume
        exportLabel = "Exporting…"
        exportProgress = 0
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try PassableFile.write(songs: songs, transitions: transitions, masterVolume: volume, to: url) { p in
                    Task { @MainActor in self?.exportProgress = p }
                }
            }
            await self?.finishExport(result, url: url)
        }
    }

    var suggestedSetName: String {
        let date = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        return "Passable Set \(date).passable"
    }

    // MARK: - Phone mix

    /// The iPhones on the same Wi-Fi that this set can be sent to.
    let phoneLink = PhoneLink()

    enum PhoneDestination { case file(URL), phone(PhoneLink.Phone) }
    private enum PhoneOutcome { case saved(URL), sent(String) }

    /// Renders the whole set and packs it, with the map of where each song
    /// sits, into a `.passablemix` for the Passable app on the iPhone: saved
    /// to a file, or sent straight to a phone nearby.
    func exportPhoneMix(title: String, to destination: PhoneDestination) {
        guard exportTask == nil, let mix, !items.isEmpty else { return }
        let frames = 0..<Int(length * AudioIO.sampleRate)
        let snapshot = makeSnapshot()
        let manifest = PhoneMix.manifest(for: mix, titles: items.map(\.title), title: title)
        let link = phoneLink
        exportLabel = "Rendering…"
        exportProgress = 0
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("phonemix-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let outcome: Result<PhoneOutcome, Error>
            do {
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let audio = temp.appendingPathComponent("mix.m4a")
                try Exporter.render(snapshot: snapshot, range: frames, tail: 3, to: audio) { p in
                    Task { @MainActor in self?.exportProgress = p * 0.9 }
                }
                await self?.setPhoneStatus("Packing…", progress: 0.9)
                switch destination {
                case .file(let url):
                    try PassableMix.write(manifest, audio: audio, to: url)
                    outcome = .success(.saved(url))
                case .phone(let phone):
                    let package = temp.appendingPathComponent(PhoneMix.suggestedFileName(title))
                    try PassableMix.write(manifest, audio: audio, to: package)
                    let size = (try? FileManager.default.attributesOfItem(atPath: package.path)[.size] as? Int) ?? 0
                    await self?.setPhoneStatus("Waiting for \(phone.name)…", progress: 0.92)
                    let invitation = PassableMix.Invitation(title: title, songs: manifest.songs.count, bytes: size,
                                                            minutes: Int((manifest.duration / 60).rounded()))
                    try await link.send(package, to: phone, invitation: invitation) { p in
                        self?.exportLabel = "Sending to \(phone.name)…"
                        self?.exportProgress = 0.92 + p * 0.08
                    }
                    outcome = .success(.sent(phone.name))
                }
            } catch {
                outcome = .failure(error)
            }
            await self?.finishPhoneExport(outcome)
        }
    }

    private func setPhoneStatus(_ label: String, progress: Double) {
        exportLabel = label
        exportProgress = progress
    }

    private func finishPhoneExport(_ result: Result<PhoneOutcome, Error>) {
        exportTask = nil
        switch result {
        case .success(.saved(let url)):
            exportProgress = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .success(.sent(let name)):
            exportLabel = "Sent to \(name)"
            exportProgress = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.exportTask == nil { self?.exportProgress = nil }
            }
        case .failure(let error):
            exportProgress = nil
            if !(error is CancellationError) { alert = error.localizedDescription }
        }
    }

    /// Opens a `.passable` file in place of the current set, unpacking its
    /// songs into the library folder.
    func openSet(_ url: URL) {
        guard exportTask == nil else {
            alert = "Wait for the current \(exportLabel.dropLast().lowercased()) to finish, then open the set again."
            return
        }
        if !items.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace the current set?"
            alert.informativeText = "\(url.deletingPathExtension().lastPathComponent) replaces the \(items.count) songs in your set. Export the current set first to keep it."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        pause()
        exportLabel = "Opening…"
        exportProgress = 0
        let folder = MusicTools.libraryFolder
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try PassableFile.read(url, into: folder) { p in
                    Task { @MainActor in self?.exportProgress = p }
                }
            }
            await self?.finishOpen(result)
        }
    }

    private func finishOpen(_ result: Result<PassableFile.Opened, Error>) {
        exportTask = nil
        exportProgress = nil
        switch result {
        case .success(let opened):
            replaceSet(with: opened)
        case .failure(let error):
            alert = "Couldn't open the set: \(error.localizedDescription)"
        }
    }

    /// The songs in the file's order (not re-ordered), its hand edits and
    /// volume; everything else is planned again from the analyses.
    private func replaceSet(with opened: PassableFile.Opened) {
        buildTask?.cancel()
        focus(nil, reopen: true)
        var merged = edits
        for t in opened.manifest.transitions where opened.urls.indices.contains(t.from) && opened.urls.indices.contains(t.to) {
            merged[PairKey(from: opened.urls[t.from], to: opened.urls[t.to])] = t.edit
        }
        edits = merged
        masterVolume = opened.manifest.masterVolume
        items = opened.urls.map { Item(url: $0) }
        needsOrdering = false
        unplaced = []
        tab = .set
        for item in items { load(item.id) }
        invalidate()
    }

    var suggestedTransitionName: String {
        guard let mix, let t = mix.transitions.first(where: { $0.from == focused }) else { return "Transition.m4a" }
        let name = { (i: Int) in self.items.indices.contains(i) ? self.items[i].title : "\(i + 1)" }
        return "\(name(t.from)) → \(name(t.to)).m4a"
    }
}
