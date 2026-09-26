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
    @Published private(set) var mix: SetMix?
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
    private let playback = PlaybackEngine()
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
    private var buildTask: Task<Void, Never>?
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
    }

    var isReady: Bool { !items.isEmpty && items.allSatisfy { $0.loaded != nil } }

    // MARK: - Tracks

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = Item(url: url)
            items.append(item)
            needsOrdering = true
            load(item.id)
        }
        invalidate()
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
                    if self.needsOrdering { self.autoOrder() } else { self.rebuild() }
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
    func autoOrder() {
        needsOrdering = false
        let ready = items.filter { $0.analysis != nil }
        guard ready.count == items.count, items.count > 2 else { return rebuild() }
        let analyses = ready.map { $0.analysis! }
        let n = analyses.count
        var costs = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n where i != j {
                costs[i][j] = PairPlan.make(a: analyses[i], b: analyses[j]).cost(a: analyses[i], b: analyses[j])
            }
        }
        let order = SetOrdering.order(costs)
        let reordered = order.map { ready[$0] }
        if reordered.map(\.id) != items.map(\.id) {
            items = reordered
            invalidate()
        } else {
            rebuild()
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
        if t.isEdited {
            var parts = [t.edit.preset.displayName]
            if t.edit.preset != .echoOut { parts.append("\(t.edit.bars) bars") }
            if t.edit.semitones != 0 { parts.append("B \(t.edit.semitones > 0 ? "+" : "")\(t.edit.semitones) st") }
            return parts.joined(separator: " · ")
        }
        var parts = [t.plan.preset.displayName]
        if t.plan.preset != .echoOut {
            parts.append("\(t.plan.bars) bars")
            parts.append(String(format: "%+.1f%% tempo", t.plan.stretchPercent))
        }
        parts.append(t.plan.keysClash ? "keys clash, melodies swapped" : "keys fit")
        return parts.joined(separator: " · ")
    }

    func isEdited(from i: Int) -> Bool {
        mix?.transitions.first(where: { $0.from == i })?.isEdited ?? false
    }

    // MARK: - Building

    /// The song list changed: the old mix no longer applies.
    private func invalidate() {
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
        let edits = self.edits
        if mix == nil { buildStatus = "Planning transitions…" }
        let processor = self.processor
        buildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let mix = try await SetBuilder.build(tracks, edits: edits, reuse: reuse, processor: processor) { text in
                    Task { @MainActor in if self?.mix == nil { self?.buildStatus = text } }
                }
                guard !Task.isCancelled, let self else { return }
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

    func makeSnapshot(including: (Int, StemKind) -> Bool = { _, _ in true }) -> MixSnapshot {
        // Mute and solo in the editor apply to the two songs it shows.
        let pair = mix.flatMap { mix in focused.flatMap { i in mix.transitions.first { $0.from == i } } }
        let editor = self.editor
        let anySolo = pair != nil && editor.lanes.contains(where: \.isSoloed)
        return mix?.snapshot(masterGain: Float(masterVolume)) { track, stem in
            guard including(track, stem) else { return false }
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
        seek(to: t.start - 4 * t.barSeconds)
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
        guard reopen || key != focusedKey else { return editor.syncTransport() }
        focusedKey = key
        editor.open(title: "\(t.from + 1) → \(t.to + 1)",
                    a: Deck(url: a.url, status: .ready, loaded: a.loaded),
                    b: Deck(url: b.url, status: .ready, loaded: b.loaded),
                    edit: t.edit, isEdited: t.isEdited, matched: b.matched, placement: t.plan.placement,
                    entryRange: t.entryRange, offset: t.delta)
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

    /// Where Next and Previous land: the start of the set and four bars
    /// before each transition, so every jump lands just ahead of a mix.
    private var cuePoints: [Double] {
        guard let mix else { return [] }
        return [0] + mix.transitions.map { max(0, $0.start - 4 * $0.barSeconds) }
    }

    /// Jumps to just before the next transition.
    func skipForward() {
        let now = transport.seconds
        guard let next = cuePoints.first(where: { $0 > now + 0.5 }) else { return }
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

    var canSkipForward: Bool { cuePoints.contains { $0 > transport.seconds + 0.5 } }

    /// Four bars before a transition, to audition it.
    func cue(transitionFrom i: Int) {
        guard let t = mix?.transitions.first(where: { $0.from == i }) else { return }
        focus(i, reopen: false)
        seek(to: t.start - 4 * t.barSeconds)
        play()
    }

    /// Four bars before the transition in the editor.
    func cueFocused() {
        if let focused { cue(transitionFrom: focused) }
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

    private var nowPlayingIndex: Int?

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
            frames = Int(max(0, t.start - 8 * t.barSeconds) * sr)..<Int(min(length, t.settled + 8 * t.barSeconds) * sr)
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
        tab = .set
        for item in items { load(item.id) }
        invalidate()
    }

    var suggestedTransitionName: String {
        guard let mix, let t = mix.transitions.first(where: { $0.from == focused }) else { return "Transition.wav" }
        let name = { (i: Int) in self.items.indices.contains(i) ? self.items[i].title : "\(i + 1)" }
        return "\(name(t.from)) → \(name(t.to)).wav"
    }
}
