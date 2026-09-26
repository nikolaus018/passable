import Foundation
import os

/// Background pipeline: decode → separate → analyse, and tempo/key matching.
///
/// Everything runs on one serial queue. Separation keeps a few hundred MB of
/// GPU buffers live, and two at once would only fight over the same GPU.
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

    /// Frames per waveform peak (~5.8 ms).
    static let peakHop = 256

    final class Ticket: @unchecked Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { flag.withLock { $0 } }
        func cancel() { flag.withLock { $0 = true } }
    }

    private let queue = DispatchQueue(label: "com.nikolausmarek.passable.processing", qos: .userInitiated)
    private var separator: StemSeparator?

    func load(_ url: URL, ticket: Ticket,
              progress: @escaping @Sendable (Progress) -> Void,
              completion: @escaping @Sendable (Result<Loaded, Error>) -> Void) {
        queue.async { [self] in
            completion(Result {
                let directory = try StemCache.directory(for: url)
                if !StemCache.hasStems(in: directory) {
                    progress(.decoding)
                    let mix = try AudioIO.loadStereo(url: url)
                    if ticket.isCancelled { throw CancellationError() }
                    progress(.separating(0))
                    if separator == nil { separator = try StemSeparator() }
                    let stems = try separator!.separate(mix, progress: { progress(.separating($0)) },
                                                        isCancelled: { ticket.isCancelled })
                    for (kind, buffer) in stems {
                        try StemAudio.save(buffer, directory: directory, name: kind.rawValue)
                    }
                }
                let stems = try StemCache.loadStems(from: directory)
                var analysis: TrackAnalysis
                if let cached = StemCache.loadAnalysis(from: directory), cached.version == TrackAnalysis.currentVersion,
                   (60...200).contains(cached.grid.bpm) {
                    analysis = cached
                    if analysis.structure?.stemLevel == nil || analysis.structure?.vocalBeatLevel == nil {
                        analysis.structure = TrackStructure.measure(stems: stems, grid: analysis.grid)
                        StemCache.saveAnalysis(analysis, to: directory)
                    }
                } else {
                    progress(.analyzing)
                    analysis = TrackAnalyzer.analyze(stems: stems)
                    StemCache.saveAnalysis(analysis, to: directory)
                }
                return Loaded(directory: directory, stems: stems, analysis: analysis,
                              peaks: stems.mapValues { $0.peaks(hop: Self.peakHop) })
            })
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
            return String(format: "v2-%.9f-%@-%d-%+d", map.rate, start, Int(map.rampLength.rounded()), semitones)
        }

        func isSame(as other: MatchPlan) -> Bool {
            func close(_ a: Double, _ b: Double) -> Bool { a == b || abs(a - b) < 0.5 }
            return semitones == other.semitones && abs(map.rate - other.map.rate) < 1e-9
                && close(map.rampStart, other.map.rampStart) && close(map.rampLength, other.map.rampLength)
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
        queue.async {
            completion(Result {
                if plan.map.isIdentity && plan.semitones == 0 {
                    return Matched(plan: plan, stems: loaded.stems, peaks: loaded.peaks)
                }
                let root = loaded.directory.appendingPathComponent("matched", isDirectory: true)
                let directory = root.appendingPathComponent(plan.cacheName, isDirectory: true)
                StemCache.removeLegacyMatches(in: loaded.directory)
                if StemCache.hasStems(in: directory), let stems = try? StemCache.loadStems(from: directory) {
                    return Matched(plan: plan, stems: stems, peaks: stems.mapValues { $0.peaks(hop: Self.peakHop) })
                }
                // Written under a temporary name and moved into place, so a
                // half-written rendition is never mistaken for a finished one.
                let staging = root.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

                final class Box: @unchecked Sendable { var error: Error?; let lock = NSLock() }
                let box = Box()
                DispatchQueue.concurrentPerform(iterations: StemKind.allCases.count) { i in
                    let kind = StemKind.allCases[i]
                    do {
                        if ticket.isCancelled { throw CancellationError() }
                        let shift = kind == .drums ? 0 : plan.semitones
                        let matched = TimeStretcher.process(loaded.stems[kind]!.copyStereo(), map: plan.map,
                                                            semitones: shift, percussive: kind == .drums)
                        if ticket.isCancelled { throw CancellationError() }
                        try StemAudio.save(matched, directory: staging, name: kind.rawValue)
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
                return Matched(plan: plan, stems: stems, peaks: stems.mapValues { $0.peaks(hop: Self.peakHop) })
            })
        }
    }
}
