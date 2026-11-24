import Accelerate
import Foundation
import os

/// Background pipeline: decode → separate → analyse, and tempo/key matching.
///
/// Songs load as a pipeline: while one is separated on the GPU, the next is
/// decoded and the one before is analysed and listened to (see `separate`).
final class TrackProcessor: @unchecked Sendable {
    struct Loaded: @unchecked Sendable {
        let directory: URL
        let stems: [StemKind: StemAudio]
        var analysis: TrackAnalysis
        let peaks: [StemKind: [Float]]
    }

    struct Matched: @unchecked Sendable {
        let plan: MatchPlan
        let stems: [StemKind: StemAudio]
        let peaks: [StemKind: [Float]]
    }

    enum Progress: Sendable {
        case decoding
        case separating(Double)
        case analyzing
    }

    /// Where a song's renditions live in its cache folder. A tool running
    /// beside the app (passable-render) keeps its own: each clears renditions
    /// it no longer needs, and would clear the other's while it reads them.
    nonisolated(unsafe) static var renditionFolder = "matched"

    /// Frames per waveform peak (~5.8 ms).
    static let peakHop = 256

    final class Ticket: @unchecked Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { flag.withLock { $0 } }
        func cancel() { flag.withLock { $0 = true } }
    }

    /// Three songs in flight: one decoding, one on the GPU, one analysed.
    private let loads: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.nikolausmarek.passable.processing"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        return queue
    }()
    /// Renditions only stretch audio (no GPU), so several can run at once.
    private let matchQueue = DispatchQueue(label: "com.nikolausmarek.passable.matching", qos: .userInitiated,
                                           attributes: .concurrent)
    /// One rendition of a song at a time, for any processor: two builds
    /// asking for the same one (a rebuild started while the one it
    /// cancelled still renders, or two sets of the same songs) rendered it
    /// twice and the second couldn't move it into place, which failed the
    /// whole build; asking for two, each deleted the other's as stale while
    /// it was being read. The second now waits and takes the first's.
    private static let renditions = OSAllocatedUnfairLock(initialState: [String: NSLock]())
    private static func renditionLock(_ directory: URL) -> NSLock {
        renditions.withLock { locks in
            if let lock = locks[directory.path] { return lock }
            let lock = NSLock()
            locks[directory.path] = lock
            return lock
        }
    }
    func load(_ url: URL, ticket: Ticket,
              progress: @escaping @Sendable (Progress) -> Void,
              completion: @escaping @Sendable (Result<Loaded, Error>) -> Void) {
        loads.addOperation { [self] in
            completion(Result { try loadNow(url, ticket: ticket, progress: progress) })
        }
    }

    private func loadNow(_ url: URL, ticket: Ticket, progress: @escaping @Sendable (Progress) -> Void) throws -> Loaded {
        let directory = try StemCache.directory(for: url)
        let song = Self.songLock(directory)
        song.lock()
        defer { song.unlock() }
        StemCache.markUsed(directory)
        if !StemCache.hasStems(in: directory) {
            progress(.decoding)
            let mix = try AudioIO.loadStereo(url: url)
            if ticket.isCancelled { throw CancellationError() }
            var stems = try Self.separate(mix, progress: progress, isCancelled: { ticket.isCancelled })
            let bandVoice = StemRoformer.isAvailable ? stems[.vocals] : nil
            let modelVocals = try Self.replaceVocals(mix: mix, stems: &stems, blending: bandVoice, progress: progress,
                                                     isCancelled: { ticket.isCancelled })
            if !modelVocals { StemResidual.redistribute(mix: mix, stems: &stems) }
            for (kind, buffer) in stems {
                try StemAudio.save(buffer, directory: directory, name: kind.rawValue)
            }
            StemCache.markExact(directory)
            if modelVocals { StemCache.markModelVocals(directory) }
            if StemRoformer.isAvailable {
                StemCache.markRoformerStems(directory)
                StemCache.markBlendedBass(directory)
            }
        } else if StemRoformer.isAvailable, StemCache.hasRoformerStems(directory), !StemCache.hasBlendedBass(directory) {
            // Separated by the stem model before its bass was blended with
            // HTDemucs': the bass line once more, the stems made to add up
            // again, what was derived from the old ones dropped, and the
            // parts measured again (grid, key, edits and words kept).
            progress(.decoding)
            let mix = try AudioIO.loadStereo(url: url)
            var stems = try StemCache.loadStems(from: directory).mapValues { $0.copyStereo() }
            if let bass = stems[.bass], let vocals = stems[.vocals] {
                stems[.bass] = try Self.blendedBass(mix, bass, isCancelled: { ticket.isCancelled })
                var rest = mix
                vDSP_vsub(vocals.left, 1, mix.left, 1, &rest.left, 1, vDSP_Length(mix.count))
                vDSP_vsub(vocals.right, 1, mix.right, 1, &rest.right, 1, vDSP_Length(mix.count))
                var others = stems.filter { $0.key != .vocals }
                StemResidual.redistribute(mix: rest, stems: &others)
                for (kind, buffer) in others {
                    try StemAudio.save(buffer, directory: directory, name: kind.rawValue)
                }
                StemCache.forgetDerivedAudio(in: directory)
                if var analysis = StemCache.loadAnalysis(from: directory) {
                    // (Measured again on the new stems, the words kept.)
                    analysis.structure?.stemLevel = nil
                    StemCache.saveAnalysis(analysis, to: directory)
                }
            }
            StemCache.markBlendedBass(directory)
        } else if StemRoformer.isAvailable, !StemCache.hasRoformerStems(directory) {
            // Separated by HTDemucs: drums, bass and melody from the stem
            // model once. The voice is kept (it's the vocal model's, or
            // made so here), what was derived from the old stems dropped,
            // and the measures of the parts taken again; the beat grid and
            // key stay, so hand edits still sit where they were made.
            progress(.decoding)
            let mix = try AudioIO.loadStereo(url: url)
            var stems = try StemCache.loadStems(from: directory).mapValues { $0.copyStereo() }
            let band = try Self.separateBand(mix, progress: { progress(.separating(0.7 * $0)) },
                                             isCancelled: { ticket.isCancelled })
            for kind in [StemKind.drums, .bass, .other] { stems[kind] = band[kind] }
            var modelVocals = StemCache.hasModelVocals(directory)
            if !modelVocals {
                modelVocals = try Self.replaceVocals(mix: mix, stems: &stems, blending: band[.vocals], progress: progress,
                                                     isCancelled: { ticket.isCancelled })
            } else if let kim = stems[.vocals], let voice = band[.vocals] {
                stems[.vocals] = Self.blendVoices(kim, voice)
            }
            if modelVocals, let vocals = stems[.vocals] {
                var rest = mix
                vDSP_vsub(vocals.left, 1, mix.left, 1, &rest.left, 1, vDSP_Length(mix.count))
                vDSP_vsub(vocals.right, 1, mix.right, 1, &rest.right, 1, vDSP_Length(mix.count))
                var others = stems.filter { $0.key != .vocals }
                StemResidual.redistribute(mix: rest, stems: &others)
                others[.vocals] = vocals
                stems = others
            } else {
                if let voice = band[.vocals] { stems[.vocals] = voice }
                StemResidual.redistribute(mix: mix, stems: &stems)
            }
            for (kind, buffer) in stems {
                try StemAudio.save(buffer, directory: directory, name: kind.rawValue)
            }
            StemCache.forgetDerivedAudio(in: directory)
            if var analysis = StemCache.loadAnalysis(from: directory) {
                analysis.structure = nil
                StemCache.saveAnalysis(analysis, to: directory)
            }
            StemCache.markExact(directory)
            if modelVocals { StemCache.markModelVocals(directory) }
            StemCache.markRoformerStems(directory)
            StemCache.markBlendedBass(directory)
        } else if VocalSeparator.isAvailable, !StemCache.hasModelVocals(directory) {
            // Separated before the vocal model: its voice from the model
            // once (the other stems kept, and made to add up again), what
            // was derived from the old stems dropped, and the measures of
            // the voice and its words taken again; the beat grid and key
            // stay, so hand edits still sit where they were made.
            progress(.decoding)
            let mix = try AudioIO.loadStereo(url: url)
            var stems = try StemCache.loadStems(from: directory).mapValues { $0.copyStereo() }
            if try Self.replaceVocals(mix: mix, stems: &stems, progress: progress, isCancelled: { ticket.isCancelled }) {
                for (kind, buffer) in stems {
                    try StemAudio.save(buffer, directory: directory, name: kind.rawValue)
                }
                StemCache.forgetDerivedAudio(in: directory)
                if var analysis = StemCache.loadAnalysis(from: directory) {
                    analysis.structure = nil
                    StemCache.saveAnalysis(analysis, to: directory)
                }
                StemCache.markExact(directory)
                StemCache.markModelVocals(directory)
            }
        } else if !StemCache.isExact(directory) {
            // Separated before the stems were made to add up to the song:
            // once, and what was derived from the old stems goes.
            progress(.decoding)
            let mix = try AudioIO.loadStereo(url: url)
            var stems = try StemCache.loadStems(from: directory).mapValues { $0.copyStereo() }
            StemResidual.redistribute(mix: mix, stems: &stems)
            for (kind, buffer) in stems {
                try StemAudio.save(buffer, directory: directory, name: kind.rawValue)
            }
            StemCache.forgetDerivedAudio(in: directory)
            StemCache.markExact(directory)
        }
        let stems = try StemCache.loadStems(from: directory)
        let cached = StemCache.loadAnalysis(from: directory)
        let usable = cached.flatMap { $0.version == TrackAnalysis.currentVersion && (60...200).contains($0.grid.bpm) ? $0 : nil }

        // The words, once per song (and again when the languages on the
        // Mac have changed since: it may be in a new one). Heard while the
        // beat and key are worked out: the recogniser has engines of its
        // own. (Whether they're wanted is known before the analysis: it
        // keeps the lines and languages of the cached one.)
        let languages = Lyrics.available()
        final class Heard: @unchecked Sendable { var outcome: Lyrics.Outcome? }
        let heard = Heard()
        let listening = DispatchGroup()
        func wantsWords(_ structure: TrackStructure?) -> Bool {
            structure?.vocalLines == nil || structure?.lyricsTried != languages
        }
        if !languages.isEmpty, let vocals = stems[.vocals], usable.map({ wantsWords($0.structure) }) ?? true {
            DispatchQueue.global(qos: .userInitiated).async(group: listening) {
                heard.outcome = Lyrics.listen(vocals: vocals)
            }
        }
        defer { listening.wait() }

        var analysis: TrackAnalysis
        if var cached = usable {
            if cached.structure?.stemLevel == nil || cached.structure?.vocalBeatLevel == nil
                || cached.structure?.hookStart == nil || cached.structure?.barChroma == nil
                || cached.structure?.harmonyChroma == nil || cached.structure?.melodyChroma == nil
                || cached.structure?.vocalSixteenthLevel == nil || cached.structure?.vocalChroma == nil
                || cached.structure?.lowSplit != TrackStructure.lowSplit
                || cached.structure?.activityMeasure != TrackStructure.activityMeasure {
                let old = cached.structure
                cached.structure = TrackStructure.measure(stems: stems, grid: cached.grid)
                cached.structure?.setLines(old?.vocalLines, tried: old?.lyricsTried, grid: cached.grid)
                StemCache.saveAnalysis(cached, to: directory)
            }
            // (Breaths, for songs measured before them: from the stems,
            // and the lines put on the grid with them.)
            if let structure = cached.structure, structure.vocalBreaths == nil {
                cached.structure?.vocalBreaths = stems[.vocals].map(TrackStructure.breaths) ?? []
                cached.structure?.setLines(structure.vocalLines, tried: structure.lyricsTried, grid: cached.grid)
                StemCache.saveAnalysis(cached, to: directory)
            }
            if cached.structure != nil, cached.structure?.heardReference == nil {
                cached.structure?.heardReference = TrackStructure.heardReference(stems: stems, grid: cached.grid)
                StemCache.saveAnalysis(cached, to: directory)
            }
            if cached.structure != nil, cached.structure?.timbre == nil {
                cached.structure?.timbre = TrackStructure.measureTimbre(stems: stems)
                StemCache.saveAnalysis(cached, to: directory)
            }
            if cached.tuningCents == nil {
                cached.tuningCents = TrackAnalyzer.tuningCents(stems: stems)
                StemCache.saveAnalysis(cached, to: directory)
            }
            // (Lines put on the grid another way: again, from the
            // words already heard.)
            if let structure = cached.structure, structure.vocalLines?.isEmpty == false,
               structure.linesVersion != TrackStructure.linesVersion {
                cached.structure?.setLines(structure.vocalLines, tried: structure.lyricsTried, grid: cached.grid)
                StemCache.saveAnalysis(cached, to: directory)
            }
            analysis = cached
        } else {
            progress(.analyzing)
            analysis = TrackAnalyzer.analyze(stems: stems)
            StemCache.saveAnalysis(analysis, to: directory)
        }
        if analysis.tempoCheck != TrackAnalysis.tempoCheck {
            progress(.analyzing)
            let checked = TrackAnalyzer.checkingTempo(analysis, stems: stems)
            if checked != analysis {
                analysis = checked
                StemCache.saveAnalysis(analysis, to: directory)
            }
        }
        // (Sections from the neural structure model, once, where the app
        // has it, on the final grid: new songs, and songs measured without it.)
        if let analyzer = StructureAnalyzer.shared, analysis.structure != nil, analysis.structure?.sections == nil {
            let bars = analysis.grid.barCount(duration: analysis.duration)
            if let found = try? analyzer.analyze(stems: stems, grid: analysis.grid, barCount: bars) {
                analysis.structure?.sections = found.sections
                analysis.structure?.neuralBoundary = found.neuralBoundary
                analysis.structure?.chorusScore = found.chorusScore
                StemCache.saveAnalysis(analysis, to: directory)
            }
        }
        if !languages.isEmpty, let vocals = stems[.vocals], let structure = analysis.structure, wantsWords(structure) {
            progress(.analyzing)
            listening.wait()
            switch heard.outcome ?? Lyrics.listen(vocals: vocals) {
            case .heard(let heard):
                analysis.structure?.setLines(heard.lines, tried: languages, grid: analysis.grid)
                StemCache.saveAnalysis(analysis, to: directory)
            case .none:
                analysis.structure?.setLines([], tried: languages, grid: analysis.grid)
                StemCache.saveAnalysis(analysis, to: directory)
            case .failed:
                break
            }
        }
        // A drummer's song plays with its bars made even, so it can be
        // beat-matched (see `Steadying`).
        if let steady = try Steadying.steadied(directory: directory, stems: stems, analysis: analysis) {
            return Loaded(directory: steady.directory, stems: steady.stems, analysis: steady.analysis,
                          peaks: StemCache.peaks(steady.stems, in: steady.directory, hop: Self.peakHop))
        }
        return Loaded(directory: directory, stems: stems, analysis: analysis,
                      peaks: StemCache.peaks(stems, in: directory, hop: Self.peakHop))
    }

    /// Separation, one song at a time for every processor (the editor's
    /// and the set's): the model keeps a few hundred MB of GPU buffers
    /// live, and two at once would only fight over the same GPU. Songs
    /// queued behind it are decoded and analysed meanwhile.
    private static let gpu = DispatchSemaphore(value: 1)
    nonisolated(unsafe) private static var separator: StemSeparator?

    nonisolated(unsafe) private static var vocalSeparator: VocalSeparator?
    nonisolated(unsafe) private static var stemRoformer: StemRoformer?

    /// The vocal model's voice in place of HTDemucs', and what the mix
    /// holds beyond it and the other three stems handed to those three by
    /// their power per bin (`StemResidual`): the four add up to the song,
    /// and what the vocal model doesn't call voice goes where it sounds.
    /// False (stems untouched) where the app has no vocal model.
    private static func replaceVocals(mix: StereoBuffer, stems: inout [StemKind: StereoBuffer],
                                      blending bandVoice: StereoBuffer? = nil,
                                      progress: @escaping @Sendable (Progress) -> Void,
                                      isCancelled: @escaping () -> Bool) throws -> Bool {
        guard VocalSeparator.isAvailable else { return false }
        gpu.wait()
        defer { gpu.signal() }
        if isCancelled() { throw CancellationError() }
        if vocalSeparator == nil { vocalSeparator = try VocalSeparator() }
        var vocals = try vocalSeparator!.vocals(mix, progress: { progress(.separating(0.3 + 0.7 * $0)) },
                                                isCancelled: isCancelled)
        if let bandVoice, bandVoice.count == vocals.count { vocals = blendVoices(vocals, bandVoice) }
        var rest = mix
        vDSP_vsub(vocals.left, 1, mix.left, 1, &rest.left, 1, vDSP_Length(mix.count))
        vDSP_vsub(vocals.right, 1, mix.right, 1, &rest.right, 1, vDSP_Length(mix.count))
        var others = stems.filter { $0.key != .vocals }
        StemResidual.redistribute(mix: rest, stems: &others)
        stems = others
        stems[.vocals] = vocals
        return true
    }

    /// The vocal model's voice with the stem model's mixed in: the two
    /// are as close to the true voice as each other (median SDR 11.8 and
    /// 11.7 dB on the MUSDB18 test excerpts), and wrong in different
    /// places, so together they're closer than either (12.05 dB at this
    /// share, better than the vocal model alone on 48 of 50;
    /// tools/convert-roformer/evaluate_stems.py and its ensemble trial).
    static let bandVoiceShare: Float = 0.3

    private static func blendVoices(_ vocal: StereoBuffer, _ band: StereoBuffer) -> StereoBuffer {
        var out = vocal
        let n = vDSP_Length(min(vocal.count, band.count))
        var keep = 1 - bandVoiceShare, share = bandVoiceShare
        vDSP_vsmul(vocal.left, 1, &keep, &out.left, 1, n)
        vDSP_vsma(band.left, 1, &share, out.left, 1, &out.left, 1, n)
        vDSP_vsmul(vocal.right, 1, &keep, &out.right, 1, n)
        vDSP_vsma(band.right, 1, &share, out.right, 1, &out.right, 1, n)
        return out
    }

    private static func separate(_ mix: StereoBuffer, progress: @escaping @Sendable (Progress) -> Void,
                                 isCancelled: @escaping () -> Bool) throws -> [StemKind: StereoBuffer] {
        progress(.separating(0))
        // (Most of the time is the vocal model's, where there is one.)
        let share = VocalSeparator.isAvailable ? 0.3 : 1
        if StemRoformer.isAvailable {
            // Drums, bass and melody from the stem model; the voice too,
            // unless the vocal model replaces it (`replaceVocals`).
            return try separateBand(mix, progress: { progress(.separating($0 * share)) }, isCancelled: isCancelled)
        }
        gpu.wait()
        defer { gpu.signal() }
        if isCancelled() { throw CancellationError() }
        if separator == nil { separator = try StemSeparator() }
        return try separator!.separate(mix, progress: { progress(.separating($0 * share)) }, isCancelled: isCancelled)
    }

    /// The stem model's four stems (see `StemRoformer`), its bass line
    /// blended with HTDemucs' (`blendedBass`).
    private static func separateBand(_ mix: StereoBuffer, progress: @escaping (Double) -> Void,
                                     isCancelled: @escaping () -> Bool) throws -> [StemKind: StereoBuffer] {
        var stems: [StemKind: StereoBuffer]
        do {
            gpu.wait()
            defer { gpu.signal() }
            if isCancelled() { throw CancellationError() }
            if stemRoformer == nil { stemRoformer = try StemRoformer() }
            stems = try stemRoformer!.separate(mix, progress: progress, isCancelled: isCancelled)
        }
        if let bass = stems[.bass] { stems[.bass] = try blendedBass(mix, bass, isCancelled: isCancelled) }
        return stems
    }

    /// Share of HTDemucs' bass line in the bass stem. The stem model's
    /// bass and HTDemucs' are wrong in different places: together they're
    /// closer to the true bass than the stem model's alone (median SDR on
    /// the MUSDB18 test excerpts 9.92 against 9.65 dB, better on 33 of 50;
    /// for drums and melody a share of HTDemucs only made them worse).
    static let htBassShare: Float = 0.3

    /// `bass` (the stem model's) with HTDemucs' bass line of `mix` mixed
    /// in; as it was without the HTDemucs model.
    private static func blendedBass(_ mix: StereoBuffer, _ bass: StereoBuffer,
                                    isCancelled: @escaping () -> Bool) throws -> StereoBuffer {
        guard StemSeparator.isAvailable else { return bass }
        gpu.wait()
        defer { gpu.signal() }
        if isCancelled() { throw CancellationError() }
        if separator == nil { separator = try StemSeparator() }
        guard let ht = try separator!.separate(mix, progress: { _ in }, isCancelled: isCancelled)[.bass],
              ht.count == bass.count else { return bass }
        var out = bass
        var keep = 1 - htBassShare, share = htBassShare
        let n = vDSP_Length(bass.count)
        vDSP_vsmul(bass.left, 1, &keep, &out.left, 1, n)
        vDSP_vsma(ht.left, 1, &share, out.left, 1, &out.left, 1, n)
        vDSP_vsmul(bass.right, 1, &keep, &out.right, 1, n)
        vDSP_vsma(ht.right, 1, &share, out.right, 1, &out.right, 1, n)
        return out
    }

    /// One load of a song at a time, for any processor: two (the editor and
    /// the set asking for the same song) would both separate it and write
    /// the same files. The second waits and takes the first's.
    private static let songs = OSAllocatedUnfairLock(initialState: [String: NSLock]())
    private static func songLock(_ directory: URL) -> NSLock {
        songs.withLock { locks in
            if let lock = locks[directory.path] { return lock }
            let lock = NSLock()
            locks[directory.path] = lock
            return lock
        }
    }

    /// What B has to be turned into: its time map (A's tempo through the
    /// blend, then a glide home) and a key shift.
    struct MatchPlan: Equatable, Sendable {
        var map: TimeMap
        var semitones: Int

        /// The same rendition, give or take rounding: the set and the editor
        /// compute the same plan on clocks that differ by a constant.
        /// Folder name for this rendition: the same plan (to the frame)
        /// finds the same files again after a relaunch.
        var cacheName: String {
            let start = map.rampStart.isFinite ? String(Int(map.rampStart.rounded())) : "inf"
            let exit = map.hasExit
                ? String(format: "-x%.9f-%d-%d", map.exitRate, Int(map.exitStart.rounded()), Int(map.exitLength.rounded())) : ""
            return String(format: "v6-%.9f-%@-%d-%+d", map.rate, start, Int(map.rampLength.rounded()), semitones) + exit
        }

        func isSame(as other: MatchPlan) -> Bool {
            func close(_ a: Double, _ b: Double) -> Bool { a == b || abs(a - b) < 0.5 }
            guard semitones == other.semitones, abs(map.rate - other.map.rate) < 1e-9,
                  close(map.rampStart, other.map.rampStart), close(map.rampLength, other.map.rampLength),
                  map.hasExit == other.map.hasExit else { return false }
            return !map.hasExit || (abs(map.exitRate - other.map.exitRate) < 1e-9
                                    && close(map.exitStart, other.map.exitStart) && close(map.exitLength, other.map.exitLength))
        }
    }

    /// Tempo- and key-matched copies of a track's stems. Drums are only
    /// time-stretched: pitch-shifting them buys nothing harmonically and
    /// costs transient punch.
    ///
    /// Each plan renders into its own folder, reused when the same plan comes
    /// back (a relaunch). Older ones are deleted: the plan changes whenever
    /// the transition moves, and every rendition is as big as the track.
    /// Stems still mapped by the player stay readable after their files are
    /// unlinked.
    func match(_ loaded: Loaded, plan: MatchPlan, ticket: Ticket,
               completion: @escaping @Sendable (Result<Matched, Error>) -> Void) {
        matchQueue.async {
            completion(Result {
                if plan.map.isIdentity && plan.semitones == 0 {
                    return Matched(plan: plan, stems: loaded.stems, peaks: loaded.peaks)
                }
                let lock = Self.renditionLock(loaded.directory)
                lock.lock()
                defer { lock.unlock() }
                let root = loaded.directory.appendingPathComponent(Self.renditionFolder, isDirectory: true)
                let directory = root.appendingPathComponent(plan.cacheName, isDirectory: true)
                StemCache.removeLegacyMatches(in: loaded.directory)
                if StemCache.hasStems(in: directory), let stems = try? StemCache.loadStems(from: directory) {
                    return Matched(plan: plan, stems: stems, peaks: StemCache.peaks(stems, in: directory, hop: Self.peakHop))
                }
                // Written under a temporary name and moved into place, so a
                // half-written rendition is never mistaken for a finished one.
                let staging = root.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

                final class Box: @unchecked Sendable { var error: Error?; let lock = NSLock() }
                let box = Box()
                let jobs: [(name: String, source: StemAudio, kind: StemKind)] =
                    StemKind.allCases.map { ($0.rawValue, loaded.stems[$0]!, $0) }
                DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                    let job = jobs[i], kind = job.kind
                    do {
                        if ticket.isCancelled { throw CancellationError() }
                        let shift = kind == .drums ? 0 : plan.semitones
                        let matched = TimeStretcher.process(job.source.copyStereo(), map: plan.map,
                                                            semitones: shift, percussive: kind == .drums,
                                                            vocal: kind == .vocals,
                                                            harmonicPercussive: kind == .other)
                        if ticket.isCancelled { throw CancellationError() }
                        // (Sharing the song's file where it plays unchanged.)
                        try StemAudio.saveRendition(matched, source: job.source, sourceDirectory: loaded.directory,
                                                    sourceName: job.name, offset: plan.semitones == 0 ? plan.map.tailOffset : nil,
                                                    directory: staging, name: job.name)
                    } catch {
                        box.lock.lock(); box.error = box.error ?? error; box.lock.unlock()
                    }
                }
                if let error = box.error {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.moveItem(at: staging, to: directory)
                var stems: [StemKind: StemAudio] = [:]
                for kind in StemKind.allCases {
                    stems[kind] = try StemAudio.load(directory: directory, name: kind.rawValue)
                }
                for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                // Another queue may be writing its own staging folder.
                where old.lastPathComponent != directory.lastPathComponent && !old.lastPathComponent.hasPrefix(".") {
                    try? FileManager.default.removeItem(at: old)
                }
                return Matched(plan: plan, stems: stems, peaks: StemCache.peaks(stems, in: directory, hop: Self.peakHop))
            })
        }
    }
}
