import CryptoKit
import Foundation

/// A drummer's song with its bars made even: each bar stretched or squeezed
/// to the song's average bar, so its beat can be matched to another's like
/// any sequenced record's.
///
/// A song played by a drummer breathes: its bars run a percent or two fast
/// or slow (`Steadiness.downbeats`), and over a minute its beat drifts a
/// second off any constant grid. It was never beat-matched for that, only
/// bridged in and out with a cut, and a set with a few such songs (disco,
/// funk, rock) had a cut on each side of every one: seven songs of 117 made
/// seven cuts, six in a row where Auto-Order put them together. A DJ rides
/// the pitch to keep such a record on the other's beat; held to its average
/// tempo bar by bar, it plays as the record does (a bar 1 % longer or
/// shorter is not heard; the drummer's feel inside each bar is kept) and
/// blends like any other.
///
/// Only where the bars are the drummer's: none more than `maxBarChange`
/// off the average (a tracker that lost the beat for a bar gives one far
/// off, and that bar would be heard bent). The steadied song lives in a
/// folder of its own inside the song's (stems, analysis, renditions), made
/// once and again only when the song's own analysis changes.
enum Steadying {
    /// The most a bar is stretched or squeezed (fraction of its length).
    static let maxBarChange = 0.08

    /// Bumped when the steadied audio or its analysis are made another way.
    static let version = 1

    static let folderName = "steady"

    /// How the song's own time maps onto the steadied song's: each of its
    /// downbeats onto one of a constant grid from its first.
    struct Warp {
        /// The song's downbeats (seconds).
        let downbeats: [Double]
        /// The steadied song's bar (seconds).
        let bar: Double

        /// Seconds of the steadied song at which the song's second `x`
        /// is heard (before the first downbeat and after the last, as it is).
        func output(_ x: Double) -> Double {
            let d = downbeats
            if x <= d[0] { return x }
            let n = d.count - 1
            if x >= d[n] { return d[0] + Double(n) * bar + (x - d[n]) }
            var lo = 0, hi = n
            while hi - lo > 1 { let mid = (lo + hi) / 2; if d[mid] <= x { lo = mid } else { hi = mid } }
            return d[0] + (Double(lo) + (x - d[lo]) / (d[lo + 1] - d[lo])) * bar
        }

        /// The song's second heard at the steadied song's second `y`.
        func source(_ y: Double) -> Double {
            let d = downbeats, n = d.count - 1
            if y <= d[0] { return y }
            let k = (y - d[0]) / bar
            if k >= Double(n) { return d[n] + (y - d[0] - Double(n) * bar) }
            let i = Int(k)
            return d[i] + (k - Double(i)) * (d[i + 1] - d[i])
        }
    }

    /// The warp for a song whose tempo breathes, nil for one that keeps a
    /// grid (or whose bars aren't a drummer's to go by).
    static func warp(_ grid: BeatGrid) -> Warp? {
        guard grid.wanders == true, let d = grid.downbeats, d.count >= 9 else { return nil }
        let bar = (d[d.count - 1] - d[0]) / Double(d.count - 1)
        guard bar > 0 else { return nil }
        let changes = zip(d.dropFirst(), d).map { abs(bar / ($0 - $1) - 1) }
        // (Bars all of one length: the grid's own, given where the tracker
        // was lost; there's nothing to even out.)
        guard changes.max()! > 1e-4, changes.allSatisfy({ $0 <= maxBarChange }) else { return nil }
        return Warp(downbeats: d, bar: bar)
    }

    /// The steadied song, made if need be; nil where the song needs none.
    static func steadied(directory: URL, stems: [StemKind: StemAudio], analysis: TrackAnalysis)
        throws -> (directory: URL, stems: [StemKind: StemAudio], analysis: TrackAnalysis)? {
        guard let warp = warp(analysis.grid) else { return nil }
        let fm = FileManager.default
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        let stemsMark = folder.appendingPathComponent("stems-\(version)-\(fingerprint(warp.downbeats))")
        let analysisMark = folder.appendingPathComponent("from-\(version)-\(fingerprint(analysis))")
        let sr = AudioIO.sampleRate

        if !(fm.fileExists(atPath: stemsMark.path) && StemCache.hasStems(in: folder)) {
            // Written beside and moved into place: a half-made song is
            // never taken for a made one.
            let staging = directory.appendingPathComponent(".\(folderName)-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            final class Box: @unchecked Sendable { var error: Error?; let lock = NSLock() }
            let box = Box()
            let count = Int((warp.output(analysis.duration) * sr).rounded(.down))
            DispatchQueue.concurrentPerform(iterations: StemKind.allCases.count) { i in
                let kind = StemKind.allCases[i]
                do {
                    guard let stem = stems[kind] else { return }
                    let out = TimeStretcher.warp(stem.copyStereo(), count: count,
                                                 source: { warp.source($0 / sr) * sr },
                                                 output: { warp.output($0 / sr) * sr }, percussive: kind == .drums)
                    try StemAudio.save(out, directory: staging, name: kind.rawValue)
                } catch {
                    box.lock.lock(); box.error = box.error ?? error; box.lock.unlock()
                }
            }
            if let error = box.error {
                try? fm.removeItem(at: staging)
                throw error
            }
            try? fm.removeItem(at: folder)
            try fm.moveItem(at: staging, to: folder)
            fm.createFile(atPath: stemsMark.path, contents: Data())
        }
        let steady = try StemCache.loadStems(from: folder)

        if fm.fileExists(atPath: analysisMark.path), var made = StemCache.loadAnalysis(from: folder),
           made.version == analysis.version {
            // (Breaths, for one steadied before they were measured.)
            if let structure = made.structure, structure.vocalBreaths == nil {
                made.structure?.vocalBreaths = steady[.vocals].map(TrackStructure.breaths) ?? []
                made.structure?.setLines(structure.vocalLines, tried: structure.lyricsTried, grid: made.grid)
                StemCache.saveAnalysis(made, to: folder)
            }
            return (folder, steady, made)
        }
        // Its analysis: the song's, on a constant grid from its first
        // downbeat, its parts measured again on the steadied stems and its
        // words where they're now sung.
        var made = analysis
        made.grid = BeatGrid(bpm: 240 / warp.bar, firstDownbeat: warp.downbeats[0])
        made.duration = warp.output(analysis.duration)
        if let old = analysis.structure {
            made.structure = TrackStructure.measure(stems: steady, grid: made.grid)
            made.structure?.heardReference = TrackStructure.heardReference(stems: steady, grid: made.grid)
            made.structure?.setLines(old.vocalLines.map { $0.map { moved($0, warp) } }, tried: old.lyricsTried,
                                     grid: made.grid)
        }
        StemCache.saveAnalysis(made, to: folder)
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("from-") {
            try? fm.removeItem(at: item)
        }
        fm.createFile(atPath: analysisMark.path, contents: Data())
        return (folder, steady, made)
    }

    /// A sung line where it's heard in the steadied song.
    static func moved(_ line: VocalLine, _ warp: Warp) -> VocalLine {
        var l = line
        l.start = warp.output(line.start)
        l.end = warp.output(line.end)
        l.breaks = line.breaks.map(warp.output)
        l.wordTimes = line.wordTimes.map(warp.output)
        return l
    }

    private static func fingerprint(_ downbeats: [Double]) -> String {
        hash(downbeats.map { String(format: "%.6f", $0) }.joined(separator: ","))
    }

    private static func fingerprint(_ analysis: TrackAnalysis) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return hash((try? encoder.encode(analysis)).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
