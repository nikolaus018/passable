import CryptoKit
import Foundation

/// On-disk home for everything derived from one source file: its four stems,
/// its analysis, and any tempo/pitch-matched renditions of the stems.
///
/// Keyed by path, size and modification date, so re-importing an unchanged
/// file skips the minute of separation, while editing it invalidates the cache.
enum StemCache {
    /// Bump when the model or the stem format changes.
    private static let version = 1

    static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Passable/tracks", isDirectory: true)
    }()

    static func directory(for url: URL) throws -> URL {
        let dir = try folder(for: url)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `directory(for:)` without making it.
    static func folder(for url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(version)|\(url.standardizedFileURL.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    /// A song's folder was just used (see `prune`).
    static func markUsed(_ directory: URL) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("used").path, contents: Data())
    }

    /// Days a song's folder is kept unused when its song isn't in `keeping`.
    static let unusedDays = 14.0

    /// Frees the disk of songs that are gone: every song ever loaded keeps
    /// its four stems (~400 MB) and a tempo-matched copy of them, and
    /// nothing ever removed them, so songs deleted long ago still held most
    /// of 200 GB. A folder goes when its song isn't one of `keeping` (the
    /// library and the set) and it hasn't been used for `unusedDays`; one
    /// that comes back is separated again.
    @discardableResult
    static func prune(keeping: [URL], dryRun: Bool = false) -> [URL] {
        var gone: [URL] = []
        let fm = FileManager.default
        let keep = Set(keeping.compactMap { try? folder(for: $0).lastPathComponent })
        let cutoff = Date().addingTimeInterval(-unusedDays * 86_400)
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(dir.lastPathComponent) {
            let marks = ["used", "exact.1", "analysis.json", ""].map { dir.appendingPathComponent($0) }
            let last = marks.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
            if let last, last < cutoff {
                gone.append(dir)
                if !dryRun { try? fm.removeItem(at: dir) }
            }
        }
        return gone
    }

    static func hasStems(in directory: URL) -> Bool {
        StemKind.allCases.allSatisfy { StemAudio.exists(directory: directory, name: $0.rawValue) }
    }

    /// Whether the stems add up to the song (see `StemResidual`).
    static func isExact(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("exact.1").path)
    }

    static func markExact(_ directory: URL) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("exact.1").path, contents: Data())
    }

    /// Renditions and waveform overviews made from the stems as they were.
    static func forgetDerivedAudio(in directory: URL) {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("matched") || item.lastPathComponent == "render-matched" {
            try? fm.removeItem(at: item)
        }
        for item in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.contains(".peaks") {
            try? fm.removeItem(at: item)
        }
    }

    static func loadStems(from directory: URL) throws -> [StemKind: StemAudio] {
        var stems: [StemKind: StemAudio] = [:]
        for kind in StemKind.allCases {
            stems[kind] = try StemAudio.load(directory: directory, name: kind.rawValue)
        }
        return stems
    }

    /// Waveform overviews, kept next to the stems. Working one out reads
    /// every sample of a stem (a few hundred MB a song, which is what made
    /// opening a set slow); reading it back is a few hundred KB.
    static func peaks(_ stems: [StemKind: StemAudio], in directory: URL, hop: Int) -> [StemKind: [Float]] {
        var out: [StemKind: [Float]] = [:]
        for (kind, stem) in stems {
            let url = directory.appendingPathComponent("\(kind.rawValue).peaks\(hop).f32")
            let count = (stem.count + hop - 1) / hop
            if let data = try? Data(contentsOf: url), data.count == count * MemoryLayout<Float>.size {
                out[kind] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else {
                let peaks = stem.peaks(hop: hop)
                out[kind] = peaks
                try? MappedChannel.write(peaks, to: url)
            }
        }
        return out
    }

    /// Tempo-matched stems from before matching was sample-exact.
    static func removeLegacyMatches(in directory: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("matched-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static func loadAnalysis(from directory: URL) -> TrackAnalysis? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("analysis.json")) else { return nil }
        return try? JSONDecoder().decode(TrackAnalysis.self, from: data)
    }

    static func saveAnalysis(_ analysis: TrackAnalysis, to directory: URL) {
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: directory.appendingPathComponent("analysis.json"), options: .atomic)
    }
}
