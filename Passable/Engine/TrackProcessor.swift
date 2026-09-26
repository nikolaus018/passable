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
                if let cached = StemCache.loadAnalysis(from: directory) {
                    analysis = cached
                    if analysis.structure == nil {
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

    /// Tempo- and key-matched copies of a track's stems. Drums are only
    /// time-stretched: pitch-shifting them buys nothing harmonically and
    /// costs transient punch.
    func match(_ loaded: Loaded, rate: Double, semitones: Int, ticket: Ticket,
               completion: @escaping @Sendable (Result<Matched, Error>) -> Void) {
        queue.async {
            completion(Result {
                let directory = try StemCache.matchedDirectory(in: loaded.directory, rate: rate, semitones: semitones)
                var stems: [StemKind: StemAudio] = [:]
                for kind in StemKind.allCases {
                    if ticket.isCancelled { throw CancellationError() }
                    let shift = kind == .drums ? 0 : semitones
                    if abs(rate - 1) < 1e-6 && shift == 0 {
                        stems[kind] = loaded.stems[kind]
                        continue
                    }
                    if !StemAudio.exists(directory: directory, name: kind.rawValue) {
                        let source = loaded.stems[kind]!.copyStereo()
                        let matched = try TimeStretcher.process(source, rate: rate, semitones: shift)
                        try StemAudio.save(matched, directory: directory, name: kind.rawValue)
                    }
                    stems[kind] = try StemAudio.load(directory: directory, name: kind.rawValue)
                }
                return Matched(stems: stems, peaks: stems.mapValues { $0.peaks(hop: Self.peakHop) })
            })
        }
    }
}
