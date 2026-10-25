import XCTest
import os
import Accelerate
@testable import Passable

/// Not a unit test: times each stage of adding a song that has never been
/// seen (decode, separation, analysis, lyrics) for the songs listed in
/// $PASSABLE_INGEST, without reading or writing the cache. With
/// $PASSABLE_INGEST_OUT, the first song's stems are written there, and a
/// second run compares its stems against them. Skipped unless set.
final class IngestLab: XCTestCase {
    func testStages() throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_INGEST"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_INGEST")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        let out = ProcessInfo.processInfo.environment["PASSABLE_INGEST_OUT"].map { URL(fileURLWithPath: $0) }
        func clock() -> Double { ProcessInfo.processInfo.systemUptime }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var t = clock()
        let separator = try StemSeparator()
        print(String(format: "INGEST model load: %.2f s", clock() - t))
        var totals = [String: Double]()
        for (index, url) in urls.enumerated() {
            let start = clock()
            t = clock()
            let mix = try AudioIO.loadStereo(url: url)
            let decode = clock() - t
            t = clock()
            let separated = try separator.separate(mix, progress: { _ in })
            let separate = clock() - t
            t = clock()
            let dir = scratch.appendingPathComponent("\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (kind, buffer) in separated { try StemAudio.save(buffer, directory: dir, name: kind.rawValue) }
            let stems = try StemCache.loadStems(from: dir)
            let save = clock() - t
            t = clock()
            let analysis = TrackAnalyzer.analyze(stems: stems)
            let analyze = clock() - t
            do {
                var t = clock()
                let n = stems[.drums]!.count
                var mixed = [Float](repeating: 0, count: n)
                for stem in stems.values {
                    vDSP_vadd(mixed, 1, stem.left.pointer, 1, &mixed, 1, vDSP_Length(n))
                    vDSP_vadd(mixed, 1, stem.right.pointer, 1, &mixed, 1, vDSP_Length(n))
                }
                t = clock()
                let heard = try BeatTracker.shared!.track(mixed)
                let track = clock() - t; t = clock()
                let drums = stems[.drums]!.copyStereo().mono()
                let harmony = mixed
                let layers = [StemKind.drums, .bass, .other].map { stems[$0]!.copyStereo().mono() }
                let prep = clock() - t; t = clock()
                _ = TempoEstimator.estimate(rhythm: drums, harmony: harmony, layers: layers, heard: heard, sampleRate: AudioIO.sampleRate)
                let tempo = clock() - t; t = clock()
                _ = KeyDetector.detect(samples: harmony, sampleRate: AudioIO.sampleRate)
                let key = clock() - t; t = clock()
                _ = TrackStructure.measure(stems: stems, grid: analysis.grid)
                let structure = clock() - t; t = clock()
                _ = StemCache.peaks(stems, in: dir, hop: TrackProcessor.peakHop)
                let peaks = clock() - t
                print(String(format: "INGEST   analysis parts: beat model %.2f, prep %.2f, tempo %.2f, key %.2f, structure %.2f, peaks %.2f s",
                             track, prep, tempo, key, structure, peaks))
            }
            t = clock()
            let outcome = Lyrics.listen(vocals: stems[.vocals]!)
            let lyrics = clock() - t
            let total = clock() - start
            let heard: String
            switch outcome {
            case .heard(let h): heard = "\(h.lines.count) lines, \(h.locale)"
            case .none: heard = "none"
            case .failed: heard = "failed"
            }
            print(String(format: "INGEST %@ (%.0f s audio): decode %.2f, separate %.2f, save %.2f, analyze %.2f, lyrics %.2f (%@), total %.2f s; %.1f bpm, %@",
                         url.lastPathComponent, Double(mix.count) / AudioIO.sampleRate,
                         decode, separate, save, analyze, lyrics, heard, total, analysis.grid.bpm, "\(analysis.key)"))
            for (name, value) in [("decode", decode), ("separate", separate), ("save", save), ("analyze", analyze),
                                  ("lyrics", lyrics), ("total", total)] {
                totals[name, default: 0] += value
            }

            if index == 0, let out {
                if StemCache.hasStems(in: out) {
                    let reference = try StemCache.loadStems(from: out)
                    for kind in StemKind.allCases {
                        let a = reference[kind]!, b = stems[kind]!
                        var signal = 0.0, noise = 0.0
                        for (x, y) in [(a.left, b.left), (a.right, b.right)] {
                            for i in 0..<min(a.count, b.count) {
                                let r = Double(x.pointer[i]), d = Double(y.pointer[i]) - r
                                signal += r * r; noise += d * d
                            }
                        }
                        print(String(format: "INGEST %@ vs reference: %.1f dB SNR", kind.rawValue, 10 * log10(signal / max(noise, 1e-30))))
                    }
                } else {
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    for (kind, buffer) in separated { try StemAudio.save(buffer, directory: out, name: kind.rawValue) }
                    print("INGEST wrote reference stems to \(out.path)")
                }
            }
        }
        print("INGEST totals over \(urls.count) songs: " + ["decode", "separate", "save", "analyze", "lyrics", "total"]
            .map { String(format: "%@ %.2f s", $0, totals[$0] ?? 0) }.joined(separator: ", "))
    }

    /// All the songs added at once, as the Set tab does, through the real
    /// loader: copies under new names, so nothing is cached, and their cache
    /// folders removed again afterwards.
    func testAddingAtOnce() async throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_INGEST"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_INGEST")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        func clock() -> Double { ProcessInfo.processInfo.systemUptime }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copies = try urls.enumerated().map { index, url in
            let copy = scratch.appendingPathComponent("\(index)-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        }
        defer {
            for copy in copies { if let dir = try? StemCache.directory(for: copy) { try? FileManager.default.removeItem(at: dir) } }
            try? FileManager.default.removeItem(at: scratch)
        }
        let processor = TrackProcessor()
        print("INGEST thermal state at start: \(ProcessInfo.processInfo.thermalState.rawValue) (0 nominal … 3 critical)")
        let start = clock()
        try await withThrowingTaskGroup(of: (Int, Double, TrackProcessor.Loaded).self) { group in
            for (index, url) in copies.enumerated() {
                group.addTask {
                    let loaded = try await withCheckedThrowingContinuation { c in
                        let last = OSAllocatedUnfairLock(initialState: "")
                        processor.load(url, ticket: .init(), progress: { p in
                            let stage: String
                            switch p {
                            case .decoding: stage = "decoding"
                            case .separating(let f): stage = f == 0 ? "separating" : ""
                            case .analyzing: stage = "analyzing"
                            }
                            guard !stage.isEmpty, last.withLock({ old in defer { old = stage }; return old != stage }) else { return }
                            print(String(format: "INGEST %6.2f s  song %d %@", clock() - start, index, stage))
                        }) { c.resume(with: $0) }
                    }
                    return (index, clock() - start, loaded)
                }
            }
            for try await (index, done, loaded) in group {
                print(String(format: "INGEST ready %@ after %.2f s: %.1f bpm, %d lines", urls[index].lastPathComponent, done,
                             loaded.analysis.grid.bpm, loaded.analysis.structure?.vocalLines?.count ?? -1))
            }
        }
        print(String(format: "INGEST %d songs added at once: all ready after %.2f s", urls.count, clock() - start))
        print("INGEST thermal state at end: \(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    /// How much separating one song slows down while another song's lyrics
    /// or analysis run alongside.
    func testContention() throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_INGEST"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_INGEST")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        func clock() -> Double { ProcessInfo.processInfo.systemUptime }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let separator = try StemSeparator()
        let first = try separator.separate(try AudioIO.loadStereo(url: urls[0]), progress: { _ in })
        for (kind, buffer) in first { try StemAudio.save(buffer, directory: scratch, name: kind.rawValue) }
        let stems = try StemCache.loadStems(from: scratch)
        let mix = try AudioIO.loadStereo(url: urls[1])
        let analysis = TrackAnalyzer.analyze(stems: stems)
        var summed = [Float](repeating: 0, count: stems[.drums]!.count)
        for stem in stems.values {
            vDSP_vadd(summed, 1, stem.left.pointer, 1, &summed, 1, vDSP_Length(summed.count))
            vDSP_vadd(summed, 1, stem.right.pointer, 1, &summed, 1, vDSP_Length(summed.count))
        }
        let mixed = summed
        for (name, work) in [("alone", nil), ("lyrics", { _ = Lyrics.listen(vocals: stems[.vocals]!) }),
                             ("analysis", { _ = TrackAnalyzer.analyze(stems: stems) }),
                             ("beat model", { _ = try? BeatTracker.shared?.track(mixed) }),
                             ("structure", { _ = TrackStructure.measure(stems: stems, grid: analysis.grid) }),
                             ("alone", nil)] as [(String, (() -> Void)?)] {
            let stop = OSAllocatedUnfairLock(initialState: false)
            let group = DispatchGroup()
            var rounds = 0
            if let work {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    while !stop.withLock({ $0 }) { work(); rounds += 1 }
                }
            }
            let t = clock()
            _ = try separator.separate(mix, progress: { _ in })
            let time = clock() - t
            stop.withLock { $0 = true }
            group.wait()
            print(String(format: "INGEST separate with %@ alongside: %.2f s (%d rounds)", name, time, rounds))
        }
    }
}
